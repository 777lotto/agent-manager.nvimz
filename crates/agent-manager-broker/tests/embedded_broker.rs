use std::future::Future;
use std::path::PathBuf;
use std::time::Duration;

use agent_manager_broker::codex::CommandSpec;
use agent_manager_broker::embedded::{EmbeddedConfig, EmbeddedError, serve};
use agent_manager_broker::protocol::Provider;
use agent_manager_broker::worker::WorkerCommandSpec;
use serde_json::{Value, json};
use tokio::io::{
    AsyncBufReadExt, AsyncWriteExt, BufReader, DuplexStream, ReadHalf, WriteHalf, duplex, split,
};
use tokio::task::JoinHandle;
use tokio::time::timeout;

const IO_TIMEOUT: Duration = Duration::from_secs(5);

struct Harness {
    reader: BufReader<ReadHalf<DuplexStream>>,
    writer: WriteHalf<DuplexStream>,
    broker: JoinHandle<Result<(), EmbeddedError>>,
    transcript: Vec<Value>,
}

impl Harness {
    fn start() -> Self {
        Self::start_with_callback_timeout(Duration::from_secs(300))
    }

    fn start_with_callback_timeout(callback_timeout: Duration) -> Self {
        let codex = fixture_command("fake_m1_codex_app_server.py");
        let claude = fixture_command("fake_m1_claude_worker.py");
        Self::start_with_provider_commands(
            callback_timeout,
            CommandSpec {
                program: "python".to_owned(),
                args: vec![codex.to_string_lossy().into_owned()],
            },
            WorkerCommandSpec {
                program: "python".to_owned(),
                args: vec![claude.to_string_lossy().into_owned()],
            },
        )
    }

    fn start_with_provider_commands(
        callback_timeout: Duration,
        codex: CommandSpec,
        claude: WorkerCommandSpec,
    ) -> Self {
        let config = EmbeddedConfig::default()
            .with_provider_commands(codex, claude)
            .with_callback_timeout(callback_timeout);
        let (client, server) = duplex(1024 * 1024);
        let (client_reader, client_writer) = split(client);
        let (server_reader, server_writer) = split(server);
        let broker = tokio::spawn(serve(BufReader::new(server_reader), server_writer, config));
        Self {
            reader: BufReader::new(client_reader),
            writer: client_writer,
            broker,
            transcript: Vec::new(),
        }
    }

    async fn send(&mut self, message: Value) {
        let mut frame = serde_json::to_vec(&message).expect("serialize client message");
        frame.push(b'\n');
        self.send_raw(&frame).await;
    }

    async fn send_raw(&mut self, frame: &[u8]) {
        self.writer.write_all(frame).await.expect("write request");
        self.writer.flush().await.expect("flush request");
    }

    async fn receive(&mut self) -> Value {
        let mut line = String::new();
        let bytes = timeout(IO_TIMEOUT, self.reader.read_line(&mut line))
            .await
            .expect("broker response timed out")
            .expect("read broker response");
        assert_ne!(bytes, 0, "broker closed its output unexpectedly");
        let message: Value = serde_json::from_str(&line).expect("broker emitted JSON");
        self.transcript.push(message.clone());
        message
    }

    async fn wait_for(&mut self, mut predicate: impl FnMut(&Value) -> bool) -> Value {
        loop {
            let message = self.receive().await;
            if predicate(&message) {
                return message;
            }
        }
    }

    async fn response(&mut self, id: i64) -> Value {
        self.wait_for(|message| message.get("id").and_then(Value::as_i64) == Some(id))
            .await
    }

    async fn event(&mut self, event_type: &str) -> Value {
        self.wait_for(|message| {
            message.get("method").and_then(Value::as_str) == Some("agent/event")
                && message["params"]["type"] == event_type
        })
        .await
    }

    async fn state(&mut self, state: &str) -> Value {
        self.wait_for(|message| {
            message.get("method").and_then(Value::as_str) == Some("broker/state")
                && message["params"]["agents"]
                    .as_array()
                    .and_then(|agents| agents.first())
                    .is_some_and(|agent| agent["state"] == state)
        })
        .await
    }

    async fn shutdown(mut self, request_id: i64) {
        self.send(request(request_id, "broker/shutdown", json!({})))
            .await;
        assert_eq!(self.response(request_id).await["result"]["shutdown"], true);
        timeout(IO_TIMEOUT, self.broker)
            .await
            .expect("broker shutdown timed out")
            .expect("broker task panicked")
            .expect("broker shutdown failed");
    }
}

