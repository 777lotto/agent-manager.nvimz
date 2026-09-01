#!/usr/bin/env python3
"""Deterministic multi-turn Codex transcript for the embedded broker."""

from __future__ import annotations

import json
import sys
from typing import Any


def read() -> dict[str, Any]:
    line = sys.stdin.readline()
    if not line:
        raise EOFError("broker closed input")
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


def turn_started(turn_id: str) -> None:
    send(
        {
            "method": "turn/started",
            "params": {"threadId": "thread-m1", "turn": {"id": turn_id}},
        }
    )


def message_delta(turn_id: str, text: str) -> None:
    send(
        {
            "method": "item/agentMessage/delta",
            "params": {
                "threadId": "thread-m1",
                "turnId": turn_id,
                "itemId": f"message-{turn_id}",
                "delta": text,
            },
        }
    )


def turn_completed(turn_id: str, status: str = "completed") -> None:
    send(
        {
            "method": "turn/completed",
            "params": {
                "threadId": "thread-m1",
                "turn": {"id": turn_id, "status": status},
            },
        }
    )


def first_turn(turn_id: str) -> None:
    turn_started(turn_id)
    send(
        {
            "method": "item/started",
            "params": {
                "threadId": "thread-m1",
                "turnId": turn_id,
                "item": {
                    "id": "tool-1",
                    "type": "commandExecution",
                    "command": "printf fixture",
                },
            },
        }
    )
    send(
        {
            "method": "item/commandExecution/outputDelta",
            "params": {
                "threadId": "thread-m1",
                "turnId": turn_id,
                "itemId": "tool-1",
                "delta": "fixture",
            },
        }
    )
    send(
        {
            "id": "approval-m1",
            "method": "item/commandExecution/requestApproval",
            "params": {
                "threadId": "thread-m1",
                "turnId": turn_id,
                "itemId": "tool-1",
                "command": "printf fixture",
                "cwd": "/tmp",
            },
        }
    )
    denial = read()
    if denial.get("result", {}).get("decision") != "decline":
        raise AssertionError("broker did not fail closed")
    message_delta(turn_id, "first answer")
    turn_completed(turn_id)


def main() -> None:
    initialize = expect("initialize")
    respond(
        initialize,
        {
            "userAgent": "codex_cli_rs/0.152.0",
            "platformFamily": "unix",
            "platformOs": "linux",
            "codexHome": "/tmp/fake-codex-home",
        },
    )
    expect("initialized")

    start = expect("thread/start")
    send({"method": "thread/started", "params": {"thread": {"id": "thread-m1"}}})
    respond(start, {"thread": {"id": "thread-m1"}})

    turn_number = 0
    while True:
        request = read()
        method = request.get("method")
        if method == "turn/start":
            turn_number += 1
            turn_id = f"turn-{turn_number}"
            respond(request, {"turn": {"id": turn_id, "status": "inProgress"}})
            if turn_number == 1:
                first_turn(turn_id)
            elif turn_number == 2:
                turn_started(turn_id)
                message_delta(turn_id, "follow-up answer")
                turn_completed(turn_id)
            elif turn_number == 3:
                turn_started(turn_id)
            else:
                raise AssertionError("unexpected extra turn")
        elif method == "turn/steer":
            if request.get("params", {}).get("expectedTurnId") != "turn-3":
                raise AssertionError("steer did not target the active turn")
            message_delta("turn-3", "steering accepted")
            respond(request, {"turnId": "turn-3"})
        elif method == "turn/interrupt":
            if request.get("params", {}).get("turnId") != "turn-3":
                raise AssertionError("interrupt did not target the active turn")
            turn_completed("turn-3", "interrupted")
            respond(request, {})
        else:
            raise AssertionError(f"unexpected method {method}")


if __name__ == "__main__":
    main()
