use std::path::PathBuf;

use agent_manager_broker::protocol::RequestId;
use agent_manager_broker::worker::{ClaudeWorker, WorkerCommandSpec};
use serde_json::json;

fn fake_command() -> WorkerCommandSpec {
    let script =
        PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("tests/fixtures/fake_claude_worker.py");
    WorkerCommandSpec {
        program: "python".to_owned(),
        args: vec![script.to_string_lossy().into_owned()],
    }
}

#[tokio::test]
async fn proves_worker_initialize_event_and_callback_flow() {
    let mut worker = ClaudeWorker::spawn(&fake_command()).expect("spawn fake worker");
    let initialized = worker.initialize().await.expect("initialize worker");
    assert_eq!(initialized["protocol_version"], 1);

    let started = worker
        .request(
            "session/start",
            json!({ "agent_id": "agent-1", "cwd": "/tmp" }),
        )
        .await
        .expect("start session");
    assert_eq!(started.result["provider_session_id"], "session-1");

    let prompt = worker
        .request(
            "turn/prompt",
            json!({ "agent_id": "agent-1", "text": "hello" }),
        )
        .await
        .expect("prompt");
    assert_eq!(prompt.result["accepted"], true);

    let event = worker.next_inbound().await.expect("session event");
    assert_eq!(event.method, "session/event");
    assert!(!event.is_callback());

    let callback = worker.next_inbound().await.expect("approval callback");
    assert_eq!(callback.method, "approval/request");
    let callback_id = callback.id.expect("callback id");
    assert!(matches!(callback_id, RequestId::String(_)));
    worker
        .deny_callback(&callback_id, "denied by deterministic test")
        .await
        .expect("deny callback");

    worker.shutdown().await.expect("shutdown worker");
}
