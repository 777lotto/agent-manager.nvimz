# Protocol ownership

Agent Manager has two independent, versioned JSON-RPC contracts:

- `broker/v1/` is the public Neovim-to-broker contract.
- `claude-worker/v1/` is the private Rust-to-Python contract.

Both use standard JSON-RPC 2.0 with a required `"jsonrpc":"2.0"` member and one
JSON object per line in stdio mode. The schemas are the source of truth;
language bindings and fixtures must agree with them.

Requests require a string or integer ID. Parse/invalid-request error responses
may carry the JSON-RPC-required null ID when the peer could not recover a valid
request ID. The public connection completes its handshake with an `initialized`
notification after a successful `initialize` response.

Codex App Server is a provider protocol, not either Agent Manager contract.
The reviewed 0.152.0 schema baseline deliberately omits the JSON-RPC header on
its wire. The curated generated schemas under `vendor/codex/0.152.0/` capture
that release, and the Rust adapter translates it at the provider boundary. The
runtime compatibility profile accepts that baseline and newer stable App Server
releases after a successful non-experimental initialization handshake; the
generated bundle is a review baseline, not a required installed CLI version.

## Compatibility rules

- Breaking method, field, enum, or semantic changes require a new protocol
  directory. Do not silently reinterpret v1.
- Optional additive fields require an explicit schema change and fixtures in
  every consuming language.
- Unknown provider events become `provider.notice`; they do not expand the
  stable event vocabulary implicitly.
- Approval and question response choices are provider-derived. The common
  contract never invents a persistent approval choice.
- The additive question `decision` field defaults to `answer` when omitted by
  an older protocol-v1 client; denial is always explicit.
- The additive `provider/session/list` `active_only` flag and optional `cwd`
  support metadata-only cross-project CLI discovery; omitting the flag retains
  resumable-session behavior.
- Additive `provider/session/delete` and private `session/delete` requests
  hard-delete only an exact inactive provider history record. They fail closed
  when writer activity cannot be verified and do not delete workspace files.
- Additive `workspace/diff` applies the existing bounded, no-external-driver Git
  diff behavior to a focused directory that has no broker agent.
- Additive managed-workspace fields preserve the explicit path-based v1 calls.
  `workspace/list`, managed `agent/start`, managed `agent/resume`, and
  `workspace/handoff` delegate to the external lifecycle authority and expose
  no destructive Git operation.
- Agent summaries report the actual provider runtime and compatibility profile
  learned during startup. A resumed session is opened by the currently
  configured compatible runtime; a live provider process is never hot-swapped.
- Malformed frames, duplicate callback responses, and unknown callback IDs fail
  closed.

Run `mise run verify` to validate every fixture against its owning schema and
deserialize public fixtures in Rust.
