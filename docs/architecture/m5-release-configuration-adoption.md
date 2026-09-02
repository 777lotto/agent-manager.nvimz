# M5 release and configuration adoption

Status: implemented and accepted on 2026-09-02.

M5 turns the M0-M4 runtime into one auditable production unit. It does not
change the public broker or private worker protocols. Instead, it freezes their
compatible toolchain, provider, and UX revisions; builds a reproducible native
and Python payload; verifies provenance before installation; and adopts the
durable paths explicitly in `nvim-config`.

## Compatibility lock

`release/compatibility-v1.json` is the machine-checked release contract for
v0.1.0:

| Boundary                           | Exact revision or version                  |
| ---------------------------------- | ------------------------------------------ |
| Target                             | `x86_64-unknown-linux-gnu`                 |
| Rust                               | 1.98.0                                     |
| Python                             | 3.13.15                                    |
| uv                                 | 0.12.7                                     |
| Neovim                             | 0.12.4                                     |
| Broker and Claude worker protocols | 1 / 1                                      |
| Codex App Server                   | 0.152.0                                    |
| Claude Agent SDK / Claude Code     | 0.2.148 / 2.1.251                          |
| UX Foundation                      | `7b8700db546b35e7b6a40b9a41b129354981587f` |
| UX Styling                         | `3379b8ba03380316a5a8f3ad3671509e9283b518` |
| UX Chrome                          | `a6a20a2135603484cd451ba7f338cf0b6fa7dbad` |

The release metadata validator compares that file with Cargo, Python, Mise,
the promoted UX pins, and the compiled broker's `contract-info` response. A
version change cannot silently drift one side of the runtime boundary.

## Reproducible release unit

`mise run release` produces:

- `agent-manager-v0.1.0-x86_64-unknown-linux-gnu.tar.gz`; and
- `SHA256SUMS` for the archive.

The archive contains the native broker, the private worker wheel, a complete
hash-locked binary-wheel `site-packages` tree, exported requirements with
hashes, the compatibility lock, license, `release.json`, and
`PAYLOAD.SHA256`. Cargo uses the locked graph in a fresh target directory,
source paths are remapped, the ELF build ID is omitted, wheel installation is
copy-only, and tar ownership, modes, order, and timestamps are normalized to
the source commit. Two independent builds must compare byte-for-byte before
handoff.

`release.json` records the full source revision, clean/dirty marker, source
epoch, compatibility lock, broker contract, and payload-checksum digest.
Production verification requires `source_dirty: false`. Archive extraction
rejects absolute or traversing paths, links, special files, unexpected roots,
oversized payloads, invalid checksums, incompatible versions, and generated
Python bytecode.

Neither plugin setup nor Neovim startup invokes Cargo, uv, pip, or a dependency
resolver. The one private Python worker continues to host Claude clients; a
pool remains unjustified without measured isolation or throughput pressure.

## CI, promotion, and provenance

CI follows the UX repository model: `bet` is production/default, `bluff` is
persistent integration, ordinary branches target `bluff`, and only `bluff`
may open a promotion pull request into `bet`. Linux runs the complete release
and operations gate. macOS verifies the broker, worker, provider pins, Lua, and
UX contracts without attempting the Linux-only artifact build. Both paths use
the exact Codex CLI and locked Claude environment, fake provider processes,
and no authentication or paid turns.

Releases start only from a signed annotated `v*` tag whose GitHub verification
is successful, whose target is a commit reachable from `bet`, and whose version
matches the compatibility lock. GitHub Actions rebuilds from that clean tag,
runs the complete gate, issues keyless artifact attestations for the archive
and checksum file, and publishes both assets. The production repository then
dispatches a focused lock-refresh event to `nvim-config` when `bet` advances.

The v0.1.0 binary remains a repository release asset. A separate package or
registry would add another trust and version boundary without solving a first
release requirement.

## Resumable installation

`ops/m5-release-install/` is the credential-free artifact phase. It uses
reviewed absolute paths, refuses to switch an active broker, verifies the outer
checksum and full inner payload, extracts to an immutable versioned directory,
constructs a minimal versioned venv pointing at the bundled packages, and
atomically changes the stable M4 symlinks. Re-running every apply step is safe.

Behavioral verification executes the installed broker contract and a real
private worker initialization handshake without opening a provider session.
It writes only version, hash, file-count, and success/failure evidence. Paired
undo restores prior managed symlink targets and removes only trees the phase
proved it created; unknown, changed, or pre-existing state is preserved.

After M5 activation, the existing M4 unit phase starts the durable service.
Upgrades deliberately require an operator to stop live agents before changing
the stable links.

## Configuration adoption

The companion `nvim-config` change pins the exact production Agent Manager
revision alongside the three compatible UX revisions. Its plugin spec selects
durable mode explicitly and names only the reviewed stable broker, socket, and
worker-Python paths. Embedded mode remains the plugin default so installations
without the lifecycle service keep a predictable native fallback.

The dependency-update workflow recognizes `agent-manager.nvimz` as a focused
lock target. It updates the lock only after a production `bet` notification;
it does not install broker or Python dependencies from Neovim.

## Acceptance evidence

`mise run verify` adds deterministic coverage for:

- static compatibility metadata versus source and compiled contracts;
- two byte-identical release builds;
- complete inner and outer SHA-256 verification;
- safe archive extraction and clean-source enforcement;
- locked worker initialization from the bundled environment;
- idempotent install/activate and reverse-order paired undo;
- shell, Python, unit, and systemd phase validation;
- Linux and macOS pinned-provider/runtime CI; and
- production-source, signed-tag, attestation, and release workflow policy.