fn fixture_command(name: &str) -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .join("tests")
        .join("fixtures")
        .join(name)
}

fn request(id: i64, method: &str, params: Value) -> Value {
    let mut request = serde_json::Map::new();
    request.insert("jsonrpc".to_owned(), Value::String("2.0".to_owned()));
    request.insert("id".to_owned(), json!(id));
    request.insert("method".to_owned(), Value::String(method.to_owned()));
    request.insert("params".to_owned(), params);
    Value::Object(request)
}

#[allow(clippy::too_many_lines)]
async fn prove_embedded_flow(provider: Provider) {
    let mut harness = Harness::start();
    harness
        .send(request(
            1,
            "initialize",
            json!({
                "protocol_version": 1,
                "client": {
                    "name": "agent-manager-test",
                    "title": "Agent Manager Test",
                    "version": "0.1.0"
                },
                "last_sequence": null
            }),
        ))
        .await;
    let initialized = harness.response(1).await;
    assert_eq!(initialized["result"]["protocol_version"], 1);
    assert_eq!(initialized["result"]["mode"], "embedded");
    harness
        .send(json!({ "jsonrpc": "2.0", "method": "initialized", "params": {} }))
        .await;
    let empty_state = harness
        .wait_for(|message| message["method"] == "broker/state")
        .await;
    assert_eq!(empty_state["params"]["agents"], json!([]));

    let cwd = PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .canonicalize()
        .expect("canonical manifest directory");
    harness
        .send(request(
            20,
            "provider/session/list",
            json!({ "provider": provider, "cwd": cwd, "limit": 10 }),
        ))
        .await;
    let discovered = harness.response(20).await;
    assert_eq!(
        discovered["result"]["sessions"][0]["provider"],
        json!(provider)
    );
    assert!(
        discovered["result"]["sessions"][0]["provider_session_id"]
            .as_str()
            .is_some_and(|session_id| !session_id.is_empty())
    );
    harness
        .send(request(
            2,
            "agent/start",
            json!({
                "provider": provider,
                "cwd": cwd,
                "workspace_strategy": "shared"
            }),
        ))
        .await;
    let started = harness.response(2).await;
    let agent_id = started["result"]["agent"]["id"]
        .as_str()
        .expect("agent id")
        .to_owned();
    assert_eq!(started["result"]["agent"]["provider"], json!(provider));
    harness.state("idle").await;

    harness
        .send(request(
            21,
            "agent/context/add",
            json!({
                "agent_id": agent_id,
                "context": {
                    "kind": "range",
                    "payload": {
                        "path": cwd.join("Cargo.toml"),
                        "start_line": 1,
                        "end_line": 1,
                        "text": "[workspace]"
                    }
                }
            }),
        ))
        .await;
    assert_eq!(harness.response(21).await["result"]["queued"], true);

    send_input(&mut harness, 3, "agent/prompt", &agent_id, "first prompt").await;
    assert_eq!(harness.response(3).await["result"]["accepted"], true);
    harness.event("tool.started").await;
    let approval = harness.event("approval.requested").await;
    let approval_id = approval["params"]["payload"]["id"]
        .as_str()
        .expect("approval id")
        .to_owned();
    let waiting_approval = harness.state("waiting_approval").await;
    assert_eq!(
        waiting_approval["params"]["agents"][0]["pending_approvals"],
        1
    );
    harness
        .send(request(
            27,
            "agent/approval/respond",
            json!({
                "agent_id": agent_id,
                "approval_id": approval_id,
                "decision": "defer"
            }),
        ))
        .await;
    assert_eq!(harness.response(27).await["error"]["code"], -32_021);
    harness
        .send(request(
            22,
            "agent/approval/respond",
            json!({
                "agent_id": agent_id,
                "approval_id": approval_id,
                "decision": "allow"
            }),
        ))
        .await;
    assert_eq!(harness.response(22).await["result"]["resolved"], true);
    harness.event("approval.resolved").await;

    let question = harness.event("question.requested").await;
    let question_id = question["params"]["payload"]["id"]
        .as_str()
        .expect("question id")
        .to_owned();
    assert_eq!(
        question["params"]["payload"]["questions"][0]["question"],
        "Which mode?"
    );
    harness.state("waiting_input").await;
    harness
        .send(request(
            23,
            "agent/question/respond",
            json!({
                "agent_id": agent_id,
                "question_id": question_id,
                "answers": { "mode": "Safe", "Which mode?": "Safe" }
            }),
        ))
        .await;
    assert_eq!(harness.response(23).await["result"]["resolved"], true);
    harness.event("question.resolved").await;
    harness.event("usage.updated").await;
    harness.event("file.changed").await;
    harness.event("message.delta").await;
    harness.event("turn.completed").await;
    harness.state("completed").await;

    harness
        .send(request(
            24,
            "agent/history",
            json!({ "agent_id": agent_id, "limit": 20 }),
        ))
        .await;
    let history = harness.response(24).await;
    assert_eq!(history["result"]["messages"][0]["role"], "user");
    assert_eq!(history["result"]["messages"][1]["text"], "historic answer");

    send_input(
        &mut harness,
        4,
        "agent/prompt",
        &agent_id,
        "follow-up prompt",
    )
    .await;
    assert_eq!(harness.response(4).await["result"]["accepted"], true);
    harness.event("message.delta").await;
    harness.event("turn.completed").await;
    harness.state("completed").await;

    send_input(
        &mut harness,
        5,
        "agent/prompt",
        &agent_id,
        "long-running prompt",
    )
    .await;
    assert_eq!(harness.response(5).await["result"]["accepted"], true);
    harness.event("turn.started").await;

    send_input(&mut harness, 6, "agent/steer", &agent_id, "steering input").await;
    assert_eq!(harness.response(6).await["result"]["accepted"], true);
    harness.event("message.delta").await;

    harness
        .send(request(
            7,
            "agent/interrupt",
            json!({ "agent_id": agent_id }),
        ))
        .await;
    assert_eq!(harness.response(7).await["result"]["interrupted"], true);
    let interrupted = harness.event("turn.completed").await;
    let interrupted_payload = &interrupted["params"]["payload"];
    assert!(
        interrupted_payload["turn"]["status"] == "interrupted"
            || interrupted_payload["subtype"] == "interrupted"
    );
    harness.state("interrupted").await;

    harness.send(request(8, "agent/list", json!({}))).await;
    let listed = harness.response(8).await;
    assert_eq!(listed["result"]["agents"][0]["id"], agent_id);
    harness
        .send(request(9, "agent/attach", json!({ "agent_id": agent_id })))
        .await;
    assert_eq!(
        harness.response(9).await["result"]["agent"]["state"],
        "interrupted"
    );

    harness
        .send(request(10, "agent/replay", json!({ "after_sequence": 0 })))
        .await;
    let replay = harness.response(10).await;
    let replayed = replay["result"]["events"]
        .as_array()
        .expect("replay event array");
    let sequences = event_sequences(&harness.transcript);
    assert_eq!(replayed.len(), sequences.len());
    assert!(
        sequences
            .windows(2)
            .all(|window| window[1] == window[0] + 1),
        "public event sequences must be contiguous"
    );

    harness
        .send(request(25, "agent/diff", json!({ "agent_id": agent_id })))
        .await;
    let diff = harness.response(25).await;
    assert!(diff["result"]["diff"].is_string());

    harness
        .send(request(26, "agent/fork", json!({ "agent_id": agent_id })))
        .await;
    let forked = harness.response(26).await;
    assert_ne!(forked["result"]["agent"]["id"], agent_id);
    assert!(
        forked["result"]["agent"]["provider_session_id"]
            .as_str()
            .is_some_and(|session_id| session_id.ends_with("-fork"))
    );
    assert_eq!(forked["result"]["agent"]["state"], "idle");

    harness.shutdown(11).await;
}

