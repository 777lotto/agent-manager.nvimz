# M1 embedded slice

- Status: implemented
- Reviewed: 2026-09-01
- Public broker protocol: 1
- Lifecycle mode: embedded stdio

M1 turns the frozen M0 contracts into one usable editor path. Neovim owns the
workspace view and a small asynchronous JSON-RPC client. The Rust broker owns
the public state machine, replay sequence, provider task, and child process.
Codex remains a native App Server child; Claude remains behind the private
Python worker.

```text
Neovim tab
  agents | conversation | activity
              |
              | JSON-RPC 2.0 JSONL over stdio
              v
       Rust embedded broker
          |             |
          v             v
   Codex App Server   Claude Python worker
```

## Runtime contract

The Lua client launches an argv list directly with piped stdin/stdout. It sends
`initialize`, verifies public protocol version 1, sends `initialized`, and then
accepts `broker/state` and sequenced `agent/event` notifications. It never runs
Cargo, uv, pip, or a shell during startup.

Embedded mode supports one agent and these public operations:

- `agent/list`, `agent/start`, and `agent/attach`;
- `agent/prompt`, `agent/steer`, and `agent/interrupt`;
- `agent/replay`; and
- `broker/shutdown`.

Methods belonging to later milestones return a structured error. The broker
canonicalizes the cwd, validates shared/worktree parameters, serializes commands
through a provider task, assigns every public event a monotonic sequence, and
keeps a bounded replay window in memory.

Provider callbacks are visible as activity but fail closed in M1. Codex server
requests receive the pinned App Server decline shape. Claude worker callbacks
receive a private deny response. No callback can become an implicit approval
because Neovim disconnects, a frame is malformed, or the UI is unavailable.

## Native workspace

`:AgentManager` opens a dedicated tab backed by three stable scratch buffers:

- agents show provider, precise state, and title;
- conversation projects user inputs and streamed assistant deltas; and
- activity preserves ordered tool and provider notices.

At 140 columns the three panes are visible. At 90–139 columns the agents rail
and one content pane are visible. Below 90 columns one pane is visible. `<Tab>`
cycles the same buffers in every mode, so responsive changes do not discard
projection state. All mappings are buffer-local. Scratch buffers disable swap,
undo files, and modelines; streamed provider text is inserted only as buffer
content and is never evaluated as Ex, Lua, a mapping, or an option.

Native `AgentManager*` highlights link to standard groups. M1 does not load or
write UX Foundation, Styling, Chrome, statusline, tabline, winbar,
statuscolumn, folds, or scrollbar state.

## Lifecycle and limitations

The broker is a child of the Neovim job. Closing only the workspace tab keeps
that child and its agent alive; `teardown()` or Neovim exit requests an orderly
broker shutdown. Embedded state is not durable across process exit. M4 owns
reconnect, persistence, a Unix socket, and multiple concurrent agents.

M1 intentionally does not expose approvals, questions, resume, fork, history,
diffs, attachments, or dirty-buffer coordination. It can run real turns, so a
prompt may consume provider quota. Credentials remain owned by the installed
Codex and Claude runtimes and never enter plugin configuration or protocol
diagnostics.

## Acceptance evidence

The default suite is deterministic and offline:

- Rust tests drive fake Codex and Claude children over real pipes and prove
  startup, tool activity, callback denial, three prompts, steering, interrupt,
  terminal state, sequence continuity, replay, and shutdown.
- Headless Neovim 0.12.4 drives the Lua job client against a fake public broker
  and proves negotiation, state/event projection, conversation coalescing,
  native buffer safety, rendering, controls, close, and teardown.
- The existing Python, schema, framing, formatting, lint, checksum, and
  redaction-oriented M0 gates remain part of `mise run verify`.

No live provider request is part of the handoff gate.
