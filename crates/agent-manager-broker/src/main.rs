use std::env;
use std::io;
use std::path::{Path, PathBuf};

use agent_manager_broker::codex::{
    CodexAppServer, CommandSpec, PINNED_CODEX_VERSION, normalize_event, thread_id,
};
use agent_manager_broker::embedded::{self, EmbeddedConfig};
use agent_manager_broker::protocol::PROTOCOL_VERSION;
use agent_manager_broker::worker::{
    PINNED_CLAUDE_CODE_VERSION, PINNED_CLAUDE_SDK_VERSION, WORKER_PROTOCOL_VERSION,
};
use agent_manager_broker::{BROKER_VERSION, codex};
use serde_json::{Value, json};
use tokio::io::BufReader;

const LIVE_CONFIRMATION: &str = "--allow-live-provider";

#[tokio::main]
async fn main() {
    if let Err(error) = run().await {
        eprintln!("agent-manager-broker: {error}");
        std::process::exit(1);
    }
}

async fn run() -> Result<(), Box<dyn std::error::Error>> {
    let args: Vec<String> = env::args().skip(1).collect();
    match args.first().map(String::as_str) {
        None | Some("help" | "--help" | "-h") => {
            print_help();
            Ok(())
        }
        Some("contract-info") => {
            println!(
                "{}",
                serde_json::to_string_pretty(&json!({
                    "broker_version": BROKER_VERSION,
                    "broker_protocol_version": PROTOCOL_VERSION,
                    "codex_app_server_version": PINNED_CODEX_VERSION,
                    "claude_worker_protocol_version": WORKER_PROTOCOL_VERSION,
                    "claude_agent_sdk_version": PINNED_CLAUDE_SDK_VERSION,
                    "claude_code_version": PINNED_CLAUDE_CODE_VERSION
                }))?
            );
            Ok(())
        }
        Some("serve") => serve_embedded(&args[1..]).await,
        Some("codex-probe") => probe_codex(parse_cwd(&args[1..])?).await,
        Some("codex-trace") => trace_codex(&args[1..]).await,
        Some(command) => Err(invalid_input(format!("unknown command: {command}")).into()),
    }
}

async fn serve_embedded(args: &[String]) -> Result<(), Box<dyn std::error::Error>> {
    let mut config = EmbeddedConfig::default();
    let mut index = 0;
    while index < args.len() {
        match args[index].as_str() {
            "--claude-python" => {
                let python = args
                    .get(index + 1)
                    .ok_or_else(|| invalid_input("--claude-python requires an absolute path"))?;
                if !Path::new(python).is_absolute() {
                    return Err(invalid_input("--claude-python requires an absolute path").into());
                }
                config = config.with_claude_python(python);
                index += 2;
            }
            option => {
                return Err(invalid_input(format!("unknown serve option: {option}")).into());
            }
        }
    }
    embedded::serve(
        BufReader::new(tokio::io::stdin()),
        tokio::io::stdout(),
        config,
    )
    .await?;
    Ok(())
}

async fn probe_codex(cwd: PathBuf) -> Result<(), Box<dyn std::error::Error>> {
    ensure_directory(&cwd)?;
    let mut server = CodexAppServer::spawn(&CommandSpec::default())?;
    let initialize = server.initialize().await?;
    let threads = server.list_threads(1).await?;
    println!(
        "{}",
        serde_json::to_string_pretty(&json!({
            "initialized": true,
            "user_agent": initialize.get("userAgent"),
            "platform_family": initialize.get("platformFamily"),
            "platform_os": initialize.get("platformOs"),
            "thread_list_shape": value_shape(&threads.result),
            "events_seen": threads.events.iter().map(|event| &event.method).collect::<Vec<_>>()
        }))?
    );
    server.shutdown().await?;
    Ok(())
}

async fn trace_codex(args: &[String]) -> Result<(), Box<dyn std::error::Error>> {
    if !args.iter().any(|arg| arg == LIVE_CONFIRMATION) {
        return Err(
            invalid_input(format!("codex-trace requires explicit {LIVE_CONFIRMATION}")).into(),
        );
    }
    let cwd = parse_cwd(args)?;
    ensure_directory(&cwd)?;
    let prompt = option_value(args, "--prompt")
        .ok_or_else(|| invalid_input("codex-trace requires --prompt"))?;

    let mut server = CodexAppServer::spawn(&CommandSpec::default())?;
    server.initialize().await?;
    let started = server.start_thread(&cwd).await?;
    let thread_id = thread_id(&started.result)
        .ok_or_else(|| invalid_input("thread/start response omitted thread.id"))?
        .to_owned();
    let turn = server.start_turn(&thread_id, prompt).await?;
    let mut next_sequence = 1;
    for event in started.events.into_iter().chain(turn.events) {
        print_event(&event, &mut next_sequence)?;
    }
    loop {
        let mut event = server.next_event().await?;
        let completed = event.method == "turn/completed";
        if event.response_required {
            server.deny_server_request(&mut event).await?;
        }
        print_event(&event, &mut next_sequence)?;
        if completed {
            break;
        }
    }
    server.shutdown().await?;
    Ok(())
}

fn print_event(
    event: &codex::ProviderEvent,
    next_sequence: &mut u64,
) -> Result<(), Box<dyn std::error::Error>> {
    let mut normalized = normalize_event("m0-probe", event)?;
    normalized.sequence = *next_sequence;
    *next_sequence = next_sequence
        .checked_add(1)
        .ok_or_else(|| io::Error::other("diagnostic sequence overflow"))?;
    println!(
        "{}",
        serde_json::to_string(&json!({
            "sequence": normalized.sequence,
            "timestamp": normalized.timestamp,
            "type": normalized.event_type,
            "provider_method": normalized.provider_event["method"]
        }))?
    );
    Ok(())
}

fn parse_cwd(args: &[String]) -> Result<PathBuf, Box<dyn std::error::Error>> {
    let cwd = option_value(args, "--cwd").ok_or_else(|| invalid_input("command requires --cwd"))?;
    Ok(PathBuf::from(cwd))
}

fn option_value<'a>(args: &'a [String], option: &str) -> Option<&'a str> {
    args.windows(2)
        .find(|window| window[0] == option)
        .map(|window| window[1].as_str())
}

fn ensure_directory(path: &Path) -> Result<(), Box<dyn std::error::Error>> {
    if !path.is_absolute() || !path.is_dir() {
        return Err(invalid_input("cwd must be an existing absolute directory").into());
    }
    Ok(())
}

fn invalid_input(message: impl Into<String>) -> io::Error {
    io::Error::new(io::ErrorKind::InvalidInput, message.into())
}

fn value_shape(value: &Value) -> &'static str {
    match value {
        Value::Null => "null",
        Value::Bool(_) => "boolean",
        Value::Number(_) => "number",
        Value::String(_) => "string",
        Value::Array(_) => "array",
        Value::Object(_) => "object",
    }
}

fn print_help() {
    println!(
        "agent-manager-broker {BROKER_VERSION}\n\
         \n\
         Commands:\n\
           contract-info\n\
           serve [--claude-python ABSOLUTE_PATH]\n\
           codex-probe --cwd ABSOLUTE_PATH\n\
           codex-trace --cwd ABSOLUTE_PATH --prompt TEXT {LIVE_CONFIRMATION}\n\
         \n\
         serve runs the embedded Neovim JSON-RPC broker over stdio.\n\
         codex-probe performs initialization and history discovery only.\n\
         codex-trace invokes the live provider and is never run by verification."
    );
}
