# M5 release artifact installation

This phase installs the attested Agent Manager v0.1.0 release without running
Cargo, uv, pip, or any dependency resolver from Neovim startup. The release
archive contains the native Linux x86_64 broker and a hash-locked Python 3.13
site-packages tree. Installation creates a minimal versioned venv, then switches
the stable M4 paths with atomic symlinks.

The checked-in `m5.env` pins every version and path. Place the two v0.1.0
release assets at its `RELEASE_ARCHIVE` and `RELEASE_CHECKSUMS` paths. Before
moving the assets into the AI container, verify the keyless GitHub build
attestation from a GitHub-authenticated control plane:

```sh
gh attestation verify \
  agent-manager-v0.1.0-x86_64-unknown-linux-gnu.tar.gz \
  --repo 777lotto/agent-manager.nvimz
```

Run every phase as `ai`; none uses sudo:

1. `00-preflight.sh`
2. `10-install-release.sh`
3. `20-activate-release.sh`
4. `90-verify.sh`

The preflight verifies the release checksum, safe archive shape, internal
payload checksums, clean source marker, target, and exact Python runtime. It
also refuses to change stable paths while `agent-manager-broker.service` is
active. The verifier performs a real broker `contract-info` call and a private
Claude worker initialization handshake, then writes credential-free evidence
to `~/.local/state/agent-manager/m5-release-install/status.json`.

After this phase passes, install and enable the durable user service using
`ops/m4-durable-service/` in its documented order. The first release does not
restart an active broker: a future upgrade must explicitly coordinate agent
shutdown before changing these symlinks.

Rollback runs in reverse order while the service is inactive:

1. `undo-20.sh`
2. `undo-10.sh`

Undo restores prior managed symlink targets and removes only versioned trees
that this phase proved it created. Unknown files, non-symlink stable paths,
changed links, active services, and pre-existing versioned releases are
preserved and reported instead of overwritten or deleted.
