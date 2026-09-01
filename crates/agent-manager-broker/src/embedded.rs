//! Embedded public JSON-RPC broker served over stdio.

use std::collections::HashMap;
use std::io;
use std::path::{Path, PathBuf};
use std::time::Duration;

use serde::Deserialize;
use serde_json::{Value, json};
use thiserror::Error;
use time::OffsetDateTime;
use time::format_description::well_known::Rfc3339;
use tokio::io::{AsyncBufRead, AsyncWrite, AsyncWriteExt};
use tokio::sync::mpsc;
use tokio::task::{JoinError, JoinHandle};
use uuid::Uuid;

use crate::BROKER_VERSION;
use crate::codex::{CommandSpec, PINNED_CODEX_VERSION};
use crate::framing::{BoundedFrame, read_bounded_line};
use crate::protocol::{
    AgentState, AgentSummary, Capability, CapabilityName, EventEnvelope, PROTOCOL_VERSION,
    Provider, RequestId, WorkspaceStrategy,
};
use crate::replay::{ReplayBuffer, ReplayResult};
use crate::runtime::{AgentCommand, RuntimeConfig, RuntimeEvent, spawn_agent};
use crate::worker::{PINNED_CLAUDE_CODE_VERSION, PINNED_CLAUDE_SDK_VERSION, WorkerCommandSpec};

const MAX_PUBLIC_FRAME_BYTES: usize = 8 * 1024 * 1024;
const DEFAULT_REPLAY_CAPACITY: usize = 2_000;
const SHUTDOWN_TIMEOUT: Duration = Duration::from_secs(5);

#[derive(Clone, Debug)]
pub struct EmbeddedConfig {
    runtime: RuntimeConfig,
    replay_capacity: usize,
}

impl Default for EmbeddedConfig {
    fn default() -> Self {
        Self {
            runtime: RuntimeConfig::default(),
            replay_capacity: DEFAULT_REPLAY_CAPACITY,
        }
    }
}

impl EmbeddedConfig {
    #[must_use]
    pub fn with_claude_python(mut self, python: impl Into<String>) -> Self {
        self.runtime.claude = WorkerCommandSpec {
            program: python.into(),
            args: vec![
                "-I".to_owned(),
                "-m".to_owned(),
                "agent_manager_claude_worker".to_owned(),
            ],
        };
        self
    }

    #[doc(hidden)]
    #[must_use]
    pub fn with_provider_commands(mut self, codex: CommandSpec, claude: WorkerCommandSpec) -> Self {
        self.runtime = RuntimeConfig { codex, claude };
        self
    }
}

