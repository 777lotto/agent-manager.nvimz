# M4 durable multi-agent runtime

Status: implemented and accepted on 2026-09-02.

M4 adds a supervised runtime without changing the provider boundary established
in M0-M3. The Rust broker remains the only owner of public protocol state,
provider processes, global event sequencing, replay, and durable metadata. The
Python worker still owns Claude SDK objects and callbacks only, and the Neovim
client still owns editor presentation and explicit context capture.

## Durable lifecycle and private paths

`agent-manager-broker serve-durable` listens only on a Unix socket. With no
override, the socket is `${XDG_RUNTIME_DIR}/agent-manager/broker.sock`; a
missing or relative `XDG_RUNTIME_DIR` is an actionable startup error. Socket
and registry overrides must be absolute.

The broker creates or validates dedicated directories before binding. The
runtime directory is mode `0700`, the socket is `0600`, and the metadata
registry is `0600`. Existing symlinks, non-socket targets, broad directory
permissions, and an already responsive broker are rejected. A stale socket is
removed only after it is proved to be a Unix socket that refuses connections.
Cleanup compares device and inode, so one process cannot unlink a replacement
socket created by another.

The lifecycle-manager package lives in `ops/m4-durable-service/`. It is a
systemd user service with restart-on-failure behavior and stable M5 artifact
paths. The phase is split into preflight, privileged status-directory setup,
unit installation, enable/start, behavioral verification, and paired undo
steps. It requires the container lifecycle manager to have already enabled
linger for `ai`; the phase checks but does not silently change that global
policy.

The unit writes monitoring state to
`/var/lib/zemrip/status/agent-manager.json`. The schema records
`last_success_at`, `last_failure_at`, `last_error`, and agent/registry
object-byte counts without prompts, tool payloads, responses, or credentials.

## Connection generations, replay, and resync

The durable broker survives Neovim and SSH disconnects. Each accepted editor
connection receives a monotonically increasing private generation. Requests
handed to provider tasks use opaque broker IDs that map back to the public
JSON-RPC ID and generation. A response from an old connection is discarded,
even when a restarted Neovim reuses the same public ID.

Every connection performs `initialize` and `initialized`. The client supplies
its last observed public event sequence. After `initialized`, the broker sends
the retained suffix before current state and live events. Replay is bounded to
2,000 events by default. Initialization reports the retained bounds and
`resync_required` when the cursor is older than the window.

On resync, the Lua model advances to the broker's latest sequence, clears
event-derived projections, reloads `agent/list`, and requests provider-backed
history for each live agent. It never replays a prompt. The Unix-socket client
uses capped exponential backoff with bounded jitter and retains an explicit
manual reconnect path through any ordinary action.

Human requests remain fail-closed. Disconnect sends a cancellation command to
every provider runtime, and an approval or question first observed while no
ready editor exists triggers the same cancellation path. Resolution events
still enter replay so a reconnect cannot resurrect an unactionable request.

## Metadata-only registry

The default registry is
`${XDG_STATE_HOME:-$HOME/.local/state}/agent-manager/registry.json`. Writes use
an owner-only temporary file, `fsync`, and atomic rename. The registry stores
only:

- workspace agent and provider session IDs;
- provider, canonical cwd, workspace strategy, and worktree path;
- title, lifecycle state, and timestamps; and
- the last known actual provider runtime and compatibility profile.

Active turn IDs, prompts, attachments, tool/approval payloads, model responses,
credentials, and replay events are excluded. On broker restart, registry
entries return as disconnected summaries with their provider identity intact;
the broker never fabricates turn completion or replays input.

An inactive summary can be archived through the public broker contract or the
confirmed Neovim action. Archiving removes only Agent Manager's registry entry;
provider-owned session history remains available for discovery and resume.

## Multiple agents and writer isolation

Durable mode removes the embedded one-live-agent limit. Each agent owns a
bounded command channel and a single provider task, which serializes prompt,
steer, interrupt, history, and callback commands independently. One blocked
agent therefore does not merge input with or overwrite another agent's state.

Shared writer ownership is keyed by the canonical Git top level, not the
requested subdirectory. A second live writable agent anywhere in that checkout
is rejected with `shared_checkout_writer_conflict`. Non-Git directories are
keyed by their canonical cwd.

An explicit `worktree` strategy is accepted only when `cwd` and
`worktree_path` resolve to the same linked Git worktree. Main checkouts and
directories containing a fabricated `.git` directory do not qualify. The
preferred managed start takes a registered repository and stable task ID; the
broker delegates inventory, claim/resume, and lease handoff to the installed
Git/worktree authority and records repository, task, `agent/**` branch, base,
and path in its summary. It does not reproduce Git lifecycle logic.
The claim response is validated against the exact linked Git worktree, task
branch, and branch-configured base before provider startup. This avoids using
the authority's repository-wide cleanup audit as a redundant post-claim lookup;
older authorities without a valid receipt use the audit fallback, with a
non-destructive lease handoff if that fallback fails.

Shared-checkout starts are an explicit broker policy and are disabled by the
production unit. The plugin exposes that opt-in as `worktrees.allow_shared` for
embedded mode. Neither policy surface exposes reset, checkout deletion,
force-clean, or garbage collection; cleanup consequences and proof remain
wholly owned by the external lifecycle authority. Provider-history deletion is
a separate, exact-session operation and always preserves Git state.

Embedded stdio mode deliberately retains its one-live-agent limit and shutdown
ownership. `broker/shutdown` is rejected in durable mode because only the
lifecycle manager may stop the service.

## Acceptance evidence

`mise run verify` remains deterministic and provider-offline. M4 adds coverage
for:

- owner-only socket, registry, and status permissions;
- multiple simultaneous Codex/Claude fake runtimes;
- per-checkout writer conflict and linked-worktree validation;
- per-agent input serialization;
- reconnect replay and bounded `resync_required` behavior;
- transcript and tool-payload absence from registry state;
- delayed old-generation response rejection;
- automatic Neovim disconnect/reconnect without stopping the service; and
- lifecycle scripts, unit syntax, paired undo structure, and behavioral
  verification code.

M5 now supplies release artifact production, checksums and attestations, stable
artifact installation, provider/runtime CI, and exact adoption in
`nvim-config`; see
[M5 release and configuration adoption](m5-release-configuration-adoption.md).
