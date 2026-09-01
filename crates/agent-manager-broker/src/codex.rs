//! Native Codex App Server JSONL boundary for the pinned CLI contract.

use std::path::Path;
use std::process::Stdio;

use serde_json::{Value, json};
use thiserror::Error;
use time::OffsetDateTime;
use time::format_description::well_known::Rfc3339;
use tokio::io::{AsyncWriteExt, BufReader};
use tokio::process::{Child, ChildStdin, ChildStdout, Command};

use crate::framing::{BoundedFrame, read_bounded_line};
use crate::protocol::{EventEnvelope, Provider};

pub const PINNED_CODEX_VERSION: &str = "0.151.0";
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
    #[error("Codex App Server event is not an unanswered server request")]
    InvalidServerRequest,
    #[error("failed to format event timestamp: {0}")]
    Timestamp(#[from] time::error::Format),
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

    pub async fn list_threads(&mut self, limit: u32) -> Result<RequestOutcome, CodexError> {
        self.request("thread/list", json!({ "limit": limit })).await
    }

    pub async fn start_thread(&mut self, cwd: &Path) -> Result<RequestOutcome, CodexError> {
        self.request(
            "thread/start",
            json!({
                "cwd": cwd,
                "approvalPolicy": "on-request",
                "ephemeral": true
            }),
        )
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

    pub async fn interrupt(&mut self, thread_id: &str, turn_id: &str) -> Result<(), CodexError> {
        self.request(
            "turn/interrupt",
            json!({ "threadId": thread_id, "turnId": turn_id }),
        )
        .await?;
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
    use serde_json::{Value, json};

    use super::{ProviderEvent, ProviderEventKind, normalize_event};

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
}
