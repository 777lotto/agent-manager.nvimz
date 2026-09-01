//! Provider tasks owned by the embedded broker.

use std::path::PathBuf;

use serde_json::{Value, json};
use time::OffsetDateTime;
use time::format_description::well_known::Rfc3339;
use tokio::sync::mpsc;
use tokio::task::JoinHandle;
use uuid::Uuid;

use crate::codex::{
    CodexAppServer, CodexError, CommandSpec, ProviderEvent, normalize_event, thread_id, turn_id,
};
use crate::protocol::{EventEnvelope, Provider, RequestId};
use crate::worker::{ClaudeWorker, WorkerCommandSpec, WorkerError, WorkerInbound};

const PROVIDER_ERROR_CODE: i64 = -32_020;
const INVALID_STATE_CODE: i64 = -32_021;

#[derive(Debug)]
pub(crate) enum AgentCommand {
    Prompt { request_id: RequestId, text: String },
    Steer { request_id: RequestId, text: String },
    Interrupt { request_id: RequestId },
    Shutdown,
}

#[derive(Debug)]
pub(crate) enum RuntimeEvent {
    Started {
        request_id: RequestId,
        agent_id: String,
        provider_session_id: String,
    },
    Response {
        request_id: RequestId,
        result: Value,
    },
    RequestFailed {
        request_id: RequestId,
        agent_id: String,
        code: i64,
        message: &'static str,
    },
    ProviderEvent(EventEnvelope),
    ProviderFailed {
        agent_id: String,
        message: &'static str,
    },
    Stopped {
        agent_id: String,
    },
}

#[derive(Clone, Debug, Default)]
pub(crate) struct RuntimeConfig {
    pub codex: CommandSpec,
    pub claude: WorkerCommandSpec,
}

pub(crate) fn spawn_agent(
    provider: Provider,
    agent_id: String,
    cwd: PathBuf,
    start_request_id: RequestId,
    config: RuntimeConfig,
    events: mpsc::UnboundedSender<RuntimeEvent>,
) -> (mpsc::Sender<AgentCommand>, JoinHandle<()>) {
    let (commands_tx, commands_rx) = mpsc::channel(32);
    let handle = match provider {
        Provider::Codex => tokio::spawn(run_codex(
            agent_id,
            cwd,
            start_request_id,
            config.codex,
            commands_rx,
            events,
        )),
        Provider::Claude => tokio::spawn(run_claude(
            agent_id,
            cwd,
            start_request_id,
            config.claude,
            commands_rx,
            events,
        )),
    };
    (commands_tx, handle)
}

