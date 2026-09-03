use std::collections::VecDeque;
use std::fs;
use std::os::unix::fs::PermissionsExt;
use std::path::{Path, PathBuf};
use std::process::Command;
use std::time::Duration;

use agent_manager_broker::codex::CommandSpec;
use agent_manager_broker::durable::{DurableConfig, DurableError, serve_until};
use agent_manager_broker::embedded::EmbeddedConfig;
use agent_manager_broker::worker::WorkerCommandSpec;
use serde_json::{Value, json};
use tokio::io::{AsyncBufReadExt, AsyncWriteExt, BufReader};
use tokio::net::UnixStream;
use tokio::net::unix::{OwnedReadHalf, OwnedWriteHalf};
use tokio::sync::oneshot;
use tokio::task::JoinHandle;
use tokio::time::timeout;

const IO_TIMEOUT: Duration = Duration::from_secs(5);

struct DurableServer {
    directory: PathBuf,
    socket: PathBuf,
    registry: PathBuf,
    shutdown: Option<oneshot::Sender<()>>,
    task: JoinHandle<Result<(), DurableError>>,
}

impl DurableServer {
    async fn start(replay_capacity: usize) -> Self {
        Self::start_with_codex(replay_capacity, "fake_m1_codex_app_server.py").await
    }

    async fn start_with_codex(replay_capacity: usize, codex_fixture: &str) -> Self {
        let directory = std::env::temp_dir().join(format!(
            "agent-manager-durable-integration-{}",
            uuid::Uuid::new_v4()
        ));
        fs::create_dir(&directory).expect("create durable test directory");
        fs::set_permissions(&directory, fs::Permissions::from_mode(0o700))
            .expect("protect durable test directory");
        let socket = directory.join("broker.sock");
        let registry = directory.join("registry.json");
        let codex = fixture_command(codex_fixture);
        let claude = fixture_command("fake_m1_claude_worker.py");
        let broker = EmbeddedConfig::default()
            .with_provider_commands(
                CommandSpec {
                    program: "python".to_owned(),
                    args: vec![codex.to_string_lossy().into_owned()],
                },
                WorkerCommandSpec {
                    program: "python".to_owned(),
                    args: vec![claude.to_string_lossy().into_owned()],
                },
            )
            .with_replay_capacity(replay_capacity);
        let (shutdown_tx, shutdown_rx) = oneshot::channel();
        let task = tokio::spawn(serve_until(
            DurableConfig::new(socket.clone(), registry.clone()).with_broker_config(broker),
            async {
                let _ = shutdown_rx.await;
            },
        ));
        timeout(IO_TIMEOUT, async {
            while !socket.exists() {
                tokio::task::yield_now().await;
            }
        })
        .await
        .expect("durable socket creation timed out");
        Self {
            directory,
            socket,
            registry,
            shutdown: Some(shutdown_tx),
            task,
        }
    }

    async fn connect(&self, last_sequence: u64) -> Client {
        let stream = UnixStream::connect(&self.socket)
            .await
            .expect("connect durable broker");
        let (reader, writer) = stream.into_split();
        let mut client = Client {
            reader: BufReader::new(reader),
            writer,
            inbox: VecDeque::new(),
        };
        client
            .send(request(
                1,
                "initialize",
                json!({
                    "protocol_version": 1,
                    "client": { "name": "durable-test", "version": "0.1.0" },
                    "last_sequence": last_sequence,
                }),
            ))
            .await;
        client
    }

    async fn shutdown(mut self) {
        self.shutdown
            .take()
            .expect("shutdown sender")
            .send(())
            .expect("signal durable shutdown");
        timeout(IO_TIMEOUT, self.task)
            .await
            .expect("durable shutdown timed out")
            .expect("durable task panicked")
            .expect("durable broker failed");
        assert!(!self.socket.exists(), "socket must be removed on shutdown");
        fs::remove_dir_all(self.directory).expect("remove durable test directory");
    }
}

