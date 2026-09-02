# M2 safe interactive workflow

- Status: implemented
- Reviewed: 2026-09-02
- Public broker protocol: 1
- Lifecycle mode: embedded stdio

M2 keeps the M1 process topology and adds the controls required to use a
provider session safely from Neovim. The Rust broker still owns one live
provider runtime. Disconnected summaries may remain after a fork, but durable
reconnect and multiple live agents remain M4 work.

```text
Neovim decision/context/diff views
                 |
                 | public JSON-RPC v1
                 v
          Rust embedded broker
          |                  |
          | native requests  | private JSON-RPC callbacks
          v                  v
   Codex App Server     Claude Python worker
```

## Session lifecycle

`provider/session/list` starts a transient provider adapter and returns
redacted session metadata for one canonical cwd. Codex uses App Server thread
list filtering; Claude uses the worker's SDK-backed session discovery. Prompt
previews and transcript bodies are not returned by discovery.

`agent/resume` opens exactly the selected provider session ID. `agent/history`
projects provider history into user, assistant, and system messages without
exposing SDK or App Server objects to Lua. `agent/fork` is allowed only while
the source is idle, completed, or interrupted and has no pending human request.
Embedded mode retires the source runtime, preserves its summary as
`disconnected`, and opens the provider fork as the one live runtime.

The session picker can focus an existing broker-owned live agent or discover a
resumable Codex or Claude session. Capability rows advertise history, resume,
fork, approvals, questions, usage, file changes, diff, and the M1 controls.
Unsupported provider behavior remains representable with an unavailable flag
and reason rather than a destructive emulation.

## Human callback rendezvous

Provider callback objects never cross into Lua. The runtime retains the native
Codex server request or Claude worker callback in a memory-only pending map and
publishes a broker UUID plus normalized presentation fields:

- provider, tool/action, summary, command, cwd, and affected paths;
- provider risk or permission suggestions when supplied;
- only the decisions supported by that request; and
- structured questions, options, multi-select, and secret-input markers.

The public provider envelope identifies the provider method but redacts the raw
callback parameters. The native object is removed after a definitive provider
response. The resolution event contains only the broker ID, decision, and a
short broker reason.

Codex approvals are translated to the exact pinned App Server response shape,
including command/file accept or decline, legacy approval variants, and scoped
permission grants. Codex question answers become App Server answer records.
Claude decisions are translated to private worker callback responses and then
to the pinned Agent SDK callback result types by the Python worker.

A callback defaults to denial or cancellation on timeout, interrupt, runtime
shutdown, provider failure, malformed input, or Neovim disconnect. Unsupported
`defer` remains an error and leaves the request pending; a failed provider
response also remains pending unless provider state proves resolution.

The model gives pending requests stable IDs. A new request focuses a dedicated
decision buffer containing provider, session, workspace strategy, action, and
affected paths. Ordinary streaming renders update other scratch buffers and do
not replace that focused decision. `a` allows only a focused approval, `d`
denies only a focused request, and `<CR>` answers only a focused question.

## Explicit editor context

Context is selected by the operator. Lua can capture a loaded file buffer,
visual range, diagnostics, or its Git diff. Buffer/range payloads include the
canonical path, filetype, changed tick, text, and an explicit unsaved marker.
Capture never writes the buffer.

The broker independently validates each context item:

- its path is absolute, canonicalizable, and inside the agent cwd;
- its kind is `buffer`, `range`, `diagnostics`, or `diff`;
- the required text, diagnostics, or diff field has the correct shape;
- no item or combined one-shot queue exceeds 512 KiB; and
- at most 256 items are accepted.

Queued context is prepended to the next prompt or steer as a delimited JSON
snapshot and then cleared. It is not silently reused on later turns. Direct
input attachments pass through the same validation and size limits.

`agent/diff` runs Git as an argv child without a shell or external
diff/text-conversion commands, with a five-second timeout and a two-MiB output
cap. Neovim renders repository and buffer/disk diffs as untrusted
scratch-buffer text.

## Dirty buffers and file events

Lua observes normalized `file.changed` paths only inside the selected agent's
cwd. Agent Manager scratch/input buffers and other special buffers are ignored.

- A loaded unmodified file uses normal `checktime` handling.
- A modified file is never reloaded automatically.
- A dirty external change records a buffer/disk conflict and displays a
  warning in the agent rail.
- The operator can inspect the buffer, show a unified disk/buffer diff, confirm
  an explicit `edit!` reload, or keep the dirty buffer.

The keep action acknowledges the current notification without saving or
overwriting either side. A later file event creates a fresh unresolved
conflict.

## Native presentation

M2 remains dependency-free native Neovim UI. Stable scratch buffers now include
decision and diff views alongside agents, conversation, and activity. All
disable swap, modelines, undo files, and direct modification. Capability rows
appear with each selected agent; the latest provider-native usage object is
flattened deterministically in the activity pane. Rendering never evaluates
provider text as Lua, Ex, mappings, options, or modelines.

M3 still owns Foundation, Styling, Panels, and Chrome integration. M4 owns the
Unix socket, persistent registry, reconnect/replay recovery, multiple live
agents, and enforced writable-worktree isolation.

## Acceptance evidence

The default gate remains deterministic and offline:

- Rust pipe tests exercise Codex and Claude session discovery, start, specific
  resume, fork, history, explicit context, approval, question, usage, file
  events, follow-up, steer, interrupt, replay, and shutdown.
- Separate timeout and interrupt tests hold both provider callbacks unanswered
  and prove the provider receives denial while the public request resolves
  fail-closed.
- Headless Neovim tests exercise the session facade, capability and usage
  rendering, focused approval/question controls, unsupported-defer behavior,
  explicit unsaved context, dirty-buffer preservation, conflict resolution,
  history, diff, fork, and specific resume.
- Protocol fixtures cover session discovery and M2 response/context request
  shapes, while rejection cases exclude fabricated approval choices and
  invalid question decisions.

No live provider turn, credential, authentication state, or provider quota is
used by `mise run verify`.
