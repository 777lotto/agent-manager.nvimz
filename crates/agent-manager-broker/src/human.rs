//! Normalized human-input requests and provider-specific response mapping.

use serde_json::{Map, Value, json};

use crate::codex::{ProviderEvent, ProviderEventKind};
use crate::protocol::{EventEnvelope, Provider};
use crate::worker::WorkerInbound;

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub(crate) enum HumanRequestKind {
    Approval,
    Question,
}

impl HumanRequestKind {
    pub(crate) const fn requested_event(self) -> &'static str {
        match self {
            Self::Approval => "approval.requested",
            Self::Question => "question.requested",
        }
    }

    const fn resolved_event(self) -> &'static str {
        match self {
            Self::Approval => "approval.resolved",
            Self::Question => "question.resolved",
        }
    }
}

pub(crate) struct HumanRequest {
    pub id: String,
    pub kind: HumanRequestKind,
    pub envelope: EventEnvelope,
}

pub(crate) fn codex_request(
    agent_id: &str,
    action_id: String,
    event: &ProviderEvent,
) -> Option<HumanRequest> {
    if event.kind != ProviderEventKind::ServerRequest || !event.response_required {
        return None;
    }
    let kind = match event.method.as_str() {
        "item/commandExecution/requestApproval"
        | "item/fileChange/requestApproval"
        | "item/permissions/requestApproval"
        | "execCommandApproval"
        | "applyPatchApproval" => HumanRequestKind::Approval,
        "item/tool/requestUserInput" => HumanRequestKind::Question,
        _ => return None,
    };
    let payload = normalized_payload(kind, &action_id, &event.method, &event.params);
    let provider_event = json!({
        "kind": "request",
        "request_id": event.request_id,
        "response_required": true,
        "method": event.method,
        "redacted": true,
    });
    Some(HumanRequest {
        id: action_id,
        kind,
        envelope: EventEnvelope::new(
            timestamp(),
            agent_id.to_owned(),
            Provider::Codex,
            kind.requested_event().to_owned(),
            payload,
            provider_event,
        ),
    })
}

pub(crate) fn claude_request(
    agent_id: &str,
    action_id: String,
    inbound: &WorkerInbound,
) -> Option<HumanRequest> {
    if !inbound.is_callback() {
        return None;
    }
    let kind = match inbound.method.as_str() {
        "approval/request" => HumanRequestKind::Approval,
        "question/request" => HumanRequestKind::Question,
        _ => return None,
    };
    let payload = normalized_payload(kind, &action_id, &inbound.method, &inbound.params);
    let provider_event = json!({
        "kind": "request",
        "request_id": inbound.id,
        "response_required": true,
        "method": inbound.method,
        "redacted": true,
    });
    Some(HumanRequest {
        id: action_id,
        kind,
        envelope: EventEnvelope::new(
            timestamp(),
            agent_id.to_owned(),
            Provider::Claude,
            kind.requested_event().to_owned(),
            payload,
            provider_event,
        ),
    })
}

pub(crate) fn resolved_event(
    agent_id: &str,
    provider: Provider,
    kind: HumanRequestKind,
    action_id: &str,
    decision: &str,
    reason: Option<&str>,
) -> EventEnvelope {
    EventEnvelope::new(
        timestamp(),
        agent_id.to_owned(),
        provider,
        kind.resolved_event().to_owned(),
        json!({
            "id": action_id,
            "decision": decision,
            "reason": reason,
        }),
        json!({ "kind": "broker", "redacted": true }),
    )
}

pub(crate) fn codex_approval_response(
    event: &ProviderEvent,
    decision: &str,
    message: Option<&str>,
) -> Result<Value, &'static str> {
    if decision == "defer" {
        return Err("this provider request cannot be deferred");
    }
    let allow = match decision {
        "allow" => true,
        "deny" => false,
        _ => return Err("invalid approval decision"),
    };
    match event.method.as_str() {
        "item/commandExecution/requestApproval" | "item/fileChange/requestApproval" => Ok(json!({
            "decision": if allow { "accept" } else { "decline" }
        })),
        "execCommandApproval" | "applyPatchApproval" => Ok(if allow {
            json!({ "decision": "approved" })
        } else {
            json!({
                "decision": {
                    "denied": {
                        "rejection": message.unwrap_or("User denied the request")
                    }
                }
            })
        }),
        "item/permissions/requestApproval" => Ok(if allow {
            json!({
                "permissions": event.params.get("permissions").cloned().unwrap_or_else(|| json!({})),
                "scope": "turn"
            })
        } else {
            json!({ "permissions": {}, "scope": "turn" })
        }),
        _ => Err("provider request is not an approval"),
    }
}

