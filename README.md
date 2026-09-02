# agent-manager.nvimz

`agent-manager` is a standalone Neovim plugin for managing Codex
and Claude agents from one keyboard-first workspace. It targets Neovim running
inside the AI container over SSH: SSH carries keystrokes and terminal output,
while Neovim, agent processes, and repository files remain container-local.

The M2 safe interactive workflow is usable now. Neovim starts the Rust broker
over stdio, the broker owns one live Codex or Claude session, and the native
workspace streams conversation, tool activity, file changes, and usage. It
supports provider session discovery, specific resume and fork, human
approvals, structured questions, explicit editor context, dirty-buffer conflict
handling, follow-up prompts, steering, interrupt, and bounded in-process
replay. Ordinary verification uses fake provider processes and never consumes
provider quota.

## Selected architecture

```text
Neovim plugin (Lua)
        |
        | JSON-RPC 2.0 over stdio or an owner-only Unix socket
        v
agent-manager broker (Rust)
        |-- native Codex adapter --> codex app-server
        `-- private stdio --> Claude worker (Python) --> Claude Agent SDK
                                                        --> Claude Code runtime
```

The Rust broker owns the public protocol, process supervision, normalized
state, replay, persistence, and the native Codex integration. The Python worker
owns only Claude SDK objects and callbacks. It has no network listener and no
independent durable registry.

This split uses the strongest supported boundary for each provider without
making the Neovim frontend provider-aware. Rust's benefit is predictable core
runtime behavior, not faster model generation; provider and model latency will
dominate. Python is appropriate at the Claude boundary because Anthropic's
official Agent SDK exposes the persistent client, interrupts, permissions,
session history, resume, and fork APIs needed by an interactive editor.

See the complete [Agent Manager specification](docs/spec.md), including the
broker/worker protocol, security model, delivery milestones, and UX
Foundation/Styling/Chrome integration plan.

## Install and verify

Toolchains are pinned by Mise and Python dependencies are locked by uv. The
ordinary test suite uses fake provider runtimes; it never consumes provider
quota or requires authentication.

```sh
mise install
mise run setup
mise run verify
cargo build --release -p agent-manager-broker
```

For a source checkout, Agent Manager discovers the release/debug broker and the
locked Python worker environment relative to the plugin root. A packaged
installation should put `agent-manager-broker` on `PATH` and configure the
installed worker Python explicitly:

```lua
require("agent_manager").setup({
  broker = {
    mode = "embedded",
    command = { "/absolute/path/to/agent-manager-broker", "serve" },
  },
  providers = {
    claude = {
      python = "/absolute/path/to/agent-manager-worker-venv/bin/python",
    },
  },
})
```

Then open Neovim and use:

```vim
:AgentManager
:AgentManagerStart codex
:AgentManagerAttach
:AgentManagerSend explain the current repository
:AgentManagerSteer focus on the failing tests
:AgentManagerInterrupt
:AgentManagerContext
:AgentManagerDiff
:AgentManagerFork
:AgentManagerHealth
```

The workspace also maps `n` to start, `h` to attach or resume, `p` to prompt,
`s` to steer, `x` to confirm an interrupt, `a`/`d` to decide only a focused
human request, `<CR>` to answer a focused question, `c` to queue explicit
context, `f` to fork, `D` to inspect diffs/conflicts, `<Tab>` to cycle panes,
and `q` to close only the view. Wide displays show agents, conversation, and
activity together; medium and narrow displays cycle the same buffers without
losing model state.

### M2 safety boundary

Live prompts use the provider account already configured for Codex or Claude
and can consume quota. Agent Manager never reads, prints, stores, or passes
provider credentials in arguments. Every approval is focused and shows the
provider, workspace, action, and affected paths supplied by the provider. Only
advertised decisions are mapped; timeout, cancellation, shutdown, malformed
input, and disconnect deny or cancel provider callbacks rather than approving.

Editor context is opt-in and one-shot. Buffer and range snapshots preserve an
explicit unsaved marker; Agent Manager does not save them. When a provider
reports a change to a loaded dirty buffer, Neovim never reloads it
automatically. The workspace records the divergence and offers inspect, diff,
explicit reload with confirmation, or keep-buffer actions.

Embedded mode still owns one live runtime and ends when its broker process
exits. A fork retires the source runtime, preserves its disconnected summary,
and opens the provider fork. Durable reconnect, multiple concurrent live
agents, writer isolation, and UX ecosystem integration remain M4/M3 work.

Opening the workspace and running the default test suite are non-spending. The
diagnostic `codex-probe` performs only initialization and thread discovery;
`codex-trace` starts a paid/live turn and therefore requires an explicit flag.

## Development

```sh
mise run setup
mise run verify
```

Useful diagnostic commands after a build:

```sh
cargo run -p agent-manager-broker -- contract-info
cargo run -p agent-manager-broker -- codex-probe --cwd "$PWD"
```

`codex-probe` performs only App Server initialization and thread discovery.
The live `codex-trace` command requires an explicit `--allow-live-provider`
flag and is never part of verification.

See [M0 contract decisions](docs/architecture/m0-contract-decisions.md) for the
frozen runtime versions, framing differences, and upgrade procedure.
See [M1 embedded slice](docs/architecture/m1-embedded-slice.md) for the current
runtime foundation. See
[M2 safe interactive workflow](docs/architecture/m2-safe-interactive-workflow.md)
for human callbacks, session lifecycle, editor context, filesystem safety, and
acceptance evidence.

## UX direction

The functional plugin will support native Neovim presentation without the UX
suite. Once those repositories are mature and their contracts are promoted:

- UX Foundation will own token resolution and persistence for the reserved
  plugin ID `agent.manager`.
- UX Styling will discover a pure, callback-free presentation adapter and
  deterministic fixtures without starting provider processes.
- UX Chrome will retain sole ownership of tabline, statusline, winbar,
  statuscolumn, folds, and scrollbar surfaces.
- A mature UX Panels package may provide the renderer primitives behind a
  narrow view interface.

Agent Manager remains a separate repository and will not be added to
`nvim-config` until its implementation acceptance gates pass.

## Repository layout

```text
crates/agent-manager-broker/       Rust protocol core and Codex/worker clients
lua/agent_manager/                  Neovim client, model, facade, and views
plugin/                             guarded Neovim command bootstrap
python/                            private Claude Agent SDK worker package
protocol/broker/v1/                public Neovim/broker contract and fixtures
protocol/claude-worker/v1/         private Rust/Python contract and fixtures
protocol/vendor/codex/0.152.0/     generated provider schema baseline
tests/                              headless Lua tests and fake public broker
docs/                              specification and architecture decisions
```

## Repository workflow

- `bet` is production/default.
- `bluff` is persistent integration.
- focused branches merge into `bluff`; verified milestones promote from
  `bluff` to `bet`.

Agent work uses broker-managed `agent/**` branches and pull requests into
`bluff`. Verified milestones promote from `bluff` to `bet`.