#[allow(clippy::too_many_lines)]
async fn run_codex(
    agent_id: String,
    cwd: PathBuf,
    start_request_id: RequestId,
    spec: CommandSpec,
    mut commands: mpsc::Receiver<AgentCommand>,
    events: mpsc::UnboundedSender<RuntimeEvent>,
) {
    let Ok(mut server) = CodexAppServer::spawn(&spec) else {
        start_failed(
            &events,
            start_request_id,
            &agent_id,
            "Codex App Server could not be started",
        );
        return;
    };
    if server.initialize().await.is_err() {
        start_failed(
            &events,
            start_request_id,
            &agent_id,
            "Codex App Server initialization failed",
        );
        let _ = server.shutdown().await;
        return;
    }
    let Ok(started) = server.start_thread(&cwd).await else {
        start_failed(
            &events,
            start_request_id,
            &agent_id,
            "Codex thread creation failed",
        );
        let _ = server.shutdown().await;
        return;
    };
    let Some(provider_session_id) = thread_id(&started.result).map(str::to_owned) else {
        start_failed(
            &events,
            start_request_id,
            &agent_id,
            "Codex thread creation omitted its identity",
        );
        let _ = server.shutdown().await;
        return;
    };
    if events
        .send(RuntimeEvent::Started {
            request_id: start_request_id,
            agent_id: agent_id.clone(),
            provider_session_id: provider_session_id.clone(),
        })
        .is_err()
    {
        let _ = server.shutdown().await;
        return;
    }
    if publish_codex_events(&mut server, &agent_id, started.events, &events)
        .await
        .is_err()
    {
        provider_failed(&events, &agent_id, "Codex startup events were invalid");
        let _ = server.shutdown().await;
        return;
    }

    let mut active_turn_id: Option<String> = None;
    loop {
        tokio::select! {
            command = commands.recv() => {
                let Some(command) = command else {
                    break;
                };
                match command {
                    AgentCommand::Prompt { request_id, text } => {
                        if active_turn_id.is_some() {
                            request_failed(
                                &events,
                                request_id,
                                &agent_id,
                                INVALID_STATE_CODE,
                                "agent already has an active turn",
                            );
                            continue;
                        }
                        match server.start_turn(&provider_session_id, &text).await {
                            Ok(outcome) => {
                                let Some(new_turn_id) = turn_id(&outcome.result).map(str::to_owned) else {
                                    request_failed(
                                        &events,
                                        request_id,
                                        &agent_id,
                                        PROVIDER_ERROR_CODE,
                                        "Codex turn creation omitted its identity",
                                    );
                                    continue;
                                };
                                let _ = events.send(RuntimeEvent::Response {
                                    request_id,
                                    result: json!({ "accepted": true, "turn_id": new_turn_id }),
                                });
                                active_turn_id = Some(new_turn_id);
                                match publish_codex_events(
                                    &mut server,
                                    &agent_id,
                                    outcome.events,
                                    &events,
                                )
                                .await
                                {
                                    Ok(true) => active_turn_id = None,
                                    Ok(false) => {}
                                    Err(_) => {
                                        provider_failed(
                                            &events,
                                            &agent_id,
                                            "Codex turn events were invalid",
                                        );
                                        break;
                                    }
                                }
                            }
                            Err(_) => request_failed(
                                &events,
                                request_id,
                                &agent_id,
                                PROVIDER_ERROR_CODE,
                                "Codex rejected the prompt",
                            ),
                        }
                    }
                    AgentCommand::Steer { request_id, text } => {
                        let Some(turn_id) = active_turn_id.as_deref() else {
                            request_failed(
                                &events,
                                request_id,
                                &agent_id,
                                INVALID_STATE_CODE,
                                "agent has no active turn to steer",
                            );
                            continue;
                        };
                        match server.steer(&provider_session_id, turn_id, &text).await {
                            Ok(outcome) => {
                                let _ = events.send(RuntimeEvent::Response {
                                    request_id,
                                    result: json!({ "accepted": true }),
                                });
                                match publish_codex_events(
                                    &mut server,
                                    &agent_id,
                                    outcome.events,
                                    &events,
                                )
                                .await
                                {
                                    Ok(true) => active_turn_id = None,
                                    Ok(false) => {}
                                    Err(_) => {
                                        provider_failed(
                                            &events,
                                            &agent_id,
                                            "Codex steer events were invalid",
                                        );
                                        break;
                                    }
                                }
                            }
                            Err(_) => request_failed(
                                &events,
                                request_id,
                                &agent_id,
                                PROVIDER_ERROR_CODE,
                                "Codex rejected the steering input",
                            ),
                        }
                    }
                    AgentCommand::Interrupt { request_id } => {
                        let Some(turn_id) = active_turn_id.as_deref() else {
                            let _ = events.send(RuntimeEvent::Response {
                                request_id,
                                result: json!({ "interrupted": false, "reason": "no_active_turn" }),
                            });
                            continue;
                        };
                        match server.interrupt_with_events(&provider_session_id, turn_id).await {
                            Ok(outcome) => {
                                let _ = events.send(RuntimeEvent::Response {
                                    request_id,
                                    result: json!({ "interrupted": true }),
                                });
                                match publish_codex_events(
                                    &mut server,
                                    &agent_id,
                                    outcome.events,
                                    &events,
                                )
                                .await
                                {
                                    Ok(true) => active_turn_id = None,
                                    Ok(false) => {}
                                    Err(_) => {
                                        provider_failed(
                                            &events,
                                            &agent_id,
                                            "Codex interrupt events were invalid",
                                        );
                                        break;
                                    }
                                }
                            }
                            Err(_) => request_failed(
                                &events,
                                request_id,
                                &agent_id,
                                PROVIDER_ERROR_CODE,
                                "Codex interrupt failed",
                            ),
                        }
                    }
                    AgentCommand::Shutdown => break,
                }
            }
            provider_event = server.next_event(), if active_turn_id.is_some() => {
                if let Ok(provider_event) = provider_event {
                    match publish_codex_event(&mut server, &agent_id, provider_event, &events).await {
                        Ok(true) => active_turn_id = None,
                        Ok(false) => {}
                        Err(_) => {
                            provider_failed(&events, &agent_id, "Codex event stream failed");
                            break;
                        }
                    }
                } else {
                    provider_failed(&events, &agent_id, "Codex event stream disconnected");
                    break;
                }
            }
        }
    }

    let _ = server.shutdown().await;
    let _ = events.send(RuntimeEvent::Stopped { agent_id });
}

