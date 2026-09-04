//! Provider metadata/history projection and explicit editor-context rendering.

use std::collections::HashSet;
use std::path::Path;

use serde_json::{Value, json};

use crate::protocol::Provider;

pub(crate) fn provider_sessions(
    provider: Provider,
    result: &Value,
    active_session_ids: &HashSet<String>,
    activity_available: bool,
    active_only: bool,
    fallback_cwd: Option<&Path>,
) -> Value {
    let records = match provider {
        Provider::Codex => result.get("data"),
        Provider::Claude => result.get("sessions"),
    }
    .and_then(Value::as_array)
    .cloned()
    .unwrap_or_default();
    let sessions = records
        .iter()
        .filter_map(|record| session_record(provider, record, active_session_ids, fallback_cwd))
        .filter(|record| !active_only || record["active"] == true)
        .collect::<Vec<_>>();
    let observed_active = sessions.iter().any(|record| record["active"] == true);
    let cursor = match provider {
        Provider::Codex => result.get("nextCursor"),
        Provider::Claude => result
            .get("next_cursor")
            .or_else(|| result.get("nextCursor")),
    }
    .cloned()
    .unwrap_or(Value::Null);
    json!({
        "sessions": sessions,
        "cursor": cursor,
        "activity_available": activity_available || observed_active,
    })
}

pub(crate) fn provider_models(provider: Provider, result: &Value) -> Value {
    let records = result
        .get("data")
        .and_then(Value::as_array)
        .cloned()
        .unwrap_or_default();
    let mut seen = HashSet::new();
    let models = records
        .iter()
        .filter(|record| record.get("hidden").and_then(Value::as_bool) != Some(true))
        .filter_map(|record| {
            let id = first_string(record, &["model", "id"])?;
            if id.is_empty()
                || id.chars().count() > 256
                || id.chars().any(char::is_control)
                || !seen.insert(id.to_owned())
            {
                return None;
            }
            let display_name = first_string(record, &["displayName", "display_name", "name"])
                .filter(|value| !value.is_empty() && value.chars().count() <= 256)
                .unwrap_or(id);
            let description = first_string(record, &["description"])
                .filter(|value| !value.is_empty() && value.chars().count() <= 4_096);
            Some(json!({
                "id": id,
                "display_name": display_name,
                "description": description,
                "is_default": record
                    .get("isDefault")
                    .or_else(|| record.get("is_default"))
                    .and_then(Value::as_bool)
                    .unwrap_or(false),
            }))
        })
        .take(1_000)
        .collect::<Vec<_>>();
    json!({ "provider": provider, "models": models })
}

pub(crate) fn history(provider: Provider, result: &Value) -> Value {
    let messages = match provider {
        Provider::Codex => codex_history(result),
        Provider::Claude => claude_history(result),
    };
    json!({ "messages": messages, "cursor": null })
}

pub(crate) fn render_input(text: &str, attachments: &[Value]) -> Result<String, serde_json::Error> {
    if attachments.is_empty() {
        return Ok(text.to_owned());
    }
    let context = serde_json::to_string(attachments)?;
    Ok(format!(
        "<agent-manager-context format=\"json\">\n{context}\n</agent-manager-context>\n\n{text}"
    ))
}