pub(crate) fn codex_question_response(
    event: &ProviderEvent,
    decision: &str,
    answers: &Map<String, Value>,
) -> Result<Value, &'static str> {
    if event.method != "item/tool/requestUserInput" {
        return Err("provider request is not a question");
    }
    if !matches!(decision, "answer" | "deny") {
        return Err("invalid question decision");
    }
    let encoded = if decision == "deny" {
        Map::new()
    } else {
        answers
            .iter()
            .map(|(key, value)| {
                let values = match value {
                    Value::String(value) => vec![Value::String(value.clone())],
                    Value::Array(values) if values.iter().all(Value::is_string) => values.clone(),
                    _ => Vec::new(),
                };
                (key.clone(), json!({ "answers": values }))
            })
            .collect()
    };
    Ok(json!({ "answers": encoded }))
}

pub(crate) fn claude_approval_response(
    decision: &str,
    updated_input: Option<Value>,
    message: Option<&str>,
) -> Result<Value, &'static str> {
    match decision {
        "allow" => {
            let mut response =
                Map::from_iter([("decision".to_owned(), Value::String("allow".to_owned()))]);
            if let Some(updated_input) = updated_input {
                response.insert("updated_input".to_owned(), updated_input);
            }
            Ok(Value::Object(response))
        }
        "deny" => Ok(json!({
            "decision": "deny",
            "message": message.unwrap_or("User denied the request"),
            "interrupt": false,
        })),
        "defer" => Err("this provider request cannot be deferred"),
        _ => Err("invalid approval decision"),
    }
}

pub(crate) fn claude_question_response(
    decision: &str,
    answers: &Map<String, Value>,
    message: Option<&str>,
) -> Result<Value, &'static str> {
    match decision {
        "answer" => Ok(json!({ "decision": "answer", "answers": answers })),
        "deny" => Ok(json!({
            "decision": "deny",
            "message": message.unwrap_or("User declined to answer"),
            "interrupt": false,
        })),
        _ => Err("invalid question decision"),
    }
}

fn normalized_payload(
    kind: HumanRequestKind,
    action_id: &str,
    method: &str,
    params: &Value,
) -> Value {
    match kind {
        HumanRequestKind::Approval => approval_payload(action_id, method, params),
        HumanRequestKind::Question => question_payload(action_id, params),
    }
}

fn approval_payload(action_id: &str, method: &str, params: &Value) -> Value {
    let tool_name = params
        .get("tool_name")
        .or_else(|| params.get("toolName"))
        .and_then(Value::as_str)
        .map_or_else(|| approval_tool_name(method).to_owned(), str::to_owned);
    let input = params.get("input").unwrap_or(params);
    let command = input
        .get("command")
        .or_else(|| params.get("command"))
        .and_then(Value::as_str);
    let cwd = params
        .get("cwd")
        .or_else(|| params.get("context").and_then(|context| context.get("cwd")))
        .and_then(Value::as_str);
    let summary = params
        .get("reason")
        .or_else(|| {
            params
                .get("context")
                .and_then(|context| context.get("description"))
        })
        .and_then(Value::as_str)
        .or(command)
        .unwrap_or(&tool_name);
    let risk = params
        .get("risk")
        .or_else(|| params.get("risk_level"))
        .or_else(|| params.get("riskLevel"))
        .or_else(|| {
            params
                .get("context")
                .and_then(|context| context.get("decision_reason"))
        });
    let permission_suggestions = params
        .get("permissions")
        .or_else(|| params.get("permission_suggestions"))
        .or_else(|| params.get("permissionSuggestions"))
        .or_else(|| {
            params
                .get("context")
                .and_then(|context| context.get("suggestions"))
        });
    json!({
        "id": action_id,
        "kind": "approval",
        "tool_name": tool_name,
        "summary": summary,
        "command": command,
        "cwd": cwd,
        "paths": collect_paths(params),
        "risk": risk,
        "permission_suggestions": permission_suggestions,
        "choices": ["allow", "deny"],
        "deferrable": false,
    })
}

fn question_payload(action_id: &str, params: &Value) -> Value {
    let input = params.get("input").unwrap_or(params);
    let questions = input
        .get("questions")
        .and_then(Value::as_array)
        .map(|questions| {
            questions
                .iter()
                .enumerate()
                .filter_map(|(index, question)| {
                    let prompt = question.get("question")?.as_str()?;
                    let id = question
                        .get("id")
                        .and_then(Value::as_str)
                        .unwrap_or(prompt);
                    let options = question
                        .get("options")
                        .and_then(Value::as_array)
                        .map(|options| {
                            options
                                .iter()
                                .filter_map(|option| {
                                    if let Some(label) = option.as_str() {
                                        return Some(json!({ "label": label, "description": "" }));
                                    }
                                    Some(json!({
                                        "label": option.get("label")?.as_str()?,
                                        "description": option
                                            .get("description")
                                            .and_then(Value::as_str)
                                            .unwrap_or("")
                                    }))
                                })
                                .collect::<Vec<_>>()
                        })
                        .unwrap_or_default();
                    Some(json!({
                        "id": id,
                        "index": index,
                        "header": question.get("header").and_then(Value::as_str).unwrap_or("Question"),
                        "question": prompt,
                        "options": options,
                        "multi_select": question
                            .get("multiSelect")
                            .or_else(|| question.get("multi_select"))
                            .and_then(Value::as_bool)
                            .unwrap_or(false),
                        "secret": question
                            .get("isSecret")
                            .or_else(|| question.get("is_secret"))
                            .or_else(|| question.get("secret"))
                            .and_then(Value::as_bool)
                            .unwrap_or(false),
                    }))
                })
                .collect::<Vec<_>>()
        })
        .unwrap_or_default();
    json!({
        "id": action_id,
        "kind": "question",
        "questions": questions,
        "choices": ["answer", "deny"],
        "deferrable": false,
    })
}

