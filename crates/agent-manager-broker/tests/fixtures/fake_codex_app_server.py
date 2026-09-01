#!/usr/bin/env python3
"""Deterministic Codex App Server transcript used by Rust integration tests."""

from __future__ import annotations

import json
import sys
from typing import Any


def read() -> dict[str, Any]:
    line = sys.stdin.readline()
    if not line:
        raise EOFError("client closed input")
    value = json.loads(line)
    if not isinstance(value, dict):
        raise TypeError("expected object frame")
    return value


def send(value: dict[str, Any]) -> None:
    sys.stdout.write(json.dumps(value, separators=(",", ":")) + "\n")
    sys.stdout.flush()


def expect(method: str) -> dict[str, Any]:
    message = read()
    if message.get("method") != method:
        raise AssertionError(f"expected {method}, got {message.get('method')}")
    return message


def respond(message: dict[str, Any], result: dict[str, Any]) -> None:
    send({"id": message["id"], "result": result})


def main() -> None:
    initialize = expect("initialize")
    respond(
        initialize,
        {
            "userAgent": "codex_cli_rs/0.151.0",
            "platformFamily": "unix",
            "platformOs": "linux",
            "codexHome": "/tmp/fake-codex-home",
        },
    )
    expect("initialized")

    message = read()
    if message.get("method") == "thread/list":
        respond(message, {"data": [], "nextCursor": None})
        message = read()

    if message.get("method") != "thread/start":
        raise AssertionError("expected thread/start")
    send({"method": "thread/started", "params": {"thread": {"id": "thread-1"}}})
    respond(message, {"thread": {"id": "thread-1"}})

    turn = expect("turn/start")
    respond(turn, {"turn": {"id": "turn-1", "status": "inProgress"}})
    send(
        {
            "method": "turn/started",
            "params": {"threadId": "thread-1", "turn": {"id": "turn-1"}},
        }
    )
    send(
        {
            "id": "approval-1",
            "method": "item/commandExecution/requestApproval",
            "params": {
                "threadId": "thread-1",
                "turnId": "turn-1",
                "itemId": "item-1",
                "command": "echo safe",
                "cwd": "/tmp",
            },
        }
    )
    approval = read()
    if approval.get("result", {}).get("decision") != "decline":
        raise AssertionError("client did not fail closed")
    send(
        {
            "method": "item/agentMessage/delta",
            "params": {
                "threadId": "thread-1",
                "turnId": "turn-1",
                "itemId": "message-1",
                "delta": "done",
            },
        }
    )
    send(
        {
            "method": "turn/completed",
            "params": {
                "threadId": "thread-1",
                "turn": {"id": "turn-1", "status": "completed"},
            },
        }
    )


if __name__ == "__main__":
    main()