async fn publish_codex_events(
    server: &mut CodexAppServer,
    agent_id: &str,
    provider_events: Vec<ProviderEvent>,
    events: &mpsc::UnboundedSender<RuntimeEvent>,
) -> Result<bool, CodexError> {
    let mut terminal = false;
    for provider_event in provider_events {
        terminal |= publish_codex_event(server, agent_id, provider_event, events).await?;
    }
    Ok(terminal)
}

async fn publish_codex_event(
    server: &mut CodexAppServer,
    agent_id: &str,
    mut provider_event: ProviderEvent,
    events: &mpsc::UnboundedSender<RuntimeEvent>,
) -> Result<bool, CodexError> {
    let terminal = matches!(provider_event.method.as_str(), "turn/completed" | "error");
    if provider_event.response_required {
        server.deny_server_request(&mut provider_event).await?;
    }
    let normalized = normalize_event(agent_id, &provider_event)?;
    let _ = events.send(RuntimeEvent::ProviderEvent(normalized));
    Ok(terminal)
}

#[allow(clippy::too_many_lines)]
async fn run_claude(
    agent_id: String,
    cwd: PathBuf,
    start_request_id: RequestId,
    spec: WorkerCommandSpec,
    mut commands: mpsc::Receiver<AgentCommand>,
    events: mpsc::UnboundedSender<RuntimeEvent>,
) {
    let Ok(mut worker) = ClaudeWorker::spawn(&spec) else {
        start_failed(
            &events,
            start_request_id,
            &agent_id,
            "Claude worker could not be started",
        );
        return;
    };
    if worker.initialize().await.is_err() {
        start_failed(
            &events,
            start_request_id,
            &agent_id,
            "Claude worker initialization failed",
        );
        let _ = worker.shutdown().await;
        return;
    }
    let Ok(started) = worker
        .request("session/start", json!({ "agent_id": agent_id, "cwd": cwd }))
        .await
    else {
        start_failed(
            &events,
            start_request_id,
            &agent_id,
            "Claude session creation failed",
        );
        let _ = worker.shutdown().await;
        return;
    };
    let Some(provider_session_id) = started
        .result
        .get("provider_session_id")
        .and_then(Value::as_str)
        .map(str::to_owned)
    else {
        start_failed(
            &events,
            start_request_id,
            &agent_id,
            "Claude session creation omitted its identity",
        );
        let _ = worker.shutdown().await;
        return;
    };
    if events
        .send(RuntimeEvent::Started {
            request_id: start_request_id,
            agent_id: agent_id.clone(),
            provider_session_id,
        })
        .is_err()
    {
        let _ = worker.shutdown().await;
        return;
    }
    if publish_worker_inbound(&mut worker, &agent_id, started.inbound, &events)
        .await
        .is_err()
    {
        provider_failed(&events, &agent_id, "Claude startup events were invalid");
        let _ = worker.shutdown().await;
        return;
    }

    let mut active_turn_id: Option<String> = None;
    loop {
        tokio::select! {
            command = commands.recv() => {
                let Some(command) = command else {
                    break;
                };
                match command {
                    AgentCommand::Prompt { request_id, text } => {
                        if active_turn_id.is_some() {
                            request_failed(
                                &events,
                                request_id,
                                &agent_id,
                                INVALID_STATE_CODE,
                                "agent already has an active turn",
                            );
                            continue;
                        }
                        match worker.request("turn/prompt", json!({ "agent_id": agent_id, "text": text })).await {
                            Ok(outcome) => {
                                let new_turn_id = Uuid::new_v4().to_string();
                                let _ = events.send(RuntimeEvent::Response {
                                    request_id,
                                    result: json!({ "accepted": true, "turn_id": new_turn_id }),
                                });
                                active_turn_id = Some(new_turn_id.clone());
                                let _ = events.send(RuntimeEvent::ProviderEvent(synthetic_claude_event(
                                    &agent_id,
                                    "turn.started",
                                    json!({ "turn": { "id": new_turn_id } }),
                                    "turn/prompt",
                                )));
                                match publish_worker_inbound(
                                    &mut worker,
                                    &agent_id,
                                    outcome.inbound,
                                    &events,
                                )
                                .await
                                {
                                    Ok(true) => active_turn_id = None,
                                    Ok(false) => {}
                                    Err(_) => {
                                        provider_failed(
                                            &events,
                                            &agent_id,
                                            "Claude turn events were invalid",
                                        );
                                        break;
                                    }
                                }
                            }
                            Err(_) => request_failed(
                                &events,
                                request_id,
                                &agent_id,
                                PROVIDER_ERROR_CODE,
                                "Claude rejected the prompt",
                            ),
                        }
                    }
                    AgentCommand::Steer { request_id, text } => {
                        if active_turn_id.is_none() {
                            request_failed(
                                &events,
                                request_id,
                                &agent_id,
                                INVALID_STATE_CODE,
                                "agent has no active turn to steer",
                            );
                            continue;
                        }
                        match worker.request("turn/steer", json!({ "agent_id": agent_id, "text": text })).await {
                            Ok(outcome) => {
                                let _ = events.send(RuntimeEvent::Response {
                                    request_id,
                                    result: json!({ "accepted": true }),
                                });
                                match publish_worker_inbound(
                                    &mut worker,
                                    &agent_id,
                                    outcome.inbound,
                                    &events,
                                )
                                .await
                                {
                                    Ok(true) => active_turn_id = None,
                                    Ok(false) => {}
                                    Err(_) => {
                                        provider_failed(
                                            &events,
                                            &agent_id,
                                            "Claude steer events were invalid",
                                        );
                                        break;
                                    }
                                }
                            }
                            Err(_) => request_failed(
                                &events,
                                request_id,
                                &agent_id,
                                PROVIDER_ERROR_CODE,
                                "Claude rejected the steering input",
                            ),
                        }
                    }
                    AgentCommand::Interrupt { request_id } => {
                        if active_turn_id.is_none() {
                            let _ = events.send(RuntimeEvent::Response {
                                request_id,
                                result: json!({ "interrupted": false, "reason": "no_active_turn" }),
                            });
                            continue;
                        }
                        match worker.request("turn/interrupt", json!({ "agent_id": agent_id })).await {
                            Ok(outcome) => {
                                let _ = events.send(RuntimeEvent::Response {
                                    request_id,
                                    result: outcome.result,
                                });
                                match publish_worker_inbound(
                                    &mut worker,
                                    &agent_id,
                                    outcome.inbound,
                                    &events,
                                )
                                .await
                                {
                                    Ok(true) => active_turn_id = None,
                                    Ok(false) => {}
                                    Err(_) => {
                                        provider_failed(
                                            &events,
                                            &agent_id,
                                            "Claude interrupt events were invalid",
                                        );
                                        break;
                                    }
                                }
                            }
                            Err(_) => request_failed(
                                &events,
                                request_id,
                                &agent_id,
                                PROVIDER_ERROR_CODE,
                                "Claude interrupt failed",
                            ),
                        }
                    }
                    AgentCommand::Shutdown => break,
                }
            }
            inbound = worker.next_inbound(), if active_turn_id.is_some() => {
                if let Ok(inbound) = inbound {
                    match publish_worker_event(&mut worker, &agent_id, inbound, &events).await {
                        Ok(true) => active_turn_id = None,
                        Ok(false) => {}
                        Err(_) => {
                            provider_failed(&events, &agent_id, "Claude event stream failed");
                            break;
                        }
                    }
                } else {
                    provider_failed(&events, &agent_id, "Claude event stream disconnected");
                    break;
                }
            }
        }
    }

    let _ = worker.shutdown().await;
    let _ = events.send(RuntimeEvent::Stopped { agent_id });
}

