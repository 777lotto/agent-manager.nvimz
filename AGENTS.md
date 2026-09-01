# Agent Manager contributor guidance

## Scope and architecture

- `protocol/` is the source of truth for every broker-facing contract.
- The Rust broker owns public protocol state, provider process supervision,
  event sequencing, and the native Codex App Server adapter.
- The Python worker owns Claude Agent SDK objects and callbacks only. It must
  never expose a listener or write non-protocol data to standard output.
- Provider-specific payloads stay namespaced. Do not erase capabilities merely
  to make Codex and Claude appear identical.
- M0 has no editor UI. Keep Lua and Neovim runtime work out of the contract
  spike unless the milestone document is explicitly revised.

## Safety boundaries

- Never log prompts, tool payloads, credentials, or provider authentication
  material.
- Child commands are argv arrays. Do not add shell-based provider launches.
- Approval and question callbacks fail closed on timeout, cancellation,
  disconnect, or malformed input.
- Live provider probes are opt-in. The default verification suite uses fake
  runtimes and must not consume provider quota or require authentication.

## Build and verification

- Tool versions are pinned in `mise.toml`; Python dependencies are locked in
  `python/uv.lock`.
- Run `mise run verify` before handoff. It is the repository's required gate.
- Rust formatting and linting use `cargo fmt` and `cargo clippy`.
- Python formatting and linting use the versions locked by uv.
- Markdown is formatted with Prettier when it is changed mechanically; do not
  run Prettier over source or generated JSON.
- Codex vendor schemas are generated artifacts. Refresh them only with
  `mise run codex-schema` against the pinned Codex CLI version.

## Tests

- Keep ordinary tests deterministic and offline.
- Contract fixtures must be accepted by both the implementation and the
  versioned JSON Schema that owns them.
- Test malformed frames, unknown methods/events, cancellation, callback
  failure, and stdout purity when touching protocol code.
