#!/usr/bin/env python3
"""Deterministic private worker transcript used by Rust integration tests."""

from __future__ import annotations

import json
import sys
from typing import Any


def read() -> dict[str, Any]:
    line = sys.stdin.readline()
    if not line:
        raise EOFError("broker closed input")
    message = json.loads(line)
    if message.get("jsonrpc") != "2.0":
        raise AssertionError("missing JSON-RPC version")
    return message


def send(message: dict[str, Any]) -> None:
    sys.stdout.write(json.dumps(message, separators=(",", ":")) + "\n")
    sys.stdout.flush()


def respond(message: dict[str, Any], result: dict[str, Any]) -> None:
    send({"jsonrpc": "2.0", "id": message["id"], "result": result})


def main() -> None:
    initialize = read()
    if initialize.get("method") != "worker/initialize":
        raise AssertionError("expected initialize")
    respond(
        initialize,
        {
            "protocol_version": 1,
            "worker_version": "0.1.0",
            "nonce": initialize["params"]["nonce"],
            "diagnostics": {
                "python_version": "3.13.15",
                "compatibility_profile": "claude-agent-sdk-v1",
                "sdk": {
                    "available": True,
                    "compatible": True,
                    "version": "0.2.148",
                    "pinned_version": "0.2.148",
                },
                "claude_runtime": {
                    "available": True,
                    "compatible": True,
                    "source": "sdk_bundled",
                    "version": "2.1.251",
                    "pinned_version": "2.1.251",
                    "executable": "/fixture/claude",
                },
            },
            "capabilities": {"callbacks": ["approval", "question"]},
        },
    )

    start = read()
    if start.get("method") != "session/start":
        raise AssertionError("expected session/start")
    respond(
        start,
        {
            "agent_id": "agent-1",
            "provider_session_id": "session-1",
            "cwd": "/tmp",
            "forked": False,
        },
    )

    prompt = read()
    if prompt.get("method") != "turn/prompt":
        raise AssertionError("expected turn/prompt")
    respond(prompt, {"accepted": True})
    send(
        {
            "jsonrpc": "2.0",
            "method": "session/event",
            "params": {
                "agent_id": "agent-1",
                "provider_session_id": "session-1",
                "worker_sequence": 1,
                "event_type": "message.assistant",
                "payload": {"sdk_type": "AssistantMessage"},
            },
        }
    )
    send(
        {
            "jsonrpc": "2.0",
            "id": "worker:approval-1",
            "method": "approval/request",
            "params": {
                "callback_id": "approval-1",
                "agent_id": "agent-1",
                "provider_session_id": "session-1",
                "tool_name": "Bash",
                "input": {"command": "cargo test"},
                "context": {},
            },
        }
    )
    denial = read()
    if denial.get("result", {}).get("decision") != "deny":
        raise AssertionError("broker did not deny callback")

    shutdown = read()
    if shutdown.get("method") != "worker/shutdown":
        raise AssertionError("expected shutdown")
    respond(shutdown, {"shutdown": True})


if __name__ == "__main__":
    main()
