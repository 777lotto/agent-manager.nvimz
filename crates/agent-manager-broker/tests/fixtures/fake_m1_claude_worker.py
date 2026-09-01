#!/usr/bin/env python3
"""Deterministic multi-turn Claude transcript for the embedded broker."""

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
                },
            },
            "capabilities": {"callbacks": ["approval", "question"]},
        },
    )

    start = read()
    if start.get("method") != "session/start":
        raise AssertionError("expected session/start")
    agent_id = start["params"]["agent_id"]
    respond(
        start,
        {
            "agent_id": agent_id,
            "provider_session_id": "session-m1",
            "cwd": start["params"]["cwd"],
            "forked": False,
        },
    )

    turn_number = 0
    while True:
        request = read()
        method = request.get("method")
        if method == "turn/prompt":
            turn_number += 1
            respond(request, {"accepted": True})
            if turn_number == 1:
                session_event(agent_id, "task.started", {"tool": "Read", "status": "running"})
                session_event(agent_id, "task.progress", {"delta": "fixture activity"})
                session_event(agent_id, "stream.event", {"delta": "first answer"})
                send(
                    {
                        "jsonrpc": "2.0",
                        "id": "worker:approval-m1",
                        "method": "approval/request",
                        "params": {
                            "callback_id": "approval-m1",
                            "agent_id": agent_id,
                            "provider_session_id": "session-m1",
                            "tool_name": "Bash",
                            "input": {"command": "printf fixture"},
                            "context": {},
                        },
                    }
                )
                denial = read()
                if denial.get("result", {}).get("decision") != "deny":
                    raise AssertionError("broker did not fail closed")
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
        elif method == "worker/shutdown":
            respond(request, {"shutdown": True})
            return
        else:
            raise AssertionError(f"unexpected method {method}")


if __name__ == "__main__":
    main()