async fn send_input(harness: &mut Harness, id: i64, method: &str, agent_id: &str, text: &str) {
    harness
        .send(request(
            id,
            method,
            json!({
                "agent_id": agent_id,
                "input": { "text": text, "attachments": [] }
            }),
        ))
        .await;
}

fn event_sequences(transcript: &[Value]) -> Vec<u64> {
    transcript
        .iter()
        .filter(|message| message["method"] == "agent/event")
        .filter_map(|message| message["params"]["sequence"].as_u64())
        .collect()
}

async fn completes_within(
    future: impl Future<Output = ()>,
) -> Result<(), tokio::time::error::Elapsed> {
    timeout(Duration::from_secs(15), future).await
}

async fn prove_specific_resume(provider: Provider, provider_session_id: &str) {
    let mut harness = Harness::start();
    harness
        .send(request(
            1,
            "initialize",
            json!({
                "protocol_version": 1,
                "client": { "name": "resume-test", "version": "0.1.0" }
            }),
        ))
        .await;
    assert_eq!(harness.response(1).await["result"]["protocol_version"], 1);
    harness
        .send(json!({ "jsonrpc": "2.0", "method": "initialized", "params": {} }))
        .await;
    harness
        .wait_for(|message| message["method"] == "broker/state")
        .await;
    let cwd = PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .canonicalize()
        .expect("canonical manifest directory");
    harness
        .send(request(
            2,
            "agent/resume",
            json!({
                "provider": provider,
                "provider_session_id": provider_session_id,
                "cwd": cwd,
                "workspace_strategy": "shared"
            }),
        ))
        .await;
    let resumed = harness.response(2).await;
    assert_eq!(
        resumed["result"]["agent"]["provider_session_id"],
        provider_session_id
    );
    harness.state("idle").await;
    harness.shutdown(3).await;
}