async fn publish_worker_inbound(
    worker: &mut ClaudeWorker,
    agent_id: &str,
    inbound: Vec<WorkerInbound>,
    events: &mpsc::UnboundedSender<RuntimeEvent>,
) -> Result<bool, WorkerError> {
    let mut terminal = false;
    for event in inbound {
        terminal |= publish_worker_event(worker, agent_id, event, events).await?;
    }
    Ok(terminal)
}

async fn publish_worker_event(
    worker: &mut ClaudeWorker,
    agent_id: &str,
    inbound: WorkerInbound,
    events: &mpsc::UnboundedSender<RuntimeEvent>,
) -> Result<bool, WorkerError> {
    if let Some(callback_id) = inbound.id.as_ref() {
        worker
            .deny_callback(callback_id, "Agent Manager M1 has no approval UI")
            .await?;
    }
    let normalized_type = normalized_worker_event_type(&inbound);
    let terminal = matches!(normalized_type, "turn.completed" | "turn.failed");
    let payload = if inbound.method == "session/event" {
        inbound
            .params
            .get("payload")
            .cloned()
            .unwrap_or_else(|| json!({}))
    } else {
        inbound.params.clone()
    };
    let provider_event = json!({
        "kind": if inbound.id.is_some() { "request" } else { "notification" },
        "request_id": inbound.id,
        "response_required": false,
        "method": inbound.method,
        "params": inbound.params,
    });
    let envelope = EventEnvelope::new(
        timestamp(),
        agent_id.to_owned(),
        Provider::Claude,
        normalized_type.to_owned(),
        payload,
        provider_event,
    );
    let _ = events.send(RuntimeEvent::ProviderEvent(envelope));
    Ok(terminal)
}

