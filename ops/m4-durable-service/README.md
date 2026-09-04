# M4 durable broker lifecycle phase

This phase installs Agent Manager as an `ai` user service owned by the
container's systemd lifecycle manager. It does not install the broker binary or
the locked Claude environment; first activate those stable paths with the
reviewed `ops/m5-release-install/` phase. The unit keeps provider processes
alive across SSH and Neovim exits, while the broker exposes only an owner-only
Unix socket.

The service passes absolute Codex, Claude worker, and workspace-lifecycle
paths. Its broker policy permits lifecycle-managed task worktrees and rejects
shared-checkout starts. Changing that policy is an explicit unit change; the
plugin exposes no reset, delete, force-clean, or garbage-collection control.

All parameters are reviewed in `m4.env`. The service writes transcript-free
registry metadata under the user's state directory and stable monitoring JSON
to `/var/lib/zemrip/status/agent-manager.json`.

Run in this order:

1. As `ai`, run `00-preflight.sh`.
2. From the operator control plane, run `05-status-dir.sh` for the one
   privileged status-directory change.
3. As `ai`, run `10-install-unit.sh` and `20-enable.sh`.
4. As `ai`, run `90-verify.sh`. It performs a real socket handshake and writes
   `/var/lib/zemrip/status/agent-manager-m4-verify.json`.

The container lifecycle manager must already have linger enabled for `ai`;
this phase checks that prerequisite and deliberately does not change it.

Rollback is the reverse order: `undo-20.sh`, `undo-10.sh`, then, from the
operator control plane, `undo-05.sh`. Each undo preserves pre-existing or
subsequently modified state rather than guessing ownership.
