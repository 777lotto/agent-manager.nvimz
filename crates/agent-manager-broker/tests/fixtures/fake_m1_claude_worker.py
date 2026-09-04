#!/usr/bin/env python3
"""Deterministic M2 Claude transcript for the embedded broker."""

from __future__ import annotations

import json
import sys
from typing import Any


def read() -> dict[str, Any]:
    line = sys.stdin.readline()
    if not line:
        raise EOFError("broker closed input")
    value = json.loads(line)
    if not isinstance(value, dict) or value.get("jsonrpc") != "2.0":
        raise TypeError("expected JSON-RPC object frame")
    return value


def send(value: dict[str, Any]) -> None:
    sys.stdout.write(json.dumps(value, separators=(",", ":")) + "\n")
    sys.stdout.flush()


def respond(request: dict[str, Any], result: dict[str, Any]) -> None:
    send({"jsonrpc": "2.0", "id": request["id"], "result": result})


def session_event(agent_id: str, event_type: str, payload: dict[str, Any]) -> None:
    send(
        {
            "jsonrpc": "2.0",
            "method": "session/event",
            "params": {
                "agent_id": agent_id,
                "provider_session_id": "session-m1",
                "worker_sequence": 1,
                "event_type": event_type,
                "payload": payload,
            },
        }
    )


def complete(agent_id: str, subtype: str = "success") -> None:
    session_event(agent_id, "result", {"is_error": False, "subtype": subtype})


def main() -> None:
    initialize = read()
    if initialize.get("method") != "worker/initialize":
        raise AssertionError("expected worker/initialize")
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

    opening = read()
    if opening.get("method") == "session/list":
        respond(
            opening,
            {
                "sessions": [
                    {
                        "session_id": "session-resumable",
                        "cwd": opening.get("params", {}).get("directory") or "/tmp",
                        "summary": "Resumable Claude session",
                        "last_modified": 1,
                        "active": True,
                    }
                ],
                "activity_available": True,
            },
        )
        shutdown = read()
        if shutdown.get("method") == "worker/shutdown":
            respond(shutdown, {"shutdown": True})
        return
    if opening.get("method") == "session/delete":
        if opening.get("params", {}).get("session_id") != "session-resumable":
            raise AssertionError("broker deleted the wrong Claude session")
        respond(opening, {"deleted": True, "provider_session_id": "session-resumable"})
        shutdown = read()
        if shutdown.get("method") == "worker/shutdown":
            respond(shutdown, {"shutdown": True})
        return
    if opening.get("method") not in {"session/start", "session/resume", "session/fork"}:
        raise AssertionError("expected session open")
    agent_id = opening["params"]["agent_id"]
    source_session = opening.get("params", {}).get("session_id")
    if opening["method"] == "session/resume":
        session_id = source_session
    elif opening["method"] == "session/fork":
        session_id = f"{source_session}-fork"
    else:
        session_id = "session-m1"
    respond(
        opening,
        {
            "agent_id": agent_id,
            "provider_session_id": session_id,
            "cwd": opening["params"]["cwd"],
            "forked": opening["method"] == "session/fork",
        },
    )

    turn_number = 0
    while True:
        request = read()
        method = request.get("method")
        if method == "turn/prompt":
            turn_number += 1
            if turn_number == 1 and "<agent-manager-context" not in request["params"]["text"]:
                raise AssertionError("explicit editor context was not forwarded")
            respond(request, {"accepted": True})
            if turn_number == 1:
                session_event(agent_id, "task.started", {"tool": "Read", "status": "running"})
                session_event(agent_id, "task.progress", {"delta": "fixture activity"})
                send(
                    {
                        "jsonrpc": "2.0",
                        "id": "worker:approval-m1",
                        "method": "approval/request",
                        "params": {
                            "callback_id": "approval-m1",
                            "agent_id": agent_id,
                            "provider_session_id": session_id,
                            "tool_name": "Bash",
                            "input": {"command": "printf fixture"},
                            "context": {},
                        },
                    }
                )
                approval = read()
                approval_result = approval.get("result", {})
                approval_decision = approval_result.get("decision")
                if approval_decision == "deny":
                    complete(agent_id, "interrupted")
                    continue
                if approval_decision != "allow":
                    raise AssertionError("broker did not forward interactive approval")
                if "updated_input" in approval_result and not isinstance(
                    approval_result["updated_input"], dict
                ):
                    raise AssertionError("absent Claude input override must be omitted")
                send(
                    {
                        "jsonrpc": "2.0",
                        "id": "worker:question-m2",
                        "method": "question/request",
                        "params": {
                            "callback_id": "question-m2",
                            "agent_id": agent_id,
                            "provider_session_id": session_id,
                            "tool_name": "AskUserQuestion",
                            "input": {
                                "questions": [
                                    {
                                        "question": "Which mode?",
                                        "header": "Mode",
                                        "options": [
                                            {"label": "Safe", "description": "Use safe mode"},
                                            {"label": "Fast", "description": "Use fast mode"},
                                        ],
                                        "multiSelect": False,
                                    }
                                ]
                            },
                            "context": {},
                        },
                    }
                )
                answer = read()
                if answer.get("result", {}).get("decision") != "answer" or answer.get(
                    "result", {}
                ).get("answers", {}).get("Which mode?") != "Safe":
                    raise AssertionError("broker did not preserve structured question answers")
                session_event(
                    agent_id,
                    "rate_limit",
                    {"input_tokens": 12, "output_tokens": 7, "total_tokens": 19},
                )
                session_event(
                    agent_id,
                    "file.changed",
                    {"path": "/tmp/agent-manager-m2-file.txt", "kind": "modified"},
                )
                session_event(agent_id, "stream.event", {"delta": "first answer"})
                complete(agent_id)
            elif turn_number == 2:
                session_event(agent_id, "stream.event", {"delta": "follow-up answer"})
                complete(agent_id)
            elif turn_number != 3:
                raise AssertionError("unexpected extra turn")
        elif method == "turn/steer":
            session_event(agent_id, "stream.event", {"delta": "steering accepted"})
            respond(request, {"accepted": True})
        elif method == "turn/interrupt":
            complete(agent_id, "interrupted")
            respond(request, {"interrupted": True})
        elif method == "session/history":
            respond(
                request,
                {
                    "messages": [
                        {"id": "history-user", "role": "user", "content": "historic question"},
                        {
                            "id": "history-assistant",
                            "role": "assistant",
                            "content": "historic answer",
                        },
                    ]
                },
            )
        elif method == "worker/shutdown":
            respond(request, {"shutdown": True})
            return
        else:
            raise AssertionError(f"unexpected method {method}")


if __name__ == "__main__":
    main()