struct Client {
    reader: BufReader<OwnedReadHalf>,
    writer: OwnedWriteHalf,
    inbox: VecDeque<Value>,
}

impl Client {
    async fn send(&mut self, message: Value) {
        let mut encoded = serde_json::to_vec(&message).expect("encode client message");
        encoded.push(b'\n');
        self.writer
            .write_all(&encoded)
            .await
            .expect("write client message");
        self.writer.flush().await.expect("flush client message");
    }

    async fn receive_wire(&mut self) -> Value {
        let mut line = String::new();
        let bytes = timeout(IO_TIMEOUT, self.reader.read_line(&mut line))
            .await
            .expect("broker response timed out")
            .expect("read broker response");
        assert_ne!(bytes, 0, "durable broker closed the connection");
        serde_json::from_str(&line).expect("broker response JSON")
    }

    async fn wait_for(&mut self, predicate: impl Fn(&Value) -> bool) -> Value {
        if let Some(index) = self.inbox.iter().position(&predicate) {
            return self.inbox.remove(index).expect("queued message");
        }
        loop {
            let message = self.receive_wire().await;
            if predicate(&message) {
                return message;
            }
            self.inbox.push_back(message);
        }
    }

    async fn response(&mut self, id: i64) -> Value {
        self.wait_for(|message| message.get("id").and_then(Value::as_i64) == Some(id))
            .await
    }

    async fn event(&mut self, event_type: &str) -> Value {
        self.wait_for(|message| {
            message["method"] == "agent/event" && message["params"]["type"] == event_type
        })
        .await
    }

    async fn state_for(&mut self, agent_id: &str, state: &str) -> Value {
        self.wait_for(|message| {
            message["method"] == "broker/state"
                && message["params"]["agents"]
                    .as_array()
                    .is_some_and(|agents| {
                        agents
                            .iter()
                            .any(|agent| agent["id"] == agent_id && agent["state"] == state)
                    })
        })
        .await
    }

    async fn initialize(&mut self) -> Value {
        let response = self.response(1).await;
        assert_eq!(response["result"]["mode"], "durable");
        self.send(json!({ "jsonrpc": "2.0", "method": "initialized", "params": {} }))
            .await;
        response
    }
}

fn fixture_command(name: &str) -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .join("tests")
        .join("fixtures")
        .join(name)
}

fn linked_worktree(parent: &Path, name: &str) -> PathBuf {
    let source = parent.join(format!("{name}-source"));
    let worktree = parent.join(format!("{name}-worktree"));
    run_git(parent, &["init", source.to_str().expect("source path")]);
    fs::write(source.join("Cargo.toml"), "[workspace]\n").expect("write Git fixture");
    run_git(&source, &["add", "Cargo.toml"]);
    run_git(
        &source,
        &[
            "-c",
            "user.name=Agent Manager Test",
            "-c",
            "user.email=agent-manager@example.invalid",
            "commit",
            "-m",
            "fixture",
        ],
    );
    run_git(
        &source,
        &[
            "worktree",
            "add",
            "-b",
            &format!("{name}-branch"),
            worktree.to_str().expect("worktree path"),
        ],
    );
    worktree
        .canonicalize()
        .expect("canonical linked worktree fixture")
}

fn run_git(cwd: &Path, args: &[&str]) {
    let output = Command::new("git")
        .args(args)
        .current_dir(cwd)
        .output()
        .expect("run Git fixture command");
    assert!(
        output.status.success(),
        "Git fixture command failed: {}",
        String::from_utf8_lossy(&output.stderr)
    );
}

fn request(id: i64, method: &str, params: impl serde::Serialize) -> Value {
    json!({ "jsonrpc": "2.0", "id": id, "method": method, "params": params })
}

async fn start_shared_agent(client: &mut Client, id: i64, provider: &str, cwd: &Path) -> Value {
    client
        .send(request(
            id,
            "agent/start",
            json!({ "provider": provider, "cwd": cwd, "workspace_strategy": "shared" }),
        ))
        .await;
    client.response(id).await
}