fn normalized_worker_event_type(inbound: &WorkerInbound) -> &'static str {
    match inbound.method.as_str() {
        "approval/request" => "approval.requested",
        "question/request" => "question.requested",
        "session/event" => match inbound.params["event_type"].as_str() {
            Some("message.assistant") => "message.completed",
            Some("stream.event") => "message.delta",
            Some("result") if inbound.params["payload"]["is_error"] == true => "turn.failed",
            Some("result") => "turn.completed",
            Some("task.started") => "tool.started",
            Some("task.progress" | "hook.event") => "tool.progress",
            Some("task.notification") => "tool.completed",
            Some("rate_limit") => "usage.updated",
            Some("provider.error") => "turn.failed",
            _ => "provider.notice",
        },
        _ => "provider.notice",
    }
}

fn synthetic_claude_event(
    agent_id: &str,
    event_type: &str,
    payload: Value,
    provider_method: &str,
) -> EventEnvelope {
    EventEnvelope::new(
        timestamp(),
        agent_id.to_owned(),
        Provider::Claude,
        event_type.to_owned(),
        payload,
        json!({ "kind": "synthetic", "method": provider_method }),
    )
}

fn timestamp() -> String {
    OffsetDateTime::now_utc()
        .format(&Rfc3339)
        .unwrap_or_else(|_| "1970-01-01T00:00:00Z".to_owned())
}

fn start_failed(
    events: &mpsc::UnboundedSender<RuntimeEvent>,
    request_id: RequestId,
    agent_id: &str,
    message: &'static str,
) {
    request_failed(events, request_id, agent_id, PROVIDER_ERROR_CODE, message);
}

fn request_failed(
    events: &mpsc::UnboundedSender<RuntimeEvent>,
    request_id: RequestId,
    agent_id: &str,
    code: i64,
    message: &'static str,
) {
    let _ = events.send(RuntimeEvent::RequestFailed {
        request_id,
        agent_id: agent_id.to_owned(),
        code,
        message,
    });
}

fn provider_failed(
    events: &mpsc::UnboundedSender<RuntimeEvent>,
    agent_id: &str,
    message: &'static str,
) {
    let _ = events.send(RuntimeEvent::ProviderFailed {
        agent_id: agent_id.to_owned(),
        message,
    });
}
