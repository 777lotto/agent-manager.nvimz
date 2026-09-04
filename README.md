# agent-manager.nvimz

`agent-manager` is a standalone Neovim plugin for managing Codex
and Claude agents from one keyboard-first workspace. It targets Neovim running
inside the AI container over SSH: SSH carries keystrokes and terminal output,
while Neovim, agent processes, and repository files remain container-local.

M4 is complete. Durable mode keeps multiple Codex and Claude agents alive
across SSH and Neovim restarts through an owner-only Unix socket, bounded
replay, provider-backed history resync, and an archivable metadata-only
registry. New sessions default to lifecycle-managed worktrees selected by
repository and a stable session name. Shared-checkout starts are disabled by default;
an administrator may explicitly re-enable them. Embedded mode remains available as the
single-agent, Neovim-owned fallback. The M3 Foundation, Styling, Chrome, and
native presentation contracts remain unchanged. Ordinary verification uses
fake provider processes and never consumes provider quota.

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
    codex = {
      executable = "/absolute/path/to/codex",
    },
    claude = {
      python = "/absolute/path/to/agent-manager-worker-venv/bin/python",
    },
  },
  worktrees = {
    lifecycle = "/absolute/path/to/zemrip-agent-workspace",
    allow_shared = false,
  },
})
```

Durable mode connects to a broker already owned by the container lifecycle
manager. Its executable and socket paths must be absolute:

```lua
require("agent_manager").setup({
  broker = {
    mode = "durable",
    command = { "/home/ai/.local/bin/agent-manager-broker", "serve-durable" },
    socket = "/run/user/1000/agent-manager/broker.sock",
  },
  providers = {
    claude = {
      python = "/home/ai/.local/share/agent-manager/venv/bin/python",
    },
  },
})
```

The resumable unit installation, verification, and rollback phase is documented
in [ops/m4-durable-service](ops/m4-durable-service/README.md). Stable artifact
installation remains M5 work; the lifecycle phase intentionally refuses to
start until those reviewed paths exist.

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
:AgentManagerArchive
:AgentManagerDelete
:AgentManagerHealth
```

To start a session from the workspace:

1. Press `1` to focus Agents and place the cursor on the desired directory.
   The project where Agent Manager was opened is marked `[cwd]`; registered or
   already managed repositories are marked `[repo]`.
2. Press `sn` and choose Codex or Claude. `sn` always means “start a new
   session”; continuing old work is not mixed into this flow.
3. Enter a stable lowercase session name. Agent Manager creates the safe
   worktree for that repository and reports when the agent is ready.
4. Press `2`, then `tp`, to compose the first prompt.

Starting from another pane still works; Agent Manager asks which registered
repository to use. `:AgentManagerStart [codex|claude]` uses the current project
as the directory hint and follows the same managed-workspace flow. Prompting
without a selected agent now explains how to start one instead of accepting
input that cannot be sent.

The workspace maps `1`, `2`, and `3` directly to Agents, Conversation, and
Activity. `<Tab>` and `<S-Tab>` still cycle panes. Commands are grouped under
buffer-local prefixes: `s` for sessions (`sn`, `so`, `sf`, `sa`), `t` for the
current turn (`tp`, `ts`, `ti`, `tc`), `d` for diff/delete (`df`, `ds`), and
`g` for navigation/refresh (`ga`, `gc`, `gt`, `gr`, `g?`). `y` means yes/allow
and `n` means no/deny only for the focused human request. `<CR>` toggles a
directory, opens a file or session, or answers a question; `h` and `l` collapse
and expand tree rows. `q` closes only the view.

When `which-key.nvim` is available, Agent Manager registers those four prefixes
as buffer-local groups without requiring `<leader>`. Because `d`, `g`, `s`, and
`t` are built-in keys, a host that wants their menus to open automatically must
include them as normal-mode entries in which-key's `opts.triggers`; its
`<auto>` trigger intentionally skips existing built-ins. Agent Manager does not
call `which-key.show()` from a mapping, call which-key setup, or replace global
mappings. The key sequences still work when which-key is absent. Wide displays
show agents, conversation, and activity together; medium and narrow displays
switch the same buffers without losing model state.

The Agents pane is a lazy filesystem tree rooted at the full home path (for
example, `/home/ai/`). It includes ordinary files and directories whether or
not a session exists there; registered repositories and every discovered
Codex/Claude session—live or saved—are overlaid beneath their directory. Codex rows use
a blue `● CODEX` badge; Claude rows use an orange `◆ CLAUDE` badge, so provider
identity remains clear even when a theme does not preserve the intended color.
Green `● ACTIVE` labels identify live writers. Dark `○ RESUME` labels identify
saved sessions with no live writer; focus one and press `<CR>` or `so` to
continue it. A `? CHECK` label means activity could not be verified, so Agent
Manager will not risk opening a second writer. Sessions are discovered across
the AI container when the workspace opens and whenever `gr` refreshes the view. Set
`ui.external_sessions = false` to disable discovery, or lower
`ui.external_session_limit` from its default of 1000 to cap each provider
query.

### Runtime safety boundary

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

Embedded mode owns one live runtime and ends when its broker process exits. In
durable mode, closing Neovim disconnects only the editor client; provider tasks
continue under the lifecycle manager. Reconnect replays the retained event
suffix or reloads summaries and provider history when the cursor is too old.
Prompt input is never replayed. A fork retires its source runtime before opening
the provider fork so writer ownership remains unambiguous.