async fn start_worktree_agent(
    client: &mut Client,
    id: i64,
    provider: &str,
    worktree: &Path,
) -> Value {
    client
        .send(request(
            id,
            "agent/start",
            json!({
                "provider": provider,
                "cwd": worktree,
                "workspace_strategy": "worktree",
                "worktree_path": worktree,
            }),
        ))
        .await;
    client.response(id).await
}

async fn add_context(client: &mut Client, id: i64, agent_id: &str, path: &Path) {
    client
        .send(request(
            id,
            "agent/context/add",
            json!({
                "agent_id": agent_id,
                "context": {
                    "kind": "buffer",
                    "payload": { "path": path, "text": "fixture context" }
                }
            }),
        ))
        .await;
    assert_eq!(client.response(id).await["result"]["queued"], true);
}

async fn agent_count(client: &mut Client, id: i64) -> usize {
    client.send(request(id, "agent/list", json!({}))).await;
    client.response(id).await["result"]["agents"]
        .as_array()
        .expect("agent list")
        .len()
}

#[tokio::test]
async fn durable_mode_runs_multiple_agents_and_enforces_writer_ownership() {
    let server = DurableServer::start(2_000).await;
    let shared_one = server.directory.join("shared-one");
    let shared_two = server.directory.join("shared-two");
    fs::create_dir(&shared_one).expect("create first shared checkout");
    fs::create_dir(&shared_two).expect("create second shared checkout");
    let context_path = shared_one.join("context.txt");
    fs::write(&context_path, "fixture").expect("write context fixture");

    let mut client = server.connect(0).await;
    let initialized = client.initialize().await;
    assert_eq!(initialized["result"]["replay"]["resync_required"], false);
    client
        .wait_for(|message| message["method"] == "broker/state")
        .await;

    let first = start_shared_agent(&mut client, 2, "codex", &shared_one).await;
    let first_id = first["result"]["agent"]["id"]
        .as_str()
        .expect("first agent id")
        .to_owned();
    client.state_for(&first_id, "idle").await;

    let second = start_shared_agent(&mut client, 3, "claude", &shared_two).await;
    let second_id = second["result"]["agent"]["id"]
        .as_str()
        .expect("second agent id")
        .to_owned();
    client.state_for(&second_id, "idle").await;

    let conflict = start_shared_agent(&mut client, 4, "codex", &shared_one).await;
    assert_eq!(conflict["error"]["code"], -32_012);
    assert_eq!(
        conflict["error"]["data"]["reason"],
        "shared_checkout_writer_conflict"
    );

    let worktree = linked_worktree(&server.directory, "multi-agent");
    fs::create_dir(worktree.join("nested")).expect("create worktree subdirectory");
    let worktree_agent = start_worktree_agent(&mut client, 5, "codex", &worktree).await;
    assert!(worktree_agent["result"]["agent"]["id"].is_string());

    let nested = worktree.join("nested");
    assert_eq!(
        start_shared_agent(&mut client, 6, "claude", &nested).await["error"]["code"],
        -32_012
    );

    add_context(&mut client, 7, &first_id, &context_path).await;
    client
        .send(request(
            8,
            "agent/prompt",
            json!({
                "agent_id": first_id,
                "input": { "text": "serialized input", "attachments": [] }
            }),
        ))
        .await;
    assert_eq!(client.response(8).await["result"]["accepted"], true);
    client
        .send(request(
            9,
            "agent/prompt",
            json!({
                "agent_id": first_id,
                "input": { "text": "must not overlap", "attachments": [] }
            }),
        ))
        .await;
    assert_eq!(client.response(9).await["error"]["code"], -32_013);
    let approval = client.event("approval.requested").await;
    client
        .send(request(
            10,
            "agent/approval/respond",
            json!({
                "agent_id": first_id,
                "approval_id": approval["params"]["payload"]["id"],
                "decision": "deny",
            }),
        ))
        .await;
    assert_eq!(client.response(10).await["result"]["resolved"], true);
    client.event("turn.completed").await;

    assert_eq!(agent_count(&mut client, 11).await, 3);
    client
        .send(request(
            12,
            "agent/archive",
            json!({ "agent_id": first_id }),
        ))
        .await;
    assert_eq!(client.response(12).await["result"]["archived"], true);
    assert_eq!(agent_count(&mut client, 13).await, 2);
    drop(client);
    server.shutdown().await;
}