fn session_record(
    provider: Provider,
    record: &Value,
    active_session_ids: &HashSet<String>,
    fallback_cwd: Option<&Path>,
) -> Option<Value> {
    let provider_session_id = first_string(
        record,
        &["id", "session_id", "sessionId", "provider_session_id"],
    )?;
    let cwd = first_string(record, &["cwd", "directory", "project_path"])
        .filter(|cwd| !cwd.is_empty())
        .map(str::to_owned)
        .or_else(|| fallback_cwd.map(|path| path.to_string_lossy().into_owned()))?;
    let explicit_title = first_string(record, &["name", "title", "summary"]);
    let short_id = provider_session_id
        .char_indices()
        .nth(12)
        .map_or(provider_session_id, |(index, _)| {
            &provider_session_id[..index]
        });
    let title = explicit_title
        .filter(|title| !title.is_empty())
        .map_or_else(|| format!("{provider} {short_id}"), str::to_owned);
    let updated_at = first_value(
        record,
        &["updatedAt", "updated_at", "last_modified", "modified_at"],
    )
    .cloned()
    .unwrap_or(Value::Null);
    let provider_status = record
        .get("status")
        .and_then(|status| status.get("type"))
        .and_then(Value::as_str);
    let active = record.get("active").and_then(Value::as_bool) == Some(true)
        || provider_status == Some("active")
        || active_session_ids.contains(provider_session_id);
    Some(json!({
        "provider": provider,
        "provider_session_id": provider_session_id,
        "cwd": cwd,
        "title": title,
        "updated_at": updated_at,
        "active": active,
        "state": if active { "running" } else { "resumable" },
    }))
}

fn codex_history(result: &Value) -> Vec<Value> {
    let Some(turns) = result
        .get("thread")
        .and_then(|thread| thread.get("turns"))
        .and_then(Value::as_array)
    else {
        return Vec::new();
    };
    let mut messages = Vec::new();
    for turn in turns {
        let turn_id = turn.get("id").and_then(Value::as_str);
        let Some(items) = turn.get("items").and_then(Value::as_array) else {
            continue;
        };
        for item in items {
            let Some(item_type) = item.get("type").and_then(Value::as_str) else {
                continue;
            };
            let role = match item_type {
                "userMessage" => "user",
                "agentMessage" => "assistant",
                _ => continue,
            };
            let Some(text) = text_from(item) else {
                continue;
            };
            messages.push(json!({
                "id": item.get("id").and_then(Value::as_str),
                "turn_id": turn_id,
                "role": role,
                "text": text,
            }));
        }
    }
    messages
}

fn claude_history(result: &Value) -> Vec<Value> {
    result
        .get("messages")
        .and_then(Value::as_array)
        .into_iter()
        .flatten()
        .enumerate()
        .filter_map(|(index, record)| {
            let role = first_string(record, &["role", "type"])
                .and_then(normalized_role)
                .or_else(|| {
                    record
                        .get("message")
                        .and_then(|message| first_string(message, &["role"]))
                        .and_then(normalized_role)
                })?;
            let text = text_from(record)?;
            let id = first_string(record, &["id", "uuid", "message_id"])
                .map_or_else(|| format!("history-{index}"), str::to_owned);
            Some(json!({ "id": id, "role": role, "text": text }))
        })
        .collect()
}

fn normalized_role(role: &str) -> Option<&'static str> {
    let lowercase = role.to_ascii_lowercase();
    if lowercase.contains("assistant") {
        Some("assistant")
    } else if lowercase.contains("user") || lowercase == "human" {
        Some("user")
    } else if lowercase.contains("system") {
        Some("system")
    } else {
        None
    }
}

fn text_from(value: &Value) -> Option<String> {
    text_from_depth(value, 0)
}

fn text_from_depth(value: &Value, depth: usize) -> Option<String> {
    if depth > 12 {
        return None;
    }
    match value {
        Value::String(text) if !text.is_empty() => Some(text.clone()),
        Value::Array(values) => {
            let parts = values
                .iter()
                .filter_map(|value| text_from_depth(value, depth + 1))
                .collect::<Vec<_>>();
            (!parts.is_empty()).then(|| parts.join(""))
        }
        Value::Object(object) => {
            for key in ["text", "content", "message", "delta"] {
                if let Some(text) = object
                    .get(key)
                    .and_then(|value| text_from_depth(value, depth + 1))
                {
                    return Some(text);
                }
            }
            None
        }
        _ => None,
    }
}

fn first_string<'a>(value: &'a Value, keys: &[&str]) -> Option<&'a str> {
    first_value(value, keys).and_then(Value::as_str)
}

fn first_value<'a>(value: &'a Value, keys: &[&str]) -> Option<&'a Value> {
    keys.iter().find_map(|key| value.get(*key))
}

