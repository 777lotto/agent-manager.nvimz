# agent-manager.nvimz

`agent-manager` is a standalone Neovim plugin for managing Codex
and Claude agents from one keyboard-first workspace. It targets Neovim running
inside the AI container over SSH: SSH carries keystrokes and terminal output,
while Neovim, agent processes, and repository files remain container-local.

Implementation is under way. The M0 contract spike now owns the versioned
public broker schema, the private Rust/Python worker schema, a Rust broker core,
the native Codex App Server process boundary, and the private Claude Agent SDK
worker. The editor UI intentionally begins in M1 after these contracts pass
their acceptance gates.

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

## M0 development

Toolchains are pinned by Mise and Python dependencies are locked by uv. The
ordinary test suite uses fake provider runtimes; it never consumes provider
quota or requires authentication.

```sh
mise install
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
python/                            private Claude Agent SDK worker package
protocol/broker/v1/                public Neovim/broker contract and fixtures
protocol/claude-worker/v1/         private Rust/Python contract and fixtures
protocol/vendor/codex/0.152.0/     generated provider schema baseline
docs/                              specification and architecture decisions
```

## Repository workflow

- `bet` is production/default.
- `bluff` is persistent integration.
- focused branches merge into `bluff`; verified milestones promote from
  `bluff` to `bet`.

Agent work uses broker-managed `agent/**` branches and pull requests into
`bluff`. Verified milestones promote from `bluff` to `bet`.