#[tokio::test]
async fn durable_worktree_strategy_requires_a_real_linked_worktree() {
    let server = DurableServer::start(2_000).await;
    let linked = linked_worktree(&server.directory, "validation");
    let main_checkout = server.directory.join("validation-source");
    let forged = server.directory.join("forged-worktree");
    fs::create_dir(&forged).expect("create forged worktree");
    fs::write(forged.join(".git"), "gitdir: /tmp/not-a-real-worktree\n")
        .expect("write forged Git marker");

    let mut client = server.connect(0).await;
    client.initialize().await;
    client
        .wait_for(|message| message["method"] == "broker/state")
        .await;
    assert_eq!(
        start_worktree_agent(&mut client, 2, "codex", &main_checkout).await["error"]["code"],
        -32_602
    );
    assert_eq!(
        start_worktree_agent(&mut client, 3, "codex", &forged).await["error"]["code"],
        -32_602
    );
    assert!(
        start_worktree_agent(&mut client, 4, "codex", &linked).await["result"]["agent"]["id"]
            .is_string()
    );
    drop(client);
    server.shutdown().await;
}

#[tokio::test]
async fn durable_reconnect_reports_bounded_resync_without_persisting_transcripts() {
    let server = DurableServer::start(2).await;
    let root = linked_worktree(&server.directory, "reconnect");
    let mut client = server.connect(0).await;
    client.initialize().await;
    client
        .wait_for(|message| message["method"] == "broker/state")
        .await;
    client
        .send(request(
            2,
            "agent/start",
            json!({
                "provider": "codex",
                "cwd": root,
                "workspace_strategy": "worktree",
                "worktree_path": root,
            }),
        ))
        .await;
    let started = client.response(2).await;
    let agent_id = started["result"]["agent"]["id"]
        .as_str()
        .expect("agent id")
        .to_owned();
    client.state_for(&agent_id, "idle").await;
    add_context(&mut client, 3, &agent_id, &root.join("Cargo.toml")).await;
    client
        .send(request(
            4,
            "agent/prompt",
            json!({
                "agent_id": agent_id,
                "input": { "text": "registry-secret-sentinel", "attachments": [] }
            }),
        ))
        .await;
    assert_eq!(client.response(4).await["result"]["accepted"], true);
    let approval = client.event("approval.requested").await;
    client
        .send(request(
            5,
            "agent/approval/respond",
            json!({
                "agent_id": agent_id,
                "approval_id": approval["params"]["payload"]["id"],
                "decision": "allow",
            }),
        ))
        .await;
    assert_eq!(client.response(5).await["result"]["resolved"], true);
    let question = client.event("question.requested").await;
    client
        .send(request(
            6,
            "agent/question/respond",
            json!({
                "agent_id": agent_id,
                "question_id": question["params"]["payload"]["id"],
                "decision": "answer",
                "answers": { "mode": "Safe", "Which mode?": "Safe" },
            }),
        ))
        .await;
    assert_eq!(client.response(6).await["result"]["resolved"], true);
    let completed = client.event("turn.completed").await;
    let latest = completed["params"]["sequence"]
        .as_u64()
        .expect("terminal sequence");
    assert!(latest > 2);
    drop(client);

    let mut reconnected = server.connect(0).await;
    let initialized = reconnected.initialize().await;
    assert_eq!(initialized["result"]["replay"]["resync_required"], true);
    assert_eq!(initialized["result"]["replay"]["latest"], latest);
    let state = reconnected
        .wait_for(|message| message["method"] == "broker/state")
        .await;
    assert_eq!(state["params"]["agents"][0]["id"], agent_id);
    let registry = fs::read_to_string(&server.registry).expect("read durable registry");
    assert!(!registry.contains("registry-secret-sentinel"));
    assert!(!registry.contains("first answer"));
    assert!(!registry.contains("printf fixture"));
    assert!(registry.contains(&agent_id));
    let status: Value = serde_json::from_str(
        &fs::read_to_string(server.directory.join("status.json")).expect("read durable status"),
    )
    .expect("durable status JSON");
    assert_eq!(status["state"], "running");
    assert!(status["last_success_at"].is_string());
    assert!(status.get("last_failure_at").is_some());
    assert!(status.get("last_error").is_some());
    assert_eq!(status["object_count"], 1);
    assert!(status["byte_count"].as_u64().is_some_and(|bytes| bytes > 0));
    drop(reconnected);
    server.shutdown().await;
}

