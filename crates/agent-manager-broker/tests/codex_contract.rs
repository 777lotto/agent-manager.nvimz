use std::path::PathBuf;

use agent_manager_broker::codex::{
    CodexAppServer, CommandSpec, ProviderEventKind, normalize_event, thread_id,
};

fn fake_command() -> CommandSpec {
    let script =
        PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("tests/fixtures/fake_codex_app_server.py");
    CommandSpec {
        program: "python".to_owned(),
        args: vec![script.to_string_lossy().into_owned()],
    }
}

#[tokio::test]
async fn proves_initialize_history_turn_event_and_approval_flow() {
    let mut server = CodexAppServer::spawn(&fake_command()).expect("spawn fake server");
    let initialized = server.initialize().await.expect("initialize");
    assert_eq!(initialized["platformOs"], "linux");

    let listed = server.list_threads(None, 10).await.expect("list threads");
    assert_eq!(
        listed.result["data"].as_array().expect("data array").len(),
        0
    );

    let cwd = std::env::current_dir().expect("current directory");
    let started = server.start_thread(&cwd).await.expect("start thread");
    assert_eq!(thread_id(&started.result), Some("thread-1"));
    assert_eq!(started.events.len(), 1);
    assert_eq!(started.events[0].method, "thread/started");

    let turn = server
        .start_turn("thread-1", "return a deterministic fixture")
        .await
        .expect("start turn");
    assert_eq!(turn.result["turn"]["id"], "turn-1");

    let mut methods = Vec::new();
    loop {
        let mut event = server.next_event().await.expect("provider event");
        let done = event.method == "turn/completed";
        if event.kind == ProviderEventKind::ServerRequest {
            assert!(event.response_required);
            server
                .deny_server_request(&mut event)
                .await
                .expect("deny server request");
            assert!(!event.response_required);
            let normalized = normalize_event("agent-1", &event).expect("normalize event");
            assert_eq!(normalized.event_type, "approval.requested");
            assert_eq!(normalized.provider_event["request_id"], "approval-1");
        }
        methods.push(event.method);
        if done {
            break;
        }
    }
    assert_eq!(
        methods,
        [
            "turn/started",
            "item/commandExecution/requestApproval",
            "item/agentMessage/delta",
            "turn/completed"
        ]
    );
    server.shutdown().await.expect("shutdown fake server");
}
