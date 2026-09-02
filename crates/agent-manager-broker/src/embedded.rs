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
use crate::runtime::{
    AgentCommand, RuntimeConfig, RuntimeEvent, SessionLaunch, discover_sessions, spawn_agent,
};
use crate::worker::{PINNED_CLAUDE_CODE_VERSION, PINNED_CLAUDE_SDK_VERSION, WorkerCommandSpec};

const MAX_PUBLIC_FRAME_BYTES: usize = 8 * 1024 * 1024;
const DEFAULT_REPLAY_CAPACITY: usize = 2_000;
const SHUTDOWN_TIMEOUT: Duration = Duration::from_secs(5);
const DIFF_TIMEOUT: Duration = Duration::from_secs(5);
const MAX_CONTEXT_BYTES: usize = 512 * 1024;
const MAX_CONTEXT_ITEMS: usize = 256;
const MAX_DIFF_BYTES: usize = 2 * 1024 * 1024;

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
        self.runtime.codex = codex;
        self.runtime.claude = claude;
        self
    }

    #[doc(hidden)]
    #[must_use]
    pub fn with_callback_timeout(mut self, timeout: Duration) -> Self {
        self.runtime.callback_timeout = timeout;
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
    pending_contexts: Vec<Value>,
    pending_questions: u64,
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
            "provider/session/list" => self.provider_sessions(request_id, params).await,
            "agent/start" => self.start_agent(request_id, params, SessionLaunch::Start),
            "agent/attach" => self.attach_agent(request_id, params),
            "agent/history" => self.history(request_id, params).await,
            "agent/prompt" => {
                self.send_agent_input(request_id, params, InputKind::Prompt)
                    .await;
            }
            "agent/steer" => {
                self.send_agent_input(request_id, params, InputKind::Steer)
                    .await;
            }
            "agent/interrupt" => self.interrupt_agent(request_id, params).await,
            "agent/resume" => self.resume_agent(request_id, params),
            "agent/fork" => self.fork_agent(request_id, params).await,
            "agent/approval/respond" => self.respond_approval(request_id, params).await,
            "agent/question/respond" => self.respond_question(request_id, params).await,
            "agent/context/add" => self.add_context(request_id, params),
            "agent/diff" => self.diff(request_id, params).await,
            "agent/replay" => self.replay(request_id, params),
            "broker/shutdown" => {
                if !params.as_object().is_some_and(serde_json::Map::is_empty) {
                    self.send(invalid_params(request_id, "params must be empty"));
                    return Ok(false);
                }
                self.send(success_response(request_id, json!({ "shutdown": true })));
                return Ok(true);
            }
            "agent/archive" => self.send(error_response(
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

    async fn provider_sessions(&self, request_id: RequestId, params: Value) {
        let Ok(parsed) = serde_json::from_value::<ProviderSessionListParams>(params) else {
            self.send(invalid_params(
                request_id,
                "invalid provider session list parameters",
            ));
            return;
        };
        let cwd = match canonical_directory(&parsed.cwd) {
            Ok(cwd) => cwd,
            Err(message) => {
                self.send(invalid_params(request_id, message));
                return;
            }
        };
        let limit = parsed.limit.unwrap_or(50).clamp(1, 1_000);
        match discover_sessions(
            parsed.provider,
            &cwd,
            parsed.cursor.as_deref(),
            limit,
            &self.config.runtime,
        )
        .await
        {
            Ok(result) => self.send(success_response(request_id, result)),
            Err(message) => self.send(error_response(Some(request_id), -32_020, message, None)),
        }
    }

    fn start_agent(&mut self, request_id: RequestId, params: Value, launch: SessionLaunch) {
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
                "provider options are not available in M2",
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

        let _ = self.launch_agent(
            request_id,
            parsed.provider,
            cwd,
            parsed.workspace_strategy,
            worktree_path,
            launch,
        );
    }

    fn launch_agent(
        &mut self,
        request_id: RequestId,
        provider: Provider,
        cwd: PathBuf,
        workspace_strategy: WorkspaceStrategy,
        worktree_path: Option<String>,
        launch: SessionLaunch,
    ) -> Option<String> {
        if self.agents.values().any(|agent| agent.task.is_some()) {
            self.send(error_response(
                Some(request_id),
                -32_011,
                "M2 embedded mode supports one live agent",
                None,
            ));
            return None;
        }
        let agent_id = Uuid::new_v4().to_string();
        let now = timestamp();
        let title = cwd
            .file_name()
            .and_then(|name| name.to_str())
            .map_or_else(|| provider.to_string(), str::to_owned);
        let summary = AgentSummary {
            id: agent_id.clone(),
            provider,
            provider_session_id: None,
            cwd: cwd.to_string_lossy().into_owned(),
            workspace_strategy,
            worktree_path,
            title,
            state: AgentState::Starting,
            active_turn_id: None,
            pending_approvals: 0,
            unread_events: 0,
            capabilities: capabilities(provider),
            created_at: now.clone(),
            updated_at: now,
        };
        let (commands, task) = spawn_agent(
            provider,
            agent_id.clone(),
            cwd,
            request_id,
            launch,
            self.config.runtime.clone(),
            self.runtime.clone(),
        );
        self.agent_order.push(agent_id.clone());
        self.agents.insert(
            agent_id.clone(),
            ManagedAgent {
                summary,
                commands,
                task: Some(task),
                pending_contexts: Vec::new(),
                pending_questions: 0,
            },
        );
        self.notify_state();
        Some(agent_id)
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

    async fn history(&mut self, request_id: RequestId, params: Value) {
        let Ok(parsed) = serde_json::from_value::<HistoryParams>(params) else {
            self.send(invalid_params(request_id, "invalid history parameters"));
            return;
        };
        let Some(agent) = self.agents.get_mut(&parsed.agent_id) else {
            self.send(agent_not_found(request_id));
            return;
        };
        if agent.task.is_none() {
            self.send(error_response(
                Some(request_id),
                -32_013,
                "Agent is not live; resume the provider session before reading history",
                None,
            ));
            return;
        }
        if agent
            .commands
            .send(AgentCommand::History {
                request_id: request_id.clone(),
                cursor: parsed.cursor,
                limit: parsed.limit,
            })
            .await
            .is_err()
        {
            self.command_channel_failed(&parsed.agent_id, request_id);
        }
    }

    fn resume_agent(&mut self, request_id: RequestId, params: Value) {
        let Ok(parsed) = serde_json::from_value::<ResumeParams>(params) else {
            self.send(invalid_params(request_id, "invalid resume parameters"));
            return;
        };
        if parsed.provider_session_id.is_empty() {
            self.send(invalid_params(
                request_id,
                "provider session id must not be empty",
            ));
            return;
        }
        if parsed
            .provider_options
            .as_ref()
            .is_some_and(|options| !options.is_empty())
        {
            self.send(invalid_params(
                request_id,
                "provider options are not available in M2",
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
        let session_id = parsed.provider_session_id;
        let _ = self.launch_agent(
            request_id,
            parsed.provider,
            cwd,
            parsed.workspace_strategy,
            worktree_path,
            SessionLaunch::Resume(session_id),
        );
    }

    async fn fork_agent(&mut self, request_id: RequestId, params: Value) {
        let Some(source_id) = parse_agent_id(params) else {
            self.send(invalid_params(request_id, "invalid agent id parameters"));
            return;
        };
        let Some(source) = self.agents.get(&source_id) else {
            self.send(agent_not_found(request_id));
            return;
        };
        if !matches!(
            source.summary.state,
            AgentState::Idle | AgentState::Completed | AgentState::Interrupted
        ) || source.summary.pending_approvals > 0
            || source.pending_questions > 0
        {
            self.send(error_response(
                Some(request_id),
                -32_013,
                "Agent must be idle with no pending human request before it can be forked",
                None,
            ));
            return;
        }
        let Some(provider_session_id) = source.summary.provider_session_id.clone() else {
            self.send(error_response(
                Some(request_id),
                -32_013,
                "Agent has no provider session identity to fork",
                None,
            ));
            return;
        };
        let provider = source.summary.provider;
        let cwd = PathBuf::from(&source.summary.cwd);
        let strategy = source.summary.workspace_strategy;
        let worktree_path = source.summary.worktree_path.clone();
        let pending_contexts = source.pending_contexts.clone();
        self.retire_agent(&source_id).await;
        let forked_id = self.launch_agent(
            request_id,
            provider,
            cwd,
            strategy,
            worktree_path,
            SessionLaunch::Fork(provider_session_id),
        );
        if let Some(agent) = forked_id.and_then(|agent_id| self.agents.get_mut(&agent_id)) {
            agent.pending_contexts = pending_contexts;
        }
    }

    async fn retire_agent(&mut self, agent_id: &str) {
        let Some(agent) = self.agents.get_mut(agent_id) else {
            return;
        };
        let _ = agent.commands.send(AgentCommand::Shutdown).await;
        if let Some(mut task) = agent.task.take()
            && tokio::time::timeout(SHUTDOWN_TIMEOUT, &mut task)
                .await
                .is_err()
        {
            task.abort();
            let _ = task.await;
        }
        agent.summary.state = AgentState::Disconnected;
        agent.summary.active_turn_id = None;
        agent.summary.pending_approvals = 0;
        agent.pending_questions = 0;
        agent.pending_contexts.clear();
        agent.summary.updated_at = timestamp();
        self.notify_state();
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
        let cwd = Path::new(&agent.summary.cwd);
        let mut attachments = agent.pending_contexts.clone();
        for attachment in parsed.input.attachments {
            let attachment = match validate_context(attachment, cwd) {
                Ok(attachment) => attachment,
                Err(message) => {
                    self.send(invalid_params(request_id, message));
                    return;
                }
            };
            attachments.push(attachment);
        }
        if let Err(message) = validate_context_collection(&attachments) {
            self.send(invalid_params(request_id, message));
            return;
        }
        let command = match kind {
            InputKind::Prompt => AgentCommand::Prompt {
                request_id: request_id.clone(),
                text: parsed.input.text,
                attachments,
            },
            InputKind::Steer => AgentCommand::Steer {
                request_id: request_id.clone(),
                text: parsed.input.text,
                attachments,
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
        agent.pending_contexts.clear();
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

    async fn respond_approval(&mut self, request_id: RequestId, params: Value) {
        let Ok(parsed) = serde_json::from_value::<ApprovalResponseParams>(params) else {
            self.send(invalid_params(request_id, "invalid approval response"));
            return;
        };
        if !matches!(parsed.decision.as_str(), "allow" | "deny" | "defer") {
            self.send(invalid_params(request_id, "invalid approval decision"));
            return;
        }
        if parsed.agent_id.is_empty()
            || parsed.approval_id.is_empty()
            || parsed
                .updated_input
                .as_ref()
                .is_some_and(|value| !value.is_object())
            || parsed
                .message
                .as_ref()
                .is_some_and(|message| message.chars().count() > 4_096)
        {
            self.send(invalid_params(request_id, "invalid approval response"));
            return;
        }
        let Some(agent) = self.agents.get_mut(&parsed.agent_id) else {
            self.send(agent_not_found(request_id));
            return;
        };
        let command = AgentCommand::Approval {
            request_id: request_id.clone(),
            action_id: parsed.approval_id,
            decision: parsed.decision,
            updated_input: parsed.updated_input,
            message: parsed.message,
        };
        if agent.commands.send(command).await.is_err() {
            self.command_channel_failed(&parsed.agent_id, request_id);
        }
    }

    async fn respond_question(&mut self, request_id: RequestId, params: Value) {
        let Ok(parsed) = serde_json::from_value::<QuestionResponseParams>(params) else {
            self.send(invalid_params(request_id, "invalid question response"));
            return;
        };
        if !matches!(parsed.decision.as_str(), "answer" | "deny") {
            self.send(invalid_params(request_id, "invalid question decision"));
            return;
        }
        if parsed.agent_id.is_empty()
            || parsed.question_id.is_empty()
            || !valid_question_answers(&parsed.answers)
            || parsed
                .message
                .as_ref()
                .is_some_and(|message| message.chars().count() > 4_096)
        {
            self.send(invalid_params(request_id, "invalid question response"));
            return;
        }
        let Some(agent) = self.agents.get_mut(&parsed.agent_id) else {
            self.send(agent_not_found(request_id));
            return;
        };
        let command = AgentCommand::Question {
            request_id: request_id.clone(),
            action_id: parsed.question_id,
            decision: parsed.decision,
            answers: parsed.answers,
            message: parsed.message,
        };
        if agent.commands.send(command).await.is_err() {
            self.command_channel_failed(&parsed.agent_id, request_id);
        }
    }

    fn add_context(&mut self, request_id: RequestId, params: Value) {
        let Ok(parsed) = serde_json::from_value::<ContextParams>(params) else {
            self.send(invalid_params(request_id, "invalid editor context"));
            return;
        };
        let Some(agent) = self.agents.get_mut(&parsed.agent_id) else {
            self.send(agent_not_found(request_id));
            return;
        };
        if agent.task.is_none() || agent.summary.state == AgentState::Disconnected {
            self.send(error_response(
                Some(request_id),
                -32_013,
                "Editor context requires a live agent",
                None,
            ));
            return;
        }
        let context = match validate_context(parsed.context, Path::new(&agent.summary.cwd)) {
            Ok(context) => context,
            Err(message) => {
                self.send(invalid_params(request_id, message));
                return;
            }
        };
        let mut contexts = agent.pending_contexts.clone();
        contexts.push(context.clone());
        if let Err(message) = validate_context_collection(&contexts) {
            self.send(invalid_params(request_id, message));
            return;
        }
        agent.pending_contexts = contexts;
        let count = agent.pending_contexts.len();
        self.send(success_response(
            request_id,
            json!({
                "queued": true,
                "count": count,
                "context": context,
            }),
        ));
    }

    async fn diff(&self, request_id: RequestId, params: Value) {
        let Some(agent_id) = parse_agent_id(params) else {
            self.send(invalid_params(request_id, "invalid agent id parameters"));
            return;
        };
        let Some(agent) = self.agents.get(&agent_id) else {
            self.send(agent_not_found(request_id));
            return;
        };
        let cwd = agent.summary.cwd.clone();
        let mut command = tokio::process::Command::new("git");
        command
            .args(["-C", &cwd, "diff", "--no-ext-diff", "--no-textconv", "--"])
            .kill_on_drop(true);
        let output = tokio::time::timeout(DIFF_TIMEOUT, command.output()).await;
        let Ok(Ok(output)) = output else {
            self.send(error_response(
                Some(request_id),
                -32_020,
                "Workspace diff timed out or could not be started",
                None,
            ));
            return;
        };
        if !output.status.success() {
            self.send(error_response(
                Some(request_id),
                -32_020,
                "Workspace diff is unavailable for this directory",
                None,
            ));
            return;
        }
        let truncated = output.stdout.len() > MAX_DIFF_BYTES;
        let bytes = &output.stdout[..output.stdout.len().min(MAX_DIFF_BYTES)];
        let diff = String::from_utf8_lossy(bytes).into_owned();
        self.send(success_response(
            request_id,
            json!({ "cwd": cwd, "diff": diff, "truncated": truncated }),
        ));
    }

    fn command_channel_failed(&mut self, agent_id: &str, request_id: RequestId) {
        if let Some(agent) = self.agents.get_mut(agent_id) {
            agent.summary.state = AgentState::Disconnected;
            agent.summary.updated_at = timestamp();
            agent.pending_contexts.clear();
        }
        self.send(error_response(
            Some(request_id),
            -32_020,
            "Provider command channel is unavailable",
            None,
        ));
        self.notify_state();
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
                fail_agent,
            } => {
                if fail_agent && let Some(agent) = self.agents.get_mut(&agent_id) {
                    agent.summary.state = AgentState::Failed;
                    agent.summary.active_turn_id = None;
                    agent.summary.updated_at = timestamp();
                    let _ = agent.commands.try_send(AgentCommand::Shutdown);
                }
                self.send(error_response(Some(request_id), code, &message, None));
                if fail_agent {
                    self.notify_state();
                }
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
                    agent.summary.pending_approvals = 0;
                    agent.pending_questions = 0;
                    agent.summary.updated_at = timestamp();
                    agent.pending_contexts.clear();
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
                if let Some(agent) = self.agents.get_mut(&agent_id) {
                    agent.task.take();
                    agent.pending_contexts.clear();
                    if agent.summary.state != AgentState::Disconnected {
                        agent.summary.state = AgentState::Disconnected;
                        agent.summary.active_turn_id = None;
                        agent.summary.updated_at = timestamp();
                        self.notify_state();
                    }
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
        let previous_approvals = agent.summary.pending_approvals;
        let previous_questions = agent.pending_questions;
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
            "approval.requested" => {
                agent.summary.pending_approvals = agent.summary.pending_approvals.saturating_add(1);
                agent.summary.state = AgentState::WaitingApproval;
            }
            "question.requested" => {
                agent.pending_questions = agent.pending_questions.saturating_add(1);
                if agent.summary.pending_approvals == 0 {
                    agent.summary.state = AgentState::WaitingInput;
                }
            }
            "approval.resolved" => {
                agent.summary.pending_approvals = agent.summary.pending_approvals.saturating_sub(1);
                restore_waiting_state(agent);
            }
            "question.resolved" => {
                agent.pending_questions = agent.pending_questions.saturating_sub(1);
                restore_waiting_state(agent);
            }
            _ => {}
        }
        let changed = previous_state != agent.summary.state
            || previous_turn != agent.summary.active_turn_id
            || previous_approvals != agent.summary.pending_approvals
            || previous_questions != agent.pending_questions;
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

fn restore_waiting_state(agent: &mut ManagedAgent) {
    if matches!(
        agent.summary.state,
        AgentState::Disconnected | AgentState::Failed
    ) {
        return;
    }
    agent.summary.state = if agent.summary.pending_approvals > 0 {
        AgentState::WaitingApproval
    } else if agent.pending_questions > 0 {
        AgentState::WaitingInput
    } else if agent.summary.active_turn_id.is_some() {
        AgentState::Running
    } else {
        AgentState::Idle
    };
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
struct ProviderSessionListParams {
    provider: Provider,
    cwd: String,
    #[serde(default)]
    cursor: Option<String>,
    #[serde(default)]
    limit: Option<u32>,
}

#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
struct ResumeParams {
    provider: Provider,
    provider_session_id: String,
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
struct HistoryParams {
    agent_id: String,
    #[serde(default)]
    cursor: Option<String>,
    #[serde(default)]
    limit: Option<u32>,
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
struct ApprovalResponseParams {
    agent_id: String,
    approval_id: String,
    decision: String,
    #[serde(default)]
    updated_input: Option<Value>,
    #[serde(default)]
    message: Option<String>,
}

#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
struct QuestionResponseParams {
    agent_id: String,
    question_id: String,
    #[serde(default = "answer_decision")]
    decision: String,
    answers: serde_json::Map<String, Value>,
    #[serde(default)]
    message: Option<String>,
}

fn answer_decision() -> String {
    "answer".to_owned()
}

fn valid_question_answers(answers: &serde_json::Map<String, Value>) -> bool {
    answers.len() <= 32
        && answers.values().all(|answer| match answer {
            Value::String(answer) => answer.chars().count() <= 16_384,
            Value::Array(answers) => {
                answers.len() <= 32
                    && answers.iter().all(|answer| {
                        answer
                            .as_str()
                            .is_some_and(|answer| answer.chars().count() <= 4_096)
                    })
            }
            _ => false,
        })
}

#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
struct ContextParams {
    agent_id: String,
    context: Value,
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
                return Err("embedded mode requires worktree_path to equal cwd");
            }
            Ok(Some(worktree.to_string_lossy().into_owned()))
        }
    }
}

fn validate_context(context: Value, cwd: &Path) -> Result<Value, &'static str> {
    let object = context.as_object().ok_or("context must be an object")?;
    let kind = object
        .get("kind")
        .and_then(Value::as_str)
        .ok_or("context.kind must be a non-empty string")?;
    if !matches!(kind, "buffer" | "range" | "diagnostics" | "diff") {
        return Err("context kind must be buffer, range, diagnostics, or diff");
    }
    let payload = object
        .get("payload")
        .and_then(Value::as_object)
        .ok_or("context.payload must be an object")?;
    let raw_path = payload
        .get("path")
        .or_else(|| payload.get("cwd"))
        .and_then(Value::as_str)
        .ok_or("editor context must identify its path")?;
    let path = canonical_context_path(raw_path)?;
    if !path.starts_with(cwd) {
        return Err("editor context path escapes the agent cwd");
    }
    match kind {
        "buffer" | "range" if !payload.get("text").is_some_and(Value::is_string) => {
            return Err("buffer and range context require text");
        }
        "diagnostics" if !payload.get("diagnostics").is_some_and(Value::is_array) => {
            return Err("diagnostics context requires a diagnostics array");
        }
        "diff" if !payload.get("diff").is_some_and(Value::is_string) => {
            return Err("diff context requires diff text");
        }
        _ => {}
    }
    if serde_json::to_vec(&context).map_or(true, |encoded| encoded.len() > MAX_CONTEXT_BYTES) {
        return Err("editor context exceeds the size limit");
    }
    Ok(context)
}

fn validate_context_collection(contexts: &[Value]) -> Result<(), &'static str> {
    if contexts.len() > MAX_CONTEXT_ITEMS {
        return Err("too many editor context items");
    }
    if serde_json::to_vec(contexts).map_or(true, |encoded| encoded.len() > MAX_CONTEXT_BYTES) {
        return Err("combined editor context exceeds the size limit");
    }
    Ok(())
}

fn canonical_context_path(raw: &str) -> Result<PathBuf, &'static str> {
    let path = Path::new(raw);
    if !path.is_absolute() {
        return Err("editor context path must be absolute");
    }
    if path.exists() {
        return path
            .canonicalize()
            .map_err(|_| "editor context path could not be resolved");
    }
    let parent = path
        .parent()
        .ok_or("editor context path has no parent")?
        .canonicalize()
        .map_err(|_| "editor context parent does not exist")?;
    let name = path
        .file_name()
        .ok_or("editor context path has no file name")?;
    Ok(parent.join(name))
}

fn capabilities(provider: Provider) -> Vec<Capability> {
    vec![
        available(CapabilityName::Streaming),
        available(CapabilityName::MultiTurn),
        available(CapabilityName::History),
        available(CapabilityName::Resume),
        available(CapabilityName::Fork),
        available(CapabilityName::Interrupt),
        available(CapabilityName::Steer),
        available(CapabilityName::Approvals),
        available(CapabilityName::Questions),
        Capability {
            name: CapabilityName::Usage,
            available: true,
            reason: None,
        },
        Capability {
            name: CapabilityName::FileChanges,
            available: true,
            reason: (provider == Provider::Claude).then(|| {
                "Projected from Claude tool and hook events when paths are supplied".to_owned()
            }),
        },
        available(CapabilityName::Diff),
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

#[cfg(test)]
mod tests {
    use std::path::PathBuf;

    use serde_json::json;

    use super::{
        MAX_CONTEXT_BYTES, MAX_CONTEXT_ITEMS, valid_question_answers, validate_context,
        validate_context_collection,
    };

    fn fixture_cwd() -> PathBuf {
        PathBuf::from(env!("CARGO_MANIFEST_DIR"))
            .canonicalize()
            .expect("canonical fixture cwd")
    }

    #[test]
    fn validates_context_shape_and_rejects_workspace_escape() {
        let cwd = fixture_cwd();
        let valid = json!({
            "kind": "range",
            "payload": {
                "path": cwd.join("Cargo.toml"),
                "start_line": 1,
                "end_line": 1,
                "text": "[package]"
            }
        });
        assert!(validate_context(valid, &cwd).is_ok());

        let outside = cwd.parent().expect("workspace root").join("Cargo.toml");
        let escaped = json!({
            "kind": "buffer",
            "payload": { "path": outside, "text": "[workspace]" }
        });
        assert_eq!(
            validate_context(escaped, &cwd),
            Err("editor context path escapes the agent cwd")
        );
        assert_eq!(
            validate_context(
                json!({ "kind": "buffer", "payload": { "path": cwd.join("Cargo.toml") } }),
                &cwd,
            ),
            Err("buffer and range context require text")
        );
    }

    #[test]
    fn bounds_context_item_count_and_encoded_size() {
        let cwd = fixture_cwd();
        let oversized = json!({
            "kind": "buffer",
            "payload": {
                "path": cwd.join("Cargo.toml"),
                "text": "x".repeat(MAX_CONTEXT_BYTES)
            }
        });
        assert_eq!(
            validate_context(oversized, &cwd),
            Err("editor context exceeds the size limit")
        );

        let items = (0..=MAX_CONTEXT_ITEMS)
            .map(|_| json!({ "kind": "buffer", "payload": {} }))
            .collect::<Vec<_>>();
        assert_eq!(
            validate_context_collection(&items),
            Err("too many editor context items")
        );
    }

    #[test]
    fn validates_public_question_answer_shapes() {
        let valid = serde_json::from_value(json!({
            "mode": "safe",
            "checks": ["format", "test"]
        }))
        .expect("answer map");
        assert!(valid_question_answers(&valid));

        let invalid = serde_json::from_value(json!({ "mode": 7 })).expect("answer map");
        assert!(!valid_question_answers(&invalid));
        let too_many = serde_json::from_value(json!({
            "checks": (0..=32).map(|index| index.to_string()).collect::<Vec<_>>()
        }))
        .expect("answer map");
        assert!(!valid_question_answers(&too_many));
    }
}