#[tokio::test]
async fn editor_disconnect_denies_pending_human_requests_before_replay() {
    let server = DurableServer::start(2_000).await;
    let workspace = server.directory.join("disconnect-workspace");
    fs::create_dir(&workspace).expect("create disconnect workspace");
    let context_path = workspace.join("context.txt");
    fs::write(&context_path, "fixture").expect("write disconnect context");
    let mut client = server.connect(0).await;
    client.initialize().await;
    client
        .wait_for(|message| message["method"] == "broker/state")
        .await;
    let started = start_shared_agent(&mut client, 2, "codex", &workspace).await;
    let agent_id = started["result"]["agent"]["id"]
        .as_str()
        .expect("disconnect agent ID")
        .to_owned();
    client.state_for(&agent_id, "idle").await;
    add_context(&mut client, 3, &agent_id, &context_path).await;
    client
        .send(request(
            4,
            "agent/prompt",
            json!({
                "agent_id": agent_id,
                "input": { "text": "disconnect callback", "attachments": [] }
            }),
        ))
        .await;
    assert_eq!(client.response(4).await["result"]["accepted"], true);
    let approval = client.event("approval.requested").await;
    let approval_sequence = approval["params"]["sequence"]
        .as_u64()
        .expect("approval sequence");
    drop(client);

    let mut reconnected = server.connect(approval_sequence).await;
    reconnected.initialize().await;
    let resolution = reconnected.event("approval.resolved").await;
    assert_eq!(resolution["params"]["payload"]["decision"], "deny");
    assert_eq!(
        resolution["params"]["payload"]["reason"],
        "client_disconnect"
    );
    reconnected.event("turn.completed").await;
    drop(reconnected);
    server.shutdown().await;
}

#[tokio::test]
async fn stale_runtime_response_cannot_match_a_reconnected_clients_request_id() {
    let server = DurableServer::start_with_codex(2_000, "fake_delayed_codex_app_server.py").await;
    let workspace = server.directory.join("delayed-workspace");
    fs::create_dir(&workspace).expect("create delayed workspace");
    let mut original = server.connect(0).await;
    original.initialize().await;
    original
        .wait_for(|message| message["method"] == "broker/state")
        .await;
    original
        .send(request(
            2,
            "agent/start",
            json!({
                "provider": "codex",
                "cwd": workspace,
                "workspace_strategy": "shared",
            }),
        ))
        .await;
    drop(original);

    let mut reconnected = server.connect(0).await;
    reconnected.initialize().await;
    reconnected
        .wait_for(|message| message["method"] == "broker/state")
        .await;
    reconnected.send(request(2, "agent/list", json!({}))).await;
    let response = reconnected.response(2).await;
    assert!(response["result"]["agents"].is_array());
    assert!(response["result"].get("agent").is_none());

    tokio::time::sleep(Duration::from_millis(300)).await;
    reconnected.send(request(3, "agent/list", json!({}))).await;
    reconnected.response(3).await;
    assert!(
        !reconnected
            .inbox
            .iter()
            .any(|message| { message["id"] == 2 && message["result"].get("agent").is_some() }),
        "the delayed response from the old connection must be discarded"
    );
    drop(reconnected);
    server.shutdown().await;
}