#[derive(Debug, Error)]
pub enum EmbeddedError {
    #[error("embedded broker I/O failed: {0}")]
    Io(#[from] io::Error),
    #[error("embedded broker task failed: {0}")]
    Join(#[from] JoinError),
    #[error("embedded broker serialization failed: {0}")]
    Json(#[from] serde_json::Error),
}

pub async fn serve<R, W>(reader: R, writer: W, config: EmbeddedConfig) -> Result<(), EmbeddedError>
where
    R: AsyncBufRead + Send + Unpin + 'static,
    W: AsyncWrite + Send + Unpin + 'static,
{
    let (input_tx, input_rx) = mpsc::unbounded_channel();
    let input_handle = tokio::spawn(read_client(reader, input_tx));
    let (output_tx, output_rx) = mpsc::unbounded_channel();
    let output_handle = tokio::spawn(write_client(writer, output_rx));
    let (runtime_tx, runtime_rx) = mpsc::unbounded_channel();

    let mut broker = Broker::new(config, output_tx, runtime_tx);
    let broker_result = broker.run(input_rx, runtime_rx).await;
    broker.shutdown_agents().await;
    drop(broker.output);

    input_handle.abort();
    let _ = input_handle.await;
    output_handle.await??;
    broker_result
}

#[derive(Debug)]
enum ClientInput {
    Frame(Value),
    ParseError,
    FrameTooLarge,
    Io(io::Error),
    Closed,
}

async fn read_client<R>(mut reader: R, input: mpsc::UnboundedSender<ClientInput>)
where
    R: AsyncBufRead + Unpin,
{
    loop {
        let frame = match read_bounded_line(&mut reader, MAX_PUBLIC_FRAME_BYTES).await {
            Ok(frame) => frame,
            Err(error) => {
                let _ = input.send(ClientInput::Io(error));
                return;
            }
        };
        match frame {
            BoundedFrame::Closed => {
                let _ = input.send(ClientInput::Closed);
                return;
            }
            BoundedFrame::TooLarge => {
                let _ = input.send(ClientInput::FrameTooLarge);
                return;
            }
            BoundedFrame::Data(mut data) => {
                while matches!(data.last(), Some(b'\n' | b'\r')) {
                    data.pop();
                }
                match serde_json::from_slice(&data) {
                    Ok(value) => {
                        if input.send(ClientInput::Frame(value)).is_err() {
                            return;
                        }
                    }
                    Err(_) => {
                        if input.send(ClientInput::ParseError).is_err() {
                            return;
                        }
                    }
                }
            }
        }
    }
}

async fn write_client<W>(
    mut writer: W,
    mut output: mpsc::UnboundedReceiver<Value>,
) -> Result<(), EmbeddedError>
where
    W: AsyncWrite + Unpin,
{
    while let Some(message) = output.recv().await {
        let mut frame = serde_json::to_vec(&message)?;
        frame.push(b'\n');
        writer.write_all(&frame).await?;
        writer.flush().await?;
    }
    Ok(())
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
enum ConnectionPhase {
    AwaitInitialize,
    AwaitInitialized,
    Ready,
}

struct ManagedAgent {
    summary: AgentSummary,
    commands: mpsc::Sender<AgentCommand>,
    task: Option<JoinHandle<()>>,
}

struct Broker {
    phase: ConnectionPhase,
    config: EmbeddedConfig,
    agents: HashMap<String, ManagedAgent>,
    agent_order: Vec<String>,
    replay: ReplayBuffer,
    output: mpsc::UnboundedSender<Value>,
    runtime: mpsc::UnboundedSender<RuntimeEvent>,
}

impl Broker {
    fn new(
        config: EmbeddedConfig,
        output: mpsc::UnboundedSender<Value>,
        runtime: mpsc::UnboundedSender<RuntimeEvent>,
    ) -> Self {
        Self {
            phase: ConnectionPhase::AwaitInitialize,
            replay: ReplayBuffer::new(config.replay_capacity),
            config,
            agents: HashMap::new(),
            agent_order: Vec::new(),
            output,
            runtime,
        }
    }

    async fn run(
        &mut self,
        mut input: mpsc::UnboundedReceiver<ClientInput>,
        mut runtime: mpsc::UnboundedReceiver<RuntimeEvent>,
    ) -> Result<(), EmbeddedError> {
        loop {
            tokio::select! {
                client = input.recv() => {
                    let Some(client) = client else {
                        return Ok(());
                    };
                    match client {
                        ClientInput::Frame(frame) => {
                            if self.handle_client_frame(frame).await? {
                                return Ok(());
                            }
                        }
                        ClientInput::ParseError => self.send(error_response(
                            None,
                            -32_700,
                            "Parse error",
                            None,
                        )),
                        ClientInput::FrameTooLarge => {
                            self.send(error_response(
                                None,
                                -32_600,
                                "Invalid Request",
                                Some(json!({ "reason": "frame_too_large" })),
                            ));
                            return Ok(());
                        }
                        ClientInput::Io(error) => return Err(EmbeddedError::Io(error)),
                        ClientInput::Closed => return Ok(()),
                    }
                }
                provider = runtime.recv() => {
                    let Some(provider) = provider else {
                        return Ok(());
                    };
                    self.handle_runtime_event(provider);
                }
            }
        }
    }

    async fn handle_client_frame(&mut self, frame: Value) -> Result<bool, EmbeddedError> {
        let Some(object) = frame.as_object() else {
            self.send(error_response(None, -32_600, "Invalid Request", None));
            return Ok(false);
        };
        if object.get("jsonrpc").and_then(Value::as_str) != Some("2.0") {
            self.send(error_response(None, -32_600, "Invalid Request", None));
            return Ok(false);
        }
        let Some(method) = object.get("method").and_then(Value::as_str) else {
            self.send(error_response(None, -32_600, "Invalid Request", None));
            return Ok(false);
        };
        let params = object.get("params").cloned().unwrap_or_else(|| json!({}));
        if !params.is_object() {
            let response_id = object
                .get("id")
                .cloned()
                .and_then(|id| serde_json::from_value(id).ok());
            self.send(error_response(response_id, -32_602, "Invalid params", None));
            return Ok(false);
        }

        let Some(raw_id) = object.get("id") else {
            self.handle_notification(method, &params);
            return Ok(false);
        };
        let Ok(request_id) = serde_json::from_value::<RequestId>(raw_id.clone()) else {
            self.send(error_response(None, -32_600, "Invalid Request", None));
            return Ok(false);
        };
        self.handle_request(request_id, method, params).await
    }

    fn handle_notification(&mut self, method: &str, params: &Value) {
        if self.phase == ConnectionPhase::AwaitInitialized
            && method == "initialized"
            && params.as_object().is_some_and(serde_json::Map::is_empty)
        {
            self.phase = ConnectionPhase::Ready;
            self.notify_state();
        }
    }

    async fn handle_request(
        &mut self,
        request_id: RequestId,
        method: &str,
        params: Value,
    ) -> Result<bool, EmbeddedError> {
        if self.phase == ConnectionPhase::AwaitInitialize {
            if method != "initialize" {
                self.send(error_response(
                    Some(request_id),
                    -32_002,
                    "Broker is not initialized",
                    None,
                ));
                return Ok(false);
            }
            return Ok(self.initialize(request_id, params));
        }
        if self.phase == ConnectionPhase::AwaitInitialized {
            self.send(error_response(
                Some(request_id),
                -32_003,
                "Broker is waiting for initialized",
                None,
            ));
            return Ok(false);
        }

        match method {
            "initialize" => self.send(error_response(
                Some(request_id),
                -32_004,
                "Broker is already initialized",
                None,
            )),
            "agent/list" => self.send(success_response(
                request_id,
                json!({ "agents": self.summaries() }),
            )),
            "agent/start" => self.start_agent(request_id, params),
            "agent/attach" => self.attach_agent(request_id, params),
            "agent/prompt" => {
                self.send_agent_input(request_id, params, InputKind::Prompt)
                    .await;
            }
            "agent/steer" => {
                self.send_agent_input(request_id, params, InputKind::Steer)
                    .await;
            }
            "agent/interrupt" => self.interrupt_agent(request_id, params).await,
            "agent/replay" => self.replay(request_id, params),
            "broker/shutdown" => {
                if !params.as_object().is_some_and(serde_json::Map::is_empty) {
                    self.send(invalid_params(request_id, "params must be empty"));
                    return Ok(false);
                }
                self.send(success_response(request_id, json!({ "shutdown": true })));
                return Ok(true);
            }
            "agent/history"
            | "agent/resume"
            | "agent/fork"
            | "agent/archive"
            | "agent/approval/respond"
            | "agent/question/respond"
            | "agent/context/add"
            | "agent/diff" => self.send(error_response(
                Some(request_id),
                -32_010,
                "Method is planned for a later milestone",
                None,
            )),
            _ => self.send(error_response(
                Some(request_id),
                -32_601,
                "Method not found",
                None,
            )),
        }
        Ok(false)
    }

    fn initialize(&mut self, request_id: RequestId, params: Value) -> bool {
        let Ok(parsed) = serde_json::from_value::<InitializeParams>(params) else {
            self.send(invalid_params(request_id, "invalid initialize parameters"));
            return false;
        };
        if parsed.protocol_version != PROTOCOL_VERSION
            || parsed.client.name.is_empty()
            || parsed.client.version.is_empty()
        {
            self.send(invalid_params(
                request_id,
                "unsupported protocol or empty client identity",
            ));
            return false;
        }
        self.phase = ConnectionPhase::AwaitInitialized;
        self.send(success_response(
            request_id,
            json!({
                "protocol_version": PROTOCOL_VERSION,
                "broker_version": BROKER_VERSION,
                "mode": "embedded",
                "providers": {
                    "codex": { "app_server_version": PINNED_CODEX_VERSION },
                    "claude": {
                        "agent_sdk_version": PINNED_CLAUDE_SDK_VERSION,
                        "claude_code_version": PINNED_CLAUDE_CODE_VERSION,
                    }
                },
                "replay": { "capacity": self.config.replay_capacity },
            }),
        ));
        false
    }

    fn start_agent(&mut self, request_id: RequestId, params: Value) {
        if !self.agents.is_empty() {
            self.send(error_response(
                Some(request_id),
                -32_011,
                "M1 embedded mode supports one agent",
                None,
            ));
            return;
        }
        let Ok(parsed) = serde_json::from_value::<StartParams>(params) else {
            self.send(invalid_params(request_id, "invalid start parameters"));
            return;
        };
        if parsed
            .provider_options
            .as_ref()
            .is_some_and(|options| !options.is_empty())
        {
            self.send(invalid_params(
                request_id,
                "provider options are not available in M1",
            ));
            return;
        }
        let cwd = match canonical_directory(&parsed.cwd) {
            Ok(cwd) => cwd,
            Err(message) => {
                self.send(invalid_params(request_id, message));
                return;
            }
        };
        let worktree_path = match validate_workspace(
            parsed.workspace_strategy,
            parsed.worktree_path.as_deref(),
            &cwd,
        ) {
            Ok(path) => path,
            Err(message) => {
                self.send(invalid_params(request_id, message));
                return;
            }
        };

        let agent_id = Uuid::new_v4().to_string();
        let now = timestamp();
        let title = cwd
            .file_name()
            .and_then(|name| name.to_str())
            .map_or_else(|| parsed.provider.to_string(), str::to_owned);
        let summary = AgentSummary {
            id: agent_id.clone(),
            provider: parsed.provider,
            provider_session_id: None,
            cwd: cwd.to_string_lossy().into_owned(),
            workspace_strategy: parsed.workspace_strategy,
            worktree_path,
            title,
            state: AgentState::Starting,
            active_turn_id: None,
            pending_approvals: 0,
            unread_events: 0,
            capabilities: capabilities(parsed.provider),
            created_at: now.clone(),
            updated_at: now,
        };
        let (commands, task) = spawn_agent(
            parsed.provider,
            agent_id.clone(),
            cwd,
            request_id,
            self.config.runtime.clone(),
            self.runtime.clone(),
        );
        self.agent_order.push(agent_id.clone());
        self.agents.insert(
            agent_id,
            ManagedAgent {
                summary,
                commands,
                task: Some(task),
            },
        );
        self.notify_state();
    }

    fn attach_agent(&self, request_id: RequestId, params: Value) {
        let Some(agent_id) = parse_agent_id(params) else {
            self.send(invalid_params(request_id, "invalid agent id parameters"));
            return;
        };
        let Some(agent) = self.agents.get(&agent_id) else {
            self.send(agent_not_found(request_id));
            return;
        };
        self.send(success_response(
            request_id,
            json!({ "agent": agent.summary }),
        ));
    }

    async fn send_agent_input(&mut self, request_id: RequestId, params: Value, kind: InputKind) {
        let Ok(parsed) = serde_json::from_value::<TurnInputParams>(params) else {
            self.send(invalid_params(request_id, "invalid turn input parameters"));
            return;
        };
        if parsed.input.text.is_empty() {
            self.send(invalid_params(request_id, "input text must not be empty"));
            return;
        }
        if !parsed.input.attachments.is_empty() {
            self.send(error_response(
                Some(request_id),
                -32_012,
                "Editor attachments are planned for M2",
                None,
            ));
            return;
        }
        let Some(agent) = self.agents.get_mut(&parsed.agent_id) else {
            self.send(agent_not_found(request_id));
            return;
        };
        let allowed = match kind {
            InputKind::Prompt => matches!(
                agent.summary.state,
                AgentState::Idle | AgentState::Completed | AgentState::Interrupted
            ),
            InputKind::Steer => agent.summary.state == AgentState::Running,
        };
        if !allowed {
            self.send(error_response(
                Some(request_id),
                -32_013,
                "Agent state does not allow this input",
                None,
            ));
            return;
        }
        let command = match kind {
            InputKind::Prompt => AgentCommand::Prompt {
                request_id: request_id.clone(),
                text: parsed.input.text,
            },
            InputKind::Steer => AgentCommand::Steer {
                request_id: request_id.clone(),
                text: parsed.input.text,
            },
        };
        if agent.commands.send(command).await.is_err() {
            agent.summary.state = AgentState::Disconnected;
            agent.summary.updated_at = timestamp();
            self.send(error_response(
                Some(request_id),
                -32_020,
                "Provider command channel is unavailable",
                None,
            ));
            self.notify_state();
            return;
        }
        if kind == InputKind::Prompt {
            agent.summary.state = AgentState::Running;
            agent.summary.updated_at = timestamp();
            self.notify_state();
        }
    }

    async fn interrupt_agent(&mut self, request_id: RequestId, params: Value) {
        let Some(agent_id) = parse_agent_id(params) else {
            self.send(invalid_params(request_id, "invalid agent id parameters"));
            return;
        };
        let Some(agent) = self.agents.get_mut(&agent_id) else {
            self.send(agent_not_found(request_id));
            return;
        };
        if agent
            .commands
            .send(AgentCommand::Interrupt {
                request_id: request_id.clone(),
            })
            .await
            .is_err()
        {
            agent.summary.state = AgentState::Disconnected;
            agent.summary.updated_at = timestamp();
            self.send(error_response(
                Some(request_id),
                -32_020,
                "Provider command channel is unavailable",
                None,
            ));
            self.notify_state();
        }
    }

    fn replay(&self, request_id: RequestId, params: Value) {
        let Ok(parsed) = serde_json::from_value::<ReplayParams>(params) else {
            self.send(invalid_params(request_id, "invalid replay parameters"));
            return;
        };
        match self.replay.replay_after(parsed.after_sequence) {
            ReplayResult::Events(events) => {
                self.send(success_response(request_id, json!({ "events": events })));
            }
            ReplayResult::ResyncRequired { oldest, latest } => self.send(error_response(
                Some(request_id),
                -32_014,
                "Replay cursor is outside the retained window",
                Some(json!({ "oldest": oldest, "latest": latest })),
            )),
        }
    }

    fn handle_runtime_event(&mut self, runtime: RuntimeEvent) {
        match runtime {
            RuntimeEvent::Started {
                request_id,
                agent_id,
                provider_session_id,
            } => {
                let summary = {
                    let Some(agent) = self.agents.get_mut(&agent_id) else {
                        return;
                    };
                    agent.summary.provider_session_id = Some(provider_session_id);
                    agent.summary.state = AgentState::Idle;
                    agent.summary.updated_at = timestamp();
                    agent.summary.clone()
                };
                self.send(success_response(request_id, json!({ "agent": summary })));
                self.notify_state();
            }
            RuntimeEvent::Response { request_id, result } => {
                self.send(success_response(request_id, result));
            }
            RuntimeEvent::RequestFailed {
                request_id,
                agent_id,
                code,
                message,
            } => {
                if let Some(agent) = self.agents.get_mut(&agent_id) {
                    agent.summary.state = AgentState::Failed;
                    agent.summary.active_turn_id = None;
                    agent.summary.updated_at = timestamp();
                }
                self.send(error_response(Some(request_id), code, message, None));
                self.notify_state();
            }
            RuntimeEvent::ProviderEvent(mut event) => {
                let sequence = self.replay.push(event.clone());
                event.sequence = sequence;
                let state_changed = self.apply_event_state(&event);
                self.send(json!({
                    "jsonrpc": "2.0",
                    "method": "agent/event",
                    "params": event,
                }));
                if state_changed {
                    self.notify_state();
                }
            }
            RuntimeEvent::ProviderFailed { agent_id, message } => {
                if let Some(agent) = self.agents.get_mut(&agent_id) {
                    agent.summary.state = AgentState::Disconnected;
                    agent.summary.active_turn_id = None;
                    agent.summary.updated_at = timestamp();
                    let mut event = EventEnvelope::new(
                        timestamp(),
                        agent_id,
                        agent.summary.provider,
                        "broker.error".to_owned(),
                        json!({ "message": message }),
                        json!({ "kind": "broker", "redacted": true }),
                    );
                    let sequence = self.replay.push(event.clone());
                    event.sequence = sequence;
                    self.send(json!({
                        "jsonrpc": "2.0",
                        "method": "agent/event",
                        "params": event,
                    }));
                    self.notify_state();
                }
            }
            RuntimeEvent::Stopped { agent_id } => {
                if let Some(agent) = self.agents.get_mut(&agent_id)
                    && agent.summary.state != AgentState::Disconnected
                {
                    agent.summary.state = AgentState::Disconnected;
                    agent.summary.active_turn_id = None;
                    agent.summary.updated_at = timestamp();
                    self.notify_state();
                }
            }
        }
    }

    fn apply_event_state(&mut self, event: &EventEnvelope) -> bool {
        let Some(agent) = self.agents.get_mut(&event.agent_id) else {
            return false;
        };
        let previous_state = agent.summary.state;
        let previous_turn = agent.summary.active_turn_id.clone();
        match event.event_type.as_str() {
            "turn.started" => {
                agent.summary.state = AgentState::Running;
                agent.summary.active_turn_id = event
                    .payload
                    .get("turn")
                    .and_then(|turn| turn.get("id"))
                    .or_else(|| event.payload.get("turnId"))
                    .and_then(Value::as_str)
                    .map(str::to_owned);
            }
            "turn.completed" => {
                agent.summary.state = if event.payload["turn"]["status"] == "interrupted"
                    || event.payload["subtype"] == "interrupted"
                {
                    AgentState::Interrupted
                } else {
                    AgentState::Completed
                };
                agent.summary.active_turn_id = None;
            }
            "turn.failed" => {
                agent.summary.state = AgentState::Failed;
                agent.summary.active_turn_id = None;
            }
            _ => {}
        }
        let changed =
            previous_state != agent.summary.state || previous_turn != agent.summary.active_turn_id;
        if changed {
            agent.summary.updated_at = timestamp();
        }
        changed
    }

    fn summaries(&self) -> Vec<AgentSummary> {
        self.agent_order
            .iter()
            .filter_map(|agent_id| self.agents.get(agent_id))
            .map(|agent| agent.summary.clone())
            .collect()
    }

    fn notify_state(&self) {
        self.send(json!({
            "jsonrpc": "2.0",
            "method": "broker/state",
            "params": { "agents": self.summaries() },
        }));
    }

    fn send(&self, message: Value) {
        let _ = self.output.send(message);
    }

    async fn shutdown_agents(&mut self) {
        for agent in self.agents.values() {
            let _ = agent.commands.send(AgentCommand::Shutdown).await;
        }
        for agent in self.agents.values_mut() {
            let Some(mut task) = agent.task.take() else {
                continue;
            };
            if tokio::time::timeout(SHUTDOWN_TIMEOUT, &mut task)
                .await
                .is_err()
            {
                task.abort();
                let _ = task.await;
            }
        }
    }
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
enum InputKind {
    Prompt,
    Steer,
}

#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
struct InitializeParams {
    protocol_version: u32,
    client: ClientIdentity,
    #[serde(default, rename = "last_sequence")]
    _last_sequence: Option<u64>,
}

#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
struct ClientIdentity {
    name: String,
    #[serde(default, rename = "title")]
    _title: Option<String>,
    version: String,
}

#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
struct StartParams {
    provider: Provider,
    cwd: String,
    workspace_strategy: WorkspaceStrategy,
    #[serde(default)]
    worktree_path: Option<String>,
    #[serde(default)]
    provider_options: Option<serde_json::Map<String, Value>>,
}

#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
struct AgentIdParams {
    agent_id: String,
}

#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
struct TurnInputParams {
    agent_id: String,
    input: TurnInput,
}

#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
struct TurnInput {
    text: String,
    attachments: Vec<Value>,
}

#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
struct ReplayParams {
    after_sequence: u64,
}

fn parse_agent_id(params: Value) -> Option<String> {
    serde_json::from_value::<AgentIdParams>(params)
        .ok()
        .map(|params| params.agent_id)
        .filter(|agent_id| !agent_id.is_empty())
}

fn canonical_directory(raw: &str) -> Result<PathBuf, &'static str> {
    let path = Path::new(raw);
    if !path.is_absolute() {
        return Err("cwd must be absolute");
    }
    let canonical = path.canonicalize().map_err(|_| "cwd does not exist")?;
    if !canonical.is_dir() {
        return Err("cwd must identify a directory");
    }
    Ok(canonical)
}

fn validate_workspace(
    strategy: WorkspaceStrategy,
    worktree_path: Option<&str>,
    cwd: &Path,
) -> Result<Option<String>, &'static str> {
    match strategy {
        WorkspaceStrategy::Shared if worktree_path.is_none() => Ok(None),
        WorkspaceStrategy::Shared => Err("shared strategy cannot specify worktree_path"),
        WorkspaceStrategy::Worktree => {
            let Some(raw) = worktree_path else {
                return Err("worktree strategy requires worktree_path");
            };
            let worktree = canonical_directory(raw)?;
            if worktree != cwd {
                return Err("M1 requires worktree_path to equal cwd");
            }
            Ok(Some(worktree.to_string_lossy().into_owned()))
        }
    }
}

fn capabilities(provider: Provider) -> Vec<Capability> {
    let later = |name| Capability {
        name,
        available: false,
        reason: Some("planned for a later milestone".to_owned()),
    };
    vec![
        available(CapabilityName::Streaming),
        available(CapabilityName::MultiTurn),
        later(CapabilityName::History),
        later(CapabilityName::Resume),
        later(CapabilityName::Fork),
        available(CapabilityName::Interrupt),
        available(CapabilityName::Steer),
        later(CapabilityName::Approvals),
        later(CapabilityName::Questions),
        Capability {
            name: CapabilityName::Usage,
            available: true,
            reason: None,
        },
        Capability {
            name: CapabilityName::FileChanges,
            available: provider == Provider::Codex,
            reason: (provider == Provider::Claude)
                .then(|| "Claude file projection is planned for M2".to_owned()),
        },
        later(CapabilityName::Diff),
        available(CapabilityName::Replay),
    ]
}

const fn available(name: CapabilityName) -> Capability {
    Capability {
        name,
        available: true,
        reason: None,
    }
}

fn timestamp() -> String {
    OffsetDateTime::now_utc()
        .format(&Rfc3339)
        .unwrap_or_else(|_| "1970-01-01T00:00:00Z".to_owned())
}

fn success_response(id: RequestId, result: Value) -> Value {
    let mut response = serde_json::Map::new();
    response.insert("jsonrpc".to_owned(), Value::String("2.0".to_owned()));
    response.insert(
        "id".to_owned(),
        serde_json::to_value(id).unwrap_or(Value::Null),
    );
    response.insert("result".to_owned(), result);
    Value::Object(response)
}

fn error_response(id: Option<RequestId>, code: i64, message: &str, data: Option<Value>) -> Value {
    let mut error = json!({ "code": code, "message": message });
    if let Some(data) = data {
        error["data"] = data;
    }
    let mut response = serde_json::Map::new();
    response.insert("jsonrpc".to_owned(), Value::String("2.0".to_owned()));
    response.insert(
        "id".to_owned(),
        serde_json::to_value(id).unwrap_or(Value::Null),
    );
    response.insert("error".to_owned(), error);
    Value::Object(response)
}

fn invalid_params(id: RequestId, reason: &str) -> Value {
    error_response(
        Some(id),
        -32_602,
        "Invalid params",
        Some(json!({ "reason": reason })),
    )
}

fn agent_not_found(id: RequestId) -> Value {
    error_response(Some(id), -32_015, "Agent was not found", None)
}

impl std::fmt::Display for Provider {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        formatter.write_str(match self {
            Self::Codex => "codex",
            Self::Claude => "claude",
        })
    }
}
