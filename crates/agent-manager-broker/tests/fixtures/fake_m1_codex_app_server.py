#!/usr/bin/env python3
"""Deterministic M2 Codex transcript for the embedded broker."""

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
    approval = read()
    approval_decision = approval.get("result", {}).get("decision")
    if approval_decision == "decline":
        turn_completed(turn_id, "interrupted")
        return
    if approval_decision != "accept":
        raise AssertionError("broker did not forward interactive approval")
    send(
        {
            "id": "question-m2",
            "method": "item/tool/requestUserInput",
            "params": {
                "threadId": "thread-m1",
                "turnId": turn_id,
                "itemId": "question-tool-1",
                "isBlocking": True,
                "questions": [
                    {
                        "id": "mode",
                        "header": "Mode",
                        "question": "Which mode?",
                        "options": [
                            {"label": "Safe", "description": "Use safe mode"},
                            {"label": "Fast", "description": "Use fast mode"},
                        ],
                    }
                ],
            },
        }
    )
    answer = read()
    if answer.get("result", {}).get("answers", {}).get("mode", {}).get("answers") != [
        "Safe"
    ]:
        raise AssertionError("broker did not preserve structured question answers")
    send(
        {
            "method": "thread/tokenUsage/updated",
            "params": {
                "threadId": "thread-m1",
                "tokenUsage": {"inputTokens": 12, "outputTokens": 7, "totalTokens": 19},
            },
        }
    )
    send(
        {
            "method": "fs/changed",
            "params": {"path": "/tmp/agent-manager-m2-file.txt", "kind": "modified"},
        }
    )
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

    opening = read()
    if opening.get("method") == "thread/list":
        respond(
            opening,
            {
                "data": [
                    {
                        "id": "thread-resumable",
                        "cwd": opening.get("params", {}).get("cwd", "/tmp"),
                        "name": "Resumable Codex session",
                        "preview": "must not leave the broker",
                        "updatedAt": 1,
                        "status": {"type": "active"},
                    }
                ],
                "nextCursor": None,
            },
        )
        return
    method = opening.get("method")
    if method == "thread/start":
        thread_id = "thread-m1"
    elif method == "thread/resume":
        thread_id = opening["params"]["threadId"]
    elif method == "thread/fork":
        thread_id = opening["params"]["threadId"] + "-fork"
    else:
        raise AssertionError(f"expected thread open, got {method}")
    send({"method": "thread/started", "params": {"thread": {"id": thread_id}}})
    respond(opening, {"thread": {"id": thread_id, "turns": []}})

    turn_number = 0
    while True:
        request = read()
        method = request.get("method")
        if method == "turn/start":
            turn_number += 1
            turn_id = f"turn-{turn_number}"
            if turn_number == 1 and "<agent-manager-context" not in request["params"]["input"][0]["text"]:
                raise AssertionError("explicit editor context was not forwarded")
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
            active_turn = f"turn-{turn_number}"
            if request.get("params", {}).get("expectedTurnId") != active_turn:
                raise AssertionError("steer did not target the active turn")
            message_delta(active_turn, "steering accepted")
            respond(request, {"turnId": active_turn})
        elif method == "turn/interrupt":
            active_turn = f"turn-{turn_number}"
            if request.get("params", {}).get("turnId") != active_turn:
                raise AssertionError("interrupt did not target the active turn")
            turn_completed(active_turn, "interrupted")
            respond(request, {})
        elif method == "thread/read":
            respond(
                request,
                {
                    "thread": {
                        "id": thread_id,
                        "turns": [
                            {
                                "id": "history-turn",
                                "items": [
                                    {
                                        "id": "history-user",
                                        "type": "userMessage",
                                        "content": [{"text": "historic question"}],
                                    },
                                    {
                                        "id": "history-assistant",
                                        "type": "agentMessage",
                                        "text": "historic answer",
                                    },
                                ],
                            }
                        ],
                    }
                },
            )
        else:
            raise AssertionError(f"unexpected method {method}")


if __name__ == "__main__":
    main()