async fn prove_callback_timeout_fails_closed(provider: Provider) {
    let mut harness = Harness::start_with_callback_timeout(Duration::from_millis(40));
    harness
        .send(request(
            1,
            "initialize",
            json!({
                "protocol_version": 1,
                "client": { "name": "timeout-test", "version": "0.1.0" }
            }),
        ))
        .await;
    harness.response(1).await;
    harness
        .send(json!({ "jsonrpc": "2.0", "method": "initialized", "params": {} }))
        .await;
    harness
        .wait_for(|message| message["method"] == "broker/state")
        .await;
    let cwd = PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .canonicalize()
        .expect("canonical manifest directory");
    harness
        .send(request(
            2,
            "agent/start",
            json!({ "provider": provider, "cwd": cwd, "workspace_strategy": "shared" }),
        ))
        .await;
    let started = harness.response(2).await;
    let agent_id = started["result"]["agent"]["id"]
        .as_str()
        .expect("agent id")
        .to_owned();
    harness.state("idle").await;
    harness
        .send(request(
            3,
            "agent/context/add",
            json!({
                "agent_id": agent_id,
                "context": {
                    "kind": "buffer",
                    "payload": { "path": cwd.join("Cargo.toml"), "text": "[workspace]" }
                }
            }),
        ))
        .await;
    harness.response(3).await;
    send_input(
        &mut harness,
        4,
        "agent/prompt",
        &agent_id,
        "wait for approval",
    )
    .await;
    harness.response(4).await;
    harness.event("approval.requested").await;
    let resolved = harness.event("approval.resolved").await;
    assert_eq!(resolved["params"]["payload"]["decision"], "deny");
    assert_eq!(resolved["params"]["payload"]["reason"], "timeout");
    harness.shutdown(5).await;
}

async fn prove_interrupt_denies_pending_callback(provider: Provider) {
    let mut harness = Harness::start();
    harness
        .send(request(
            1,
            "initialize",
            json!({
                "protocol_version": 1,
                "client": { "name": "interrupt-test", "version": "0.1.0" }
            }),
        ))
        .await;
    harness.response(1).await;
    harness
        .send(json!({ "jsonrpc": "2.0", "method": "initialized", "params": {} }))
        .await;
    harness
        .wait_for(|message| message["method"] == "broker/state")
        .await;
    let cwd = PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .canonicalize()
        .expect("canonical manifest directory");
    harness
        .send(request(
            2,
            "agent/start",
            json!({ "provider": provider, "cwd": cwd, "workspace_strategy": "shared" }),
        ))
        .await;
    let started = harness.response(2).await;
    let agent_id = started["result"]["agent"]["id"]
        .as_str()
        .expect("agent id")
        .to_owned();
    harness.state("idle").await;
    harness
        .send(request(
            3,
            "agent/context/add",
            json!({
                "agent_id": agent_id,
                "context": {
                    "kind": "buffer",
                    "payload": { "path": cwd.join("Cargo.toml"), "text": "[workspace]" }
                }
            }),
        ))
        .await;
    harness.response(3).await;
    send_input(
        &mut harness,
        4,
        "agent/prompt",
        &agent_id,
        "interrupt pending approval",
    )
    .await;
    harness.response(4).await;
    harness.event("approval.requested").await;
    harness
        .send(request(
            5,
            "agent/interrupt",
            json!({ "agent_id": agent_id }),
        ))
        .await;
    let resolved = harness.event("approval.resolved").await;
    assert_eq!(resolved["params"]["payload"]["decision"], "deny");
    assert_eq!(resolved["params"]["payload"]["reason"], "interrupt");
    assert_eq!(harness.response(5).await["result"]["interrupted"], true);
    harness.shutdown(6).await;
}