#[cfg(test)]
mod tests {
    use serde_json::json;

    use std::collections::HashSet;

    use super::{history, provider_models, provider_sessions, render_input};
    use crate::protocol::Provider;

    #[test]
    fn projects_provider_metadata_without_transcript_previews() {
        let projected = provider_sessions(
            Provider::Codex,
            &json!({
                "data": [{
                    "id": "thread-1234567890",
                    "cwd": "/tmp/project",
                    "name": null,
                    "preview": "sensitive first prompt",
                    "updatedAt": 10
                }],
                "nextCursor": "next"
            }),
            &HashSet::new(),
            true,
            false,
            None,
        );
        assert_eq!(
            projected["sessions"][0]["provider_session_id"],
            "thread-1234567890"
        );
        assert_eq!(projected["cursor"], "next");
        assert!(!projected.to_string().contains("sensitive first prompt"));
    }

    #[test]
    fn projects_visible_provider_models_in_catalog_order() {
        let projected = provider_models(
            Provider::Codex,
            &json!({
                "data": [
                    {
                        "id": "model-default",
                        "model": "model-default",
                        "displayName": "Model Default",
                        "description": "Default model",
                        "hidden": false,
                        "isDefault": true
                    },
                    {
                        "id": "hidden-model",
                        "model": "hidden-model",
                        "displayName": "Hidden",
                        "hidden": true,
                        "isDefault": false
                    }
                ]
            }),
        );
        assert_eq!(projected["provider"], "codex");
        assert_eq!(projected["models"].as_array().map(Vec::len), Some(1));
        assert_eq!(projected["models"][0]["id"], "model-default");
        assert_eq!(projected["models"][0]["is_default"], true);
    }

    #[test]
    fn active_only_projection_uses_external_writer_observations() {
        let active_id = "018f6f57-7220-7dcb-9cf8-86f21b9754ed".to_owned();
        let projected = provider_sessions(
            Provider::Codex,
            &json!({
                "data": [
                    { "id": active_id, "cwd": "/workspace/live", "updatedAt": 2 },
                    { "id": "018f6f57-7220-7dcb-9cf8-86f21b9754ee", "cwd": "/workspace/old", "updatedAt": 1 }
                ],
                "nextCursor": null
            }),
            &HashSet::from([active_id]),
            true,
            true,
            None,
        );

        assert_eq!(projected["sessions"].as_array().map(Vec::len), Some(1));
        assert_eq!(projected["sessions"][0]["cwd"], "/workspace/live");
        assert_eq!(projected["sessions"][0]["state"], "running");
        assert_eq!(projected["activity_available"], true);
    }

    #[test]
    fn missing_provider_cwd_uses_the_requested_or_home_directory() {
        let projected = provider_sessions(
            Provider::Claude,
            &json!({
                "sessions": [{ "session_id": "session-without-directory" }]
            }),
            &HashSet::new(),
            true,
            false,
            Some(std::path::Path::new("/home/ai")),
        );

        assert_eq!(projected["sessions"][0]["cwd"], "/home/ai");
    }

    #[test]
    fn projects_codex_turn_messages() {
        let projected = history(
            Provider::Codex,
            &json!({
                "thread": { "turns": [{
                    "id": "turn-1",
                    "items": [
                        { "id": "u1", "type": "userMessage", "content": [{ "text": "hello" }] },
                        { "id": "a1", "type": "agentMessage", "text": "hi" }
                    ]
                }] }
            }),
        );
        assert_eq!(projected["messages"][0]["role"], "user");
        assert_eq!(projected["messages"][1]["text"], "hi");
    }

    #[test]
    fn renders_context_as_an_explicit_one_shot_prefix() {
        let rendered = render_input(
            "review this",
            &[json!({ "kind": "range", "payload": { "path": "/tmp/a", "text": "x" } })],
        )
        .expect("render input");
        assert!(rendered.contains("<agent-manager-context"));
        assert!(rendered.ends_with("review this"));
    }
}