`ds` and `:AgentManagerDelete` permanently delete the focused provider's saved
session history after a second confirmation. The broker refuses deletion while
the session is active or a human request is pending. For a manager-owned idle
session it first retires the provider runtime and hands off any managed lease;
the Git worktree, branch, and project files are always preserved.

Opening the workspace and running the default test suite are non-spending. The
diagnostic `codex-probe` performs only initialization and thread discovery;
`codex-trace` starts a paid/live turn and therefore requires an explicit flag.
External CLI discovery is metadata-only: Agent Manager projects provider,
session ID, working directory, optional provider-supplied title, timestamp, and active
state. Prompt previews and tool payloads are discarded at the provider
boundary.

## Development

```sh
mise run setup
mise run verify
mise run ux-test
```

The M4 gate resolves registered UX checkouts automatically. Elsewhere,
set `UX_FOUNDATION_ROOT`, `UX_STYLING_ROOT`, and `UX_CHROME_ROOT` to checkouts
containing the promoted commits recorded in `tests/ux-pins.env`.

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
acceptance evidence. See
[M3 UX ecosystem integration](docs/architecture/m3-ux-ecosystem-integration.md)
for the immutable manifest, Styling discovery, Chrome cache, compatibility
pins, and acceptance evidence. See
[M4 durable multi-agent runtime](docs/architecture/m4-durable-multi-agent-runtime.md)
for socket lifecycle, replay/resync, registry privacy, writer isolation, and
acceptance evidence.
See
[external CLI session discovery](docs/architecture/external-cli-session-discovery.md)
for the cross-process activity checks and read-only ownership boundary.

## UX integration

The functional plugin supports native Neovim presentation without the UX suite.
The promoted schema-v1 integrations are:

- UX Foundation owns token resolution and persistence for the published plugin
  ID `agent.manager`.
- UX Styling discovers a pure presentation adapter and deterministic fixtures
  without starting the Agent Manager runtime or provider processes.
- UX Chrome retains sole ownership of tabline, statusline, winbar,
  statuscolumn, folds, and scrollbar surfaces. Its current public API has no
  segment extension, so external owners consume Agent Manager's non-blocking
  cache when desired.
- UX Panels is not yet available. The existing native view remains the narrow
  backend and health reports that decision explicitly.

### Managed worktrees and administrator policy

The normal `sn` flow only starts a new session. Repository choices and existing
workspace mappings come from the installed `zemrip-agent-workspace audit
--json` interface. A new session asks for one stable lowercase kebab-case name;
the broker atomically claims the resulting `agent/<name>` branch, lease, and
`~/worktrees/<repo>/<name>` checkout before it starts a provider. Continuing a
saved row reuses its mapped workspace; if its history came from a canonical
checkout, Agent Manager asks for a workspace name and safely moves the resumed
provider into that worktree. No raw worktree path is requested.

The lifecycle command remains the authority for Git fetches, branches, leases,
handoff, and cleanup. Agent Manager exposes inventory, claim/resume, and
non-destructive lease handoff only. It deliberately has no worktree reset,
checkout deletion, force-clean, or garbage-collection API. Provider-history
deletion is a separate operation and never removes Git state. Set `worktrees.lifecycle = false` to
disable managed starts. Set `worktrees.allow_shared = true` only when the
administrator intends to permit writable agents in coordination checkouts; the
embedded broker enforces the setting, and durable deployments enforce it with
the corresponding service flag.

### Provider runtime compatibility

Agent Manager no longer requires the executable on `PATH` to equal one exact
Codex release. The vendored 0.152.0 schemas are the reviewed lower-bound
baseline for the `codex-app-server-stable-v1` profile. At every start, the
adapter performs the stable App Server initialization handshake with
`experimentalApi = false`, reads the actual runtime version, and rejects a
runtime older than the baseline. Newer stable App Server releases remain usable
without changing a hard-coded pin; actual version, profile, and resolved
executable are recorded in the agent summary and durable registry.

The Claude worker follows the same pattern with the `claude-agent-sdk-v1`
profile. Its locked environment remains the reproducible tested baseline, while
the handshake reports and validates the SDK and SDK-bundled Claude Code versions
that are actually running. A different reviewed worker environment can be
selected with `providers.claude.python` without changing the public protocol.

Running provider processes are never hot-swapped. After an executable or worker
environment is upgraded, existing processes finish on their original runtime;
resuming a persisted provider session launches it through the currently
configured compatible runtime.

Cached consumers can call `status()`, `running_count()`, or
`pending_approval_count()`. State changes emit a coalesced
`User AgentManagerStateChanged` event carrying only those counts and stable
agent IDs—never prompt text or tool payloads.

Agent Manager remains a separate repository. `nvim-config` consumes an exact
tested commit from `bluff`; the M5 release and durable-service gates remain the
authority for packaged runtime adoption.

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
ops/m4-durable-service/            supervised lifecycle apply/undo/verify phase
```

## Repository workflow

- `bluff` is the default and only long-lived branch.
- focused branches start from and merge into `bluff`.
- signed `vX.Y.Z` tags and GitHub Releases mark tested `bluff` commits.

Agent work uses broker-managed `agent/**` branches and pull requests into
`bluff`. Brokered `zemrip-ai` commits use the expected unsigned agent identity;
workflow changes require an operator-approved one-use ticket. The broker cannot
push `bluff` or tags, publish Releases, or administer repository secrets.

Publishing a stable GitHub Release can notify `nvim-config` to test and pin the
exact tagged commit. The operator provisions the repository-scoped
`NVIM_CONFIG_DISPATCH_TOKEN`; the credential-free agent plane never receives
its value.