fn approval_tool_name(method: &str) -> &'static str {
    match method {
        "item/commandExecution/requestApproval" | "execCommandApproval" => "Command",
        "item/fileChange/requestApproval" | "applyPatchApproval" => "File change",
        "item/permissions/requestApproval" => "Permissions",
        _ => "Tool",
    }
}

fn collect_paths(value: &Value) -> Vec<String> {
    let mut paths = Vec::new();
    collect_paths_into(value, &mut paths, 0);
    paths.sort();
    paths.dedup();
    paths.truncate(64);
    paths
}

fn collect_paths_into(value: &Value, paths: &mut Vec<String>, depth: usize) {
    if depth > 8 || paths.len() >= 64 {
        return;
    }
    match value {
        Value::Object(object) => {
            for (key, value) in object {
                if matches!(
                    key.as_str(),
                    "path" | "file_path" | "filePath" | "blocked_path" | "grantRoot"
                ) && let Some(path) = value.as_str()
                {
                    paths.push(path.to_owned());
                }
                collect_paths_into(value, paths, depth + 1);
            }
        }
        Value::Array(values) => {
            for value in values {
                collect_paths_into(value, paths, depth + 1);
            }
        }
        _ => {}
    }
}

fn timestamp() -> String {
    use time::OffsetDateTime;
    use time::format_description::well_known::Rfc3339;

    OffsetDateTime::now_utc()
        .format(&Rfc3339)
        .unwrap_or_else(|_| "1970-01-01T00:00:00Z".to_owned())
}

#[cfg(test)]
mod tests {
    use serde_json::json;

    use super::{
        claude_approval_response, codex_approval_response, codex_question_response, codex_request,
    };
    use crate::codex::{ProviderEvent, ProviderEventKind};

    fn event(method: &str, params: serde_json::Value) -> ProviderEvent {
        ProviderEvent {
            kind: ProviderEventKind::ServerRequest,
            request_id: Some(json!(1)),
            response_required: true,
            method: method.to_owned(),
            params,
        }
    }

    #[test]
    fn maps_codex_approval_shapes_without_inventing_persistence() {
        let command = event("item/commandExecution/requestApproval", json!({}));
        assert_eq!(
            codex_approval_response(&command, "allow", None).expect("allow"),
            json!({ "decision": "accept" })
        );
        assert_eq!(
            codex_approval_response(&command, "deny", None).expect("deny"),
            json!({ "decision": "decline" })
        );

        let permissions = event(
            "item/permissions/requestApproval",
            json!({ "permissions": { "network": { "enabled": true } } }),
        );
        assert_eq!(
            codex_approval_response(&permissions, "deny", None).expect("deny permissions"),
            json!({ "permissions": {}, "scope": "turn" })
        );
    }

    #[test]
    fn maps_public_answers_to_codex_answer_records() {
        let question = event("item/tool/requestUserInput", json!({}));
        let answers = serde_json::from_value(json!({
            "mode": "safe",
            "files": ["one", "two"]
        }))
        .expect("answer object");
        let response = codex_question_response(&question, "answer", &answers).expect("answer");
        assert_eq!(response["answers"]["mode"], json!({ "answers": ["safe"] }));
        assert_eq!(
            response["answers"]["files"],
            json!({ "answers": ["one", "two"] })
        );
    }

    #[test]
    fn redacts_native_callback_payload_after_normalizing_decision_detail() {
        let approval = event(
            "item/permissions/requestApproval",
            json!({
                "permissions": { "network": { "enabled": true } },
                "risk": "elevated",
                "input": { "path": "/tmp/project/file" }
            }),
        );
        let request =
            codex_request("agent-1", "approval-1".to_owned(), &approval).expect("approval request");
        assert_eq!(request.envelope.provider_event["redacted"], true);
        assert!(request.envelope.provider_event.get("params").is_none());
        assert_eq!(request.envelope.payload["risk"], "elevated");
        assert_eq!(
            request.envelope.payload["paths"],
            json!(["/tmp/project/file"])
        );
    }

    #[test]
    fn claude_allow_omits_absent_input_override() {
        let unchanged = claude_approval_response("allow", None, None).expect("allow");
        assert_eq!(unchanged, json!({ "decision": "allow" }));

        let updated =
            claude_approval_response("allow", Some(json!({ "command": "printf safe" })), None)
                .expect("allow with update");
        assert_eq!(updated["updated_input"]["command"], "printf safe");
    }
}
