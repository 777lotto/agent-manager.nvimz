#!/usr/bin/env python3
"""Deterministic public broker used by headless Neovim tests."""

from __future__ import annotations

import json
import sys
from typing import Any


def read() -> dict[str, Any]:
    line = sys.stdin.readline()
    if not line:
        raise EOFError("Neovim closed input")
    value = json.loads(line)
    if not isinstance(value, dict) or value.get("jsonrpc") != "2.0":
        raise TypeError("expected a JSON-RPC object")
    if "method" in value and not isinstance(value.get("params"), dict):
        raise TypeError("request params must be an object")
    return value


def send(value: dict[str, Any]) -> None:
    sys.stdout.write(json.dumps(value, separators=(",", ":")) + "\n")
    sys.stdout.flush()


def respond(request: dict[str, Any], result: dict[str, Any]) -> None:
    send({"jsonrpc": "2.0", "id": request["id"], "result": result})


def agent(state: str, turn_id: str | None = None) -> dict[str, Any]:
    return {
        "id": "agent-lua-1",
        "provider": "codex",
        "provider_session_id": "thread-lua-1",
        "cwd": "/tmp",
        "workspace_strategy": "shared",
        "worktree_path": None,
        "title": "lua fixture",
        "state": state,
        "active_turn_id": turn_id,
        "pending_approvals": 0,
        "unread_events": 0,
        "capabilities": [
            {"name": "streaming", "available": True, "reason": None},
            {"name": "multi_turn", "available": True, "reason": None},
            {"name": "interrupt", "available": True, "reason": None},
            {"name": "steer", "available": True, "reason": None},
        ],
        "created_at": "2026-09-01T00:00:00Z",
        "updated_at": "2026-09-01T00:00:00Z",
    }


def state(value: str, turn_id: str | None = None) -> None:
    send(
        {
            "jsonrpc": "2.0",
            "method": "broker/state",
            "params": {"agents": [agent(value, turn_id)]},
        }
    )


class Events:
    def __init__(self) -> None:
        self.sequence = 0

    def send(self, event_type: str, payload: dict[str, Any]) -> None:
        self.sequence += 1
        send(
            {
                "jsonrpc": "2.0",
                "method": "agent/event",
                "params": {
                    "protocol_version": 1,
                    "sequence": self.sequence,
                    "timestamp": "2026-09-01T00:00:00Z",
                    "agent_id": "agent-lua-1",
                    "provider": "codex",
                    "type": event_type,
                    "payload": payload,
                    "provider_event": {"kind": "fixture"},
                },
            }
        )


def main() -> None:
    initialize = read()
    if initialize.get("method") != "initialize":
        raise AssertionError("expected initialize")
    respond(
        initialize,
        {
            "protocol_version": 1,
            "broker_version": "0.1.0",
            "mode": "embedded",
            "providers": {
                "codex": {"app_server_version": "0.152.0"},
                "claude": {
                    "agent_sdk_version": "0.2.148",
                    "claude_code_version": "2.1.251",
                },
            },
            "replay": {"capacity": 2000},
        },
    )
    initialized = read()
    if initialized.get("method") != "initialized":
        raise AssertionError("expected initialized")
    send({"jsonrpc": "2.0", "method": "broker/state", "params": {"agents": []}})

    events = Events()
    started = False
    prompt_number = 0
    while True:
        request = read()
        method = request.get("method")
        if method == "agent/list":
            respond(request, {"agents": [agent("completed")] if started else []})
        elif method == "agent/start":
            started = True
            state("starting")
            respond(request, {"agent": agent("idle")})
            state("idle")
        elif method == "agent/prompt":
            prompt_number += 1
            turn_id = f"turn-lua-{prompt_number}"
            respond(request, {"accepted": True, "turn_id": turn_id})
            state("running", turn_id)
            events.send("turn.started", {"turn": {"id": turn_id}})
            if prompt_number == 1:
                events.send(
                    "tool.started",
                    {"item": {"id": "tool-lua-1", "type": "commandExecution", "command": "fixture"}},
                )
                events.send("message.delta", {"delta": "hello"})
                events.send("message.delta", {"delta": " world"})
                events.send("turn.completed", {"turn": {"id": turn_id, "status": "completed"}})
                state("completed")
        elif method == "agent/steer":
            respond(request, {"accepted": True})
            events.send("message.delta", {"delta": " steered"})
        elif method == "agent/interrupt":
            respond(request, {"interrupted": True})
            events.send(
                "turn.completed",
                {"turn": {"id": "turn-lua-2", "status": "interrupted"}},
            )
            state("interrupted")
        elif method == "broker/shutdown":
            respond(request, {"shutdown": True})
            return
        else:
            send(
                {
                    "jsonrpc": "2.0",
                    "id": request.get("id"),
                    "error": {"code": -32601, "message": "Method not found"},
                }
            )


if __name__ == "__main__":
    main()
