//! Native Codex App Server JSONL boundary for the pinned CLI contract.

use std::collections::HashSet;
use std::env;
use std::fs::{self, OpenOptions, TryLockError};
use std::path::{Path, PathBuf};
use std::process::Stdio;

use serde_json::{Value, json};
use thiserror::Error;
use time::OffsetDateTime;
use time::format_description::well_known::Rfc3339;
use tokio::io::{AsyncWriteExt, BufReader};
use tokio::process::{Child, ChildStdin, ChildStdout, Command};

use crate::framing::{BoundedFrame, read_bounded_line};
use crate::protocol::{EventEnvelope, Provider, ProviderRuntime};

pub const CODEX_COMPATIBILITY_PROFILE: &str = "codex-app-server-stable-v1";
pub const CODEX_SCHEMA_BASELINE_VERSION: &str = "0.152.0";
const MAX_FRAME_BYTES: usize = 8 * 1024 * 1024;

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct CommandSpec {
    pub program: String,
    pub args: Vec<String>,
}

impl Default for CommandSpec {
    fn default() -> Self {
        Self {
            program: "codex".to_owned(),
            args: vec!["app-server".to_owned(), "--stdio".to_owned()],
        }
    }
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum ProviderEventKind {
    Notification,
    ServerRequest,
}

#[derive(Clone, Debug, PartialEq)]
pub struct ProviderEvent {
    pub kind: ProviderEventKind,
    pub request_id: Option<Value>,
    pub response_required: bool,
    pub method: String,
    pub params: Value,
}

#[derive(Clone, Debug, PartialEq)]
pub struct RequestOutcome {
    pub result: Value,
    pub events: Vec<ProviderEvent>,
}

#[derive(Debug, Error)]
pub enum CodexError {
    #[error("failed to spawn Codex App Server: {0}")]
    Spawn(#[source] std::io::Error),
    #[error("Codex App Server did not expose {0}")]
    MissingPipe(&'static str),
    #[error("Codex App Server I/O failed: {0}")]
    Io(#[from] std::io::Error),
    #[error("Codex App Server emitted invalid JSON: {0}")]
    Json(#[from] serde_json::Error),
    #[error("Codex App Server frame exceeds the size limit")]
    FrameTooLarge,
    #[error("Codex App Server closed its protocol stream")]
    Closed,
    #[error("Codex App Server protocol error {code}: {message}")]
    Response { code: i64, message: String },
    #[error("Codex App Server emitted an unexpected protocol frame")]
    UnexpectedFrame,
    #[error("Codex App Server response omitted {0}")]
    MissingField(&'static str),
    #[error("Codex App Server runtime {0} is outside the stable-v1 compatibility profile")]
    IncompatibleRuntime(String),
    #[error("Codex App Server event is not an unanswered server request")]
    InvalidServerRequest,
    #[error("failed to format event timestamp: {0}")]
    Timestamp(#[from] time::error::Format),
}

pub fn runtime_identity(
    initialize: &Value,
    spec: &CommandSpec,
) -> Result<ProviderRuntime, CodexError> {
    let user_agent = initialize
        .get("userAgent")
        .and_then(Value::as_str)
        .ok_or(CodexError::MissingField("userAgent"))?;
    let version = user_agent
        .split_once('/')
        .map(|(_, version)| version)
        .and_then(|version| version.split_whitespace().next())
        .map(|version| {
            version.trim_end_matches(|character: char| {
                !character.is_ascii_alphanumeric() && character != '.' && character != '-'
            })
        })
        .filter(|version| !version.is_empty())
        .ok_or(CodexError::MissingField("userAgent version"))?;
    let current = numeric_version(version)
        .ok_or_else(|| CodexError::IncompatibleRuntime(version.to_owned()))?;
    let baseline = numeric_version(CODEX_SCHEMA_BASELINE_VERSION)
        .expect("committed Codex baseline must be numeric");
    if current < baseline {
        return Err(CodexError::IncompatibleRuntime(version.to_owned()));
    }
    Ok(ProviderRuntime {
        compatibility_profile: CODEX_COMPATIBILITY_PROFILE.to_owned(),
        provider_version: version.to_owned(),
        adapter_version: None,
        executable: resolve_program(&spec.program),
    })
}

fn numeric_version(value: &str) -> Option<(u64, u64, u64)> {
    let core = value.split_once('-').map_or(value, |(core, _)| core);
    let mut components = core.split('.');
    let major = components.next()?.parse().ok()?;
    let minor = components.next()?.parse().ok()?;
    let patch = components.next()?.parse().ok()?;
    if components.next().is_some() {
        return None;
    }
    Some((major, minor, patch))
}

fn resolve_program(program: &str) -> Option<String> {
    let path = Path::new(program);
    if path.components().count() > 1 {
        return path
            .canonicalize()
            .ok()
            .map(|path| path.to_string_lossy().into_owned());
    }
    env::var_os("PATH")
        .into_iter()
        .flat_map(|paths| env::split_paths(&paths).collect::<Vec<_>>())
        .map(|directory| directory.join(program))
        .find(|candidate| candidate.is_file())
        .and_then(|candidate| candidate.canonicalize().ok())
        .map(|path| path.to_string_lossy().into_owned())
}

pub struct CodexAppServer {
    child: Child,
    stdin: ChildStdin,
    stdout: BufReader<ChildStdout>,
    next_request_id: u64,
}

impl CodexAppServer {
    pub fn spawn(spec: &CommandSpec) -> Result<Self, CodexError> {
        let mut command = Command::new(&spec.program);
        command
            .args(&spec.args)
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::inherit())
            .kill_on_drop(true);
        let mut child = command.spawn().map_err(CodexError::Spawn)?;
        let stdin = child.stdin.take().ok_or(CodexError::MissingPipe("stdin"))?;
        let stdout = child
            .stdout
            .take()
            .ok_or(CodexError::MissingPipe("stdout"))?;
        Ok(Self {
            child,
            stdin,
            stdout: BufReader::new(stdout),
            next_request_id: 1,
        })
    }

    pub async fn initialize(&mut self) -> Result<Value, CodexError> {
        let outcome = self
            .request(
                "initialize",
                json!({
                    "clientInfo": {
                        "name": "agent_manager",
                        "title": "Agent Manager",
                        "version": env!("CARGO_PKG_VERSION")
                    },
                    "capabilities": {
                        "experimentalApi": false
                    }
                }),
            )
            .await?;
        self.notify("initialized", json!({})).await?;
        Ok(outcome.result)
    }

    pub async fn list_threads(
        &mut self,
        cursor: Option<&str>,
        limit: u32,
    ) -> Result<RequestOutcome, CodexError> {
        self.request(
            "thread/list",
            json!({
                "cursor": cursor,
                "limit": limit,
                "sortKey": "updated_at",
                "sortDirection": "desc"
            }),
        )
        .await
    }

    pub async fn list_threads_for_directory(
        &mut self,
        cwd: &Path,
        cursor: Option<&str>,
        limit: u32,
    ) -> Result<RequestOutcome, CodexError> {
        self.request(
            "thread/list",
            json!({
                "cwd": cwd,
                "cursor": cursor,
                "limit": limit,
                "sortKey": "updated_at",
                "sortDirection": "desc"
            }),
        )
        .await
    }

    pub async fn start_thread(&mut self, cwd: &Path) -> Result<RequestOutcome, CodexError> {
        self.request(
            "thread/start",
            json!({
                "cwd": cwd,
                "approvalPolicy": "on-request",
                "ephemeral": false
            }),
        )
        .await
    }

    pub async fn resume_thread(
        &mut self,
        thread_id: &str,
        cwd: &Path,
    ) -> Result<RequestOutcome, CodexError> {
        self.request(
            "thread/resume",
            json!({
                "threadId": thread_id,
                "cwd": cwd,
                "approvalPolicy": "on-request"
            }),
        )
        .await
    }

    pub async fn fork_thread(
        &mut self,
        thread_id: &str,
        cwd: &Path,
    ) -> Result<RequestOutcome, CodexError> {
        self.request(
            "thread/fork",
            json!({
                "threadId": thread_id,
                "cwd": cwd,
                "approvalPolicy": "on-request",
                "ephemeral": false
            }),
        )
        .await
    }

    pub async fn read_thread(&mut self, thread_id: &str) -> Result<RequestOutcome, CodexError> {
        self.request(
            "thread/read",
            json!({ "threadId": thread_id, "includeTurns": true }),
        )
        .await
    }

    pub async fn delete_thread(&mut self, thread_id: &str) -> Result<RequestOutcome, CodexError> {
        self.request("thread/delete", json!({ "threadId": thread_id }))
            .await
    }

    pub async fn start_turn(
        &mut self,
        thread_id: &str,
        prompt: &str,
    ) -> Result<RequestOutcome, CodexError> {
        self.request(
            "turn/start",
            json!({
                "threadId": thread_id,
                "input": [{ "type": "text", "text": prompt }]
            }),
        )
        .await
    }

    pub async fn steer(
        &mut self,
        thread_id: &str,
        turn_id: &str,
        prompt: &str,
    ) -> Result<RequestOutcome, CodexError> {
        self.request(
            "turn/steer",
            json!({
                "threadId": thread_id,
                "expectedTurnId": turn_id,
                "input": [{ "type": "text", "text": prompt }]
            }),
        )
        .await
    }

    pub async fn interrupt_with_events(
        &mut self,
        thread_id: &str,
        turn_id: &str,
    ) -> Result<RequestOutcome, CodexError> {
        self.request(
            "turn/interrupt",
            json!({ "threadId": thread_id, "turnId": turn_id }),
        )
        .await
    }

    pub async fn interrupt(&mut self, thread_id: &str, turn_id: &str) -> Result<(), CodexError> {
        self.interrupt_with_events(thread_id, turn_id).await?;
        Ok(())
    }

    pub async fn request(
        &mut self,
        method: &str,
        params: Value,
    ) -> Result<RequestOutcome, CodexError> {
        let request_id = self.next_request_id;
        self.next_request_id = self
            .next_request_id
            .checked_add(1)
            .ok_or(CodexError::UnexpectedFrame)?;
        self.write(&json!({ "id": request_id, "method": method, "params": params }))
            .await?;

        let mut events = Vec::new();
        loop {
            let message = self.read().await?;
            if message.get("id").and_then(Value::as_u64) == Some(request_id)
                && message.get("method").is_none()
            {
                if let Some(error) = message.get("error") {
                    return Err(response_error(error));
                }
                let result = message
                    .get("result")
                    .cloned()
                    .ok_or(CodexError::MissingField("result"))?;
                return Ok(RequestOutcome { result, events });
            }

            let mut event = parse_event_or_request(&message)?;
            if event.response_required {
                self.deny_server_request(&mut event).await?;
            }
            events.push(event);
        }
    }

    pub async fn next_event(&mut self) -> Result<ProviderEvent, CodexError> {
        let message = self.read().await?;
        parse_event_or_request(&message)
    }

    pub async fn respond_server_request(
        &mut self,
        event: &mut ProviderEvent,
        result: Value,
    ) -> Result<(), CodexError> {
        let id = unanswered_request_id(event)?;
        self.write(&json!({ "id": id, "result": result })).await?;
        event.response_required = false;
        Ok(())
    }

    pub async fn deny_server_request(
        &mut self,
        event: &mut ProviderEvent,
    ) -> Result<(), CodexError> {
        let id = unanswered_request_id(event)?;
        let response = match safe_server_request_response(&event.method) {
            Ok(result) => json!({ "id": id, "result": result }),
            Err(error) => json!({
                "id": id,
                "error": { "code": -32601, "message": error }
            }),
        };
        self.write(&response).await?;
        event.response_required = false;
        Ok(())
    }

    pub async fn shutdown(mut self) -> Result<(), CodexError> {
        if self.child.try_wait()?.is_none() {
            self.child.start_kill()?;
        }
        self.child.wait().await?;
        Ok(())
    }

    async fn notify(&mut self, method: &str, params: Value) -> Result<(), CodexError> {
        self.write(&json!({ "method": method, "params": params }))
            .await
    }

    async fn write(&mut self, message: &Value) -> Result<(), CodexError> {
        let mut frame = serde_json::to_vec(message)?;
        if frame.len() > MAX_FRAME_BYTES {
            return Err(CodexError::FrameTooLarge);
        }
        frame.push(b'\n');
        self.stdin.write_all(&frame).await?;
        self.stdin.flush().await?;
        Ok(())
    }

    async fn read(&mut self) -> Result<Value, CodexError> {
        let mut frame = match read_bounded_line(&mut self.stdout, MAX_FRAME_BYTES).await? {
            BoundedFrame::Closed => return Err(CodexError::Closed),
            BoundedFrame::TooLarge => return Err(CodexError::FrameTooLarge),
            BoundedFrame::Data(frame) => frame,
        };
        while matches!(frame.last(), Some(b'\n' | b'\r')) {
            frame.pop();
        }
        let value: Value = serde_json::from_slice(&frame)?;
        if !value.is_object() {
            return Err(CodexError::UnexpectedFrame);
        }
        Ok(value)
    }
}

#[must_use]
pub(crate) fn default_thread_lock_directory() -> Option<PathBuf> {
    match env::var_os("CODEX_HOME").map(PathBuf::from) {
        Some(path) if path.is_absolute() => Some(path.join("thread-writer-locks")),
        Some(_) => None,
        None => env::var_os("HOME")
            .map(PathBuf::from)
            .filter(|path| path.is_absolute())
            .map(|path| path.join(".codex").join("thread-writer-locks")),
    }
}

/// Returns thread IDs whose pinned Codex writer lock is currently held.
///
/// The lock directory is provider-owned and deliberately optional. Missing,
/// unreadable, malformed, or unlocked entries fail open as an unavailable or
/// inactive observation; Agent Manager never creates or mutates a lock file.
pub(crate) fn active_thread_ids(directory: Option<&Path>) -> (HashSet<String>, bool) {
    let Some(directory) = directory else {
        return (HashSet::new(), false);
    };
    let Ok(entries) = fs::read_dir(directory) else {
        return (HashSet::new(), false);
    };
    let mut active = HashSet::new();
    for entry in entries.flatten() {
        let path = entry.path();
        let Some(thread_id) = path
            .file_name()
            .and_then(|name| name.to_str())
            .and_then(|name| name.strip_suffix(".lock"))
            .filter(|thread_id| uuid::Uuid::parse_str(thread_id).is_ok())
        else {
            continue;
        };
        let Ok(metadata) = fs::symlink_metadata(&path) else {
            continue;
        };
        if !metadata.file_type().is_file() {
            continue;
        }
        let Ok(file) = OpenOptions::new().read(true).write(true).open(&path) else {
            continue;
        };
        match file.try_lock() {
            Ok(()) => {
                let _ = file.unlock();
            }
            Err(TryLockError::WouldBlock) => {
                active.insert(thread_id.to_owned());
            }
            Err(_) => {}
        }
    }
    (active, true)
}

impl Drop for CodexAppServer {
    fn drop(&mut self) {
        let _ = self.child.start_kill();
    }
}

pub fn normalize_event(
    agent_id: &str,
    provider_event: &ProviderEvent,
) -> Result<EventEnvelope, CodexError> {
    let event_type = normalized_event_type(&provider_event.method, &provider_event.params);
    let provider_record = json!({
        "kind": match provider_event.kind {
            ProviderEventKind::Notification => "notification",
            ProviderEventKind::ServerRequest => "request",
        },
        "request_id": provider_event.request_id,
        "response_required": provider_event.response_required,
        "method": provider_event.method,
        "params": provider_event.params,
    });
    Ok(EventEnvelope::new(
        OffsetDateTime::now_utc().format(&Rfc3339)?,
        agent_id.to_owned(),
        Provider::Codex,
        event_type.to_owned(),
        provider_record["params"].clone(),
        provider_record,
    ))
}

#[must_use]
pub fn thread_id(result: &Value) -> Option<&str> {
    result.get("thread")?.get("id")?.as_str()
}

#[must_use]
pub fn turn_id(result: &Value) -> Option<&str> {
    result.get("turn")?.get("id")?.as_str()
}

fn normalized_event_type(method: &str, params: &Value) -> &'static str {
    match method {
        "thread/started"
        | "thread/status/changed"
        | "thread/closed"
        | "thread/archived"
        | "thread/unarchived" => "agent.state_changed",
        "turn/started" => "turn.started",
        "turn/completed" if params["turn"]["status"] == "failed" => "turn.failed",
        "turn/completed" => "turn.completed",
        "item/started" => item_lifecycle_event(params, true),
        "item/completed" => item_lifecycle_event(params, false),
        "item/agentMessage/delta" => "message.delta",
        "item/commandExecution/outputDelta"
        | "item/mcpToolCall/progress"
        | "command/exec/outputDelta"
        | "process/outputDelta" => "tool.progress",
        "process/exited" => "tool.completed",
        "item/fileChange/outputDelta" | "item/fileChange/patchUpdated" | "fs/changed" => {
            "file.changed"
        }
        "turn/diff/updated" | "thread/reverted" => "diff.changed",
        "thread/tokenUsage/updated" | "account/rateLimits/updated" => "usage.updated",
        "thread/compacted" => "context.compacted",
        "item/commandExecution/requestApproval"
        | "item/fileChange/requestApproval"
        | "item/permissions/requestApproval"
        | "execCommandApproval"
        | "applyPatchApproval" => "approval.requested",
        "item/tool/requestUserInput" => "question.requested",
        "error" => "turn.failed",
        "warning" | "configWarning" | "guardianWarning" | "windows/worldWritableWarning" => {
            "broker.warning"
        }
        _ => "provider.notice",
    }
}

fn item_lifecycle_event(params: &Value, started: bool) -> &'static str {
    match params["item"]["type"].as_str() {
        Some("userMessage" | "agentMessage") if started => "message.started",
        Some("userMessage" | "agentMessage") => "message.completed",
        Some(item_type) if is_tool_item(item_type) && started => "tool.started",
        Some(item_type) if is_tool_item(item_type) => "tool.completed",
        Some("fileChange") => "file.changed",
        Some("contextCompaction") => "context.compacted",
        _ => "provider.notice",
    }
}

fn is_tool_item(item_type: &str) -> bool {
    matches!(
        item_type,
        "commandExecution"
            | "mcpToolCall"
            | "dynamicToolCall"
            | "collabAgentToolCall"
            | "subAgentActivity"
            | "webSearch"
            | "imageView"
            | "sleep"
            | "imageGeneration"
    )
}

fn parse_event_or_request(message: &Value) -> Result<ProviderEvent, CodexError> {
    let Some(method) = message.get("method").and_then(Value::as_str) else {
        return Err(CodexError::UnexpectedFrame);
    };
    if method.is_empty() {
        return Err(CodexError::UnexpectedFrame);
    }
    let params = message.get("params").cloned().unwrap_or_else(|| json!({}));
    if !params.is_object() {
        return Err(CodexError::UnexpectedFrame);
    }
    let request_id = message.get("id").cloned();
    if request_id
        .as_ref()
        .is_some_and(|id| !(id.is_string() || id.as_i64().is_some() || id.as_u64().is_some()))
    {
        return Err(CodexError::UnexpectedFrame);
    }
    Ok(ProviderEvent {
        kind: if request_id.is_some() {
            ProviderEventKind::ServerRequest
        } else {
            ProviderEventKind::Notification
        },
        response_required: request_id.is_some(),
        request_id,
        method: method.to_owned(),
        params,
    })
}

fn unanswered_request_id(event: &ProviderEvent) -> Result<Value, CodexError> {
    if event.kind != ProviderEventKind::ServerRequest || !event.response_required {
        return Err(CodexError::InvalidServerRequest);
    }
    event
        .request_id
        .clone()
        .ok_or(CodexError::InvalidServerRequest)
}

fn safe_server_request_response(method: &str) -> Result<Value, &'static str> {
    match method {
        "item/commandExecution/requestApproval"
        | "item/fileChange/requestApproval"
        | "execCommandApproval"
        | "applyPatchApproval" => Ok(json!({ "decision": "decline" })),
        _ => Err("unsupported server request denied by Agent Manager"),
    }
}

fn response_error(error: &Value) -> CodexError {
    CodexError::Response {
        code: error.get("code").and_then(Value::as_i64).unwrap_or(-32_000),
        message: error
            .get("message")
            .and_then(Value::as_str)
            .unwrap_or("unknown Codex App Server error")
            .to_owned(),
    }
}

#[cfg(test)]
mod tests {
    use std::collections::HashSet;
    use std::fs::{self, File};

    use serde_json::{Value, json};

    use super::{
        CODEX_COMPATIBILITY_PROFILE, CodexError, CommandSpec, ProviderEvent, ProviderEventKind,
        active_thread_ids, normalize_event, runtime_identity, safe_server_request_response,
    };

    fn event(method: &str, params: Value) -> ProviderEvent {
        ProviderEvent {
            kind: ProviderEventKind::Notification,
            request_id: None,
            response_required: false,
            method: method.to_owned(),
            params,
        }
    }

    #[test]
    fn stable_profile_accepts_the_schema_baseline_and_newer_runtimes() {
        let command = CommandSpec {
            program: "/fixture/codex".to_owned(),
            args: Vec::new(),
        };
        for version in ["0.152.0", "0.153.0", "1.0.0"] {
            let runtime = runtime_identity(
                &json!({ "userAgent": format!("codex_cli_rs/{version}") }),
                &command,
            )
            .expect("compatible runtime");
            assert_eq!(runtime.provider_version, version);
            assert_eq!(runtime.compatibility_profile, CODEX_COMPATIBILITY_PROFILE);
        }
    }

    #[test]
    fn stable_profile_rejects_pre_baseline_and_malformed_runtimes() {
        let command = CommandSpec::default();
        for version in ["0.151.9", "not-a-version"] {
            assert!(matches!(
                runtime_identity(
                    &json!({ "userAgent": format!("codex_cli_rs/{version}") }),
                    &command,
                ),
                Err(CodexError::IncompatibleRuntime(_))
            ));
        }
    }

    #[test]
    fn classifies_item_lifecycle_from_the_provider_item_type() {
        let cases = [
            ("agentMessage", "message.started", "message.completed"),
            ("commandExecution", "tool.started", "tool.completed"),
            ("fileChange", "file.changed", "file.changed"),
            (
                "contextCompaction",
                "context.compacted",
                "context.compacted",
            ),
            ("reasoning", "provider.notice", "provider.notice"),
        ];

        for (item_type, started_type, completed_type) in cases {
            let params = json!({ "item": { "id": "item-1", "type": item_type } });
            let started = normalize_event("agent-1", &event("item/started", params.clone()))
                .expect("normalize started item");
            let completed = normalize_event("agent-1", &event("item/completed", params))
                .expect("normalize completed item");
            assert_eq!(started.event_type, started_type);
            assert_eq!(completed.event_type, completed_type);
        }
    }

    #[test]
    fn classifies_failed_turn_and_preserves_unknown_provider_event() {
        let failed = normalize_event(
            "agent-1",
            &event(
                "turn/completed",
                json!({ "turn": { "id": "turn-1", "status": "failed" } }),
            ),
        )
        .expect("normalize failed turn");
        assert_eq!(failed.event_type, "turn.failed");

        let unknown = normalize_event("agent-1", &event("future/event", json!({ "opaque": true })))
            .expect("normalize unknown event");
        assert_eq!(unknown.event_type, "provider.notice");
        assert_eq!(unknown.provider_event["method"], "future/event");
        assert_eq!(unknown.provider_event["params"]["opaque"], true);
    }

    #[test]
    fn preserves_auth_recovery_notifications_as_provider_notices() {
        let recovery = normalize_event(
            "agent-1",
            &event(
                "modelProvider/authRecoveryStarted",
                json!({
                    "message": "provider authentication is recovering",
                    "provider": "openai",
                    "threadId": "thread-1",
                    "turnId": "turn-1"
                }),
            ),
        )
        .expect("normalize auth recovery notification");

        assert_eq!(recovery.event_type, "provider.notice");
        assert_eq!(
            recovery.provider_event["method"],
            "modelProvider/authRecoveryStarted"
        );
        assert_eq!(recovery.provider_event["params"]["threadId"], "thread-1");
    }

    #[test]
    fn unsupported_mcp_elicitation_remains_fail_closed() {
        assert_eq!(
            safe_server_request_response("mcpServer/elicitation/request"),
            Err("unsupported server request denied by Agent Manager")
        );
    }

    #[test]
    fn observes_only_held_codex_writer_locks() {
        let directory = std::env::temp_dir().join(format!(
            "agent-manager-codex-lock-test-{}",
            uuid::Uuid::new_v4()
        ));
        fs::create_dir(&directory).expect("create lock test directory");
        let active_id = uuid::Uuid::new_v4().to_string();
        let inactive_id = uuid::Uuid::new_v4().to_string();
        let active_file =
            File::create(directory.join(format!("{active_id}.lock"))).expect("create active lock");
        active_file.lock().expect("hold active lock");
        File::create(directory.join(format!("{inactive_id}.lock"))).expect("create inactive lock");
        File::create(directory.join("not-a-thread.lock")).expect("create malformed lock");

        let (active, available) = active_thread_ids(Some(&directory));

        assert!(available);
        assert_eq!(active, HashSet::from([active_id]));
        active_file.unlock().expect("release active lock");
        fs::remove_dir_all(directory).expect("remove lock test directory");
    }
}