#[tokio::test]
async fn codex_embedded_flow_streams_follow_up_steer_interrupt_and_replay() {
    completes_within(prove_embedded_flow(Provider::Codex))
        .await
        .expect("Codex embedded flow timed out");
}

#[tokio::test]
async fn claude_embedded_flow_streams_follow_up_steer_interrupt_and_replay() {
    completes_within(prove_embedded_flow(Provider::Claude))
        .await
        .expect("Claude embedded flow timed out");
}

#[tokio::test]
async fn codex_embedded_flow_resumes_one_specific_provider_session() {
    completes_within(prove_specific_resume(Provider::Codex, "thread-resumable"))
        .await
        .expect("Codex resume timed out");
}

#[tokio::test]
async fn claude_embedded_flow_resumes_one_specific_provider_session() {
    completes_within(prove_specific_resume(Provider::Claude, "session-resumable"))
        .await
        .expect("Claude resume timed out");
}

#[tokio::test]
async fn provider_callbacks_time_out_fail_closed() {
    completes_within(async {
        prove_callback_timeout_fails_closed(Provider::Codex).await;
        prove_callback_timeout_fails_closed(Provider::Claude).await;
    })
    .await
    .expect("callback timeout flow timed out");
}

#[tokio::test]
async fn interrupt_denies_pending_provider_callbacks() {
    completes_within(async {
        prove_interrupt_denies_pending_callback(Provider::Codex).await;
        prove_interrupt_denies_pending_callback(Provider::Claude).await;
    })
    .await
    .expect("callback interrupt flow timed out");
}

#[tokio::test]
async fn public_boundary_rejects_malformed_uninitialized_and_unknown_requests() {
    let mut harness = Harness::start();
    harness.send_raw(b"{not-json}\n").await;
    let parse_error = harness.receive().await;
    assert_eq!(parse_error["id"], Value::Null);
    assert_eq!(parse_error["error"]["code"], -32_700);

    harness.send(request(1, "agent/list", json!({}))).await;
    assert_eq!(harness.response(1).await["error"]["code"], -32_002);

    harness
        .send(request(
            2,
            "initialize",
            json!({
                "protocol_version": 1,
                "client": { "name": "negative-test", "version": "0.1.0" }
            }),
        ))
        .await;
    assert_eq!(harness.response(2).await["result"]["protocol_version"], 1);
    harness
        .send(json!({ "jsonrpc": "2.0", "method": "initialized", "params": {} }))
        .await;
    harness
        .wait_for(|message| message["method"] == "broker/state")
        .await;

    harness.send(request(3, "future/method", json!({}))).await;
    assert_eq!(harness.response(3).await["error"]["code"], -32_601);
    harness.shutdown(4).await;
}

#[tokio::test]
async fn failed_provider_start_releases_the_embedded_live_slot() {
    let claude = fixture_command("fake_m1_claude_worker.py");
    let mut harness = Harness::start_with_provider_commands(
        Duration::from_secs(300),
        CommandSpec {
            program: "/definitely/missing/agent-manager-codex".to_owned(),
            args: Vec::new(),
        },
        WorkerCommandSpec {
            program: "python".to_owned(),
            args: vec![claude.to_string_lossy().into_owned()],
        },
    );
    harness
        .send(request(
            1,
            "initialize",
            json!({
                "protocol_version": 1,
                "client": { "name": "recovery-test", "version": "0.1.0" }
            }),
        ))
        .await;
    harness.response(1).await;
    harness
        .send(json!({ "jsonrpc": "2.0", "method": "initialized", "params": {} }))
        .await;
    harness
        .wait_for(|message| message["method"] == "broker/state")
        .await;
    let cwd = PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .canonicalize()
        .expect("canonical manifest directory");
    harness
        .send(request(
            2,
            "agent/start",
            json!({ "provider": "codex", "cwd": cwd, "workspace_strategy": "shared" }),
        ))
        .await;
    assert_eq!(harness.response(2).await["error"]["code"], -32_020);
    harness.state("disconnected").await;

    harness
        .send(request(
            3,
            "agent/start",
            json!({ "provider": "claude", "cwd": cwd, "workspace_strategy": "shared" }),
        ))
        .await;
    assert_eq!(
        harness.response(3).await["result"]["agent"]["provider"],
        "claude"
    );
    harness.shutdown(4).await;
}
