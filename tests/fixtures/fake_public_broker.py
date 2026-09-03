#!/usr/bin/env python3
"""Deterministic M2 public broker used by headless Neovim tests."""

from __future__ import annotations

import json
import os
import sys
from pathlib import Path
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


def reject(request: dict[str, Any], message: str) -> None:
    send(
        {
            "jsonrpc": "2.0",
            "id": request["id"],
            "error": {"code": -32602, "message": message},
        }
    )


CAPABILITIES = [
    {"name": "streaming", "available": True, "reason": None},
    {"name": "multi_turn", "available": True, "reason": None},
    {"name": "history", "available": True, "reason": None},
    {"name": "resume", "available": True, "reason": None},
    {"name": "fork", "available": True, "reason": None},
    {"name": "interrupt", "available": True, "reason": None},
    {"name": "steer", "available": True, "reason": None},
    {"name": "approvals", "available": True, "reason": None},
    {"name": "questions", "available": True, "reason": None},
    {"name": "usage", "available": True, "reason": None},
    {"name": "file_changes", "available": True, "reason": None},
    {"name": "diff", "available": True, "reason": None},
    {"name": "replay", "available": True, "reason": None},
]


def agent(record: dict[str, Any]) -> dict[str, Any]:
    return {
        "id": record["id"],
        "provider": record["provider"],
        "provider_session_id": record["session_id"],
        "cwd": record["cwd"],
        "workspace_strategy": "shared",
        "worktree_path": None,
        "title": record["title"],
        "state": record["state"],
        "active_turn_id": record.get("turn_id"),
        "pending_approvals": record.get("pending_approvals", 0),
        "unread_events": 0,
        "capabilities": CAPABILITIES,
        "created_at": "2026-09-01T00:00:00Z",
        "updated_at": "2026-09-01T00:00:00Z",
    }


class Events:
    def __init__(self, broker: Broker) -> None:
        self.broker = broker
        self.sequence = 0

    def send(self, event_type: str, payload: dict[str, Any]) -> None:
        self.sequence += 1
        current = self.broker.current
        send(
            {
                "jsonrpc": "2.0",
                "method": "agent/event",
                "params": {
                    "protocol_version": 1,
                    "sequence": self.sequence,
                    "timestamp": "2026-09-01T00:00:00Z",
                    "agent_id": current["id"],
                    "provider": current["provider"],
                    "type": event_type,
                    "payload": payload,
                    "provider_event": {"kind": "fixture"},
                },
            }
        )


class Broker:
    def __init__(self) -> None:
        self.records: list[dict[str, Any]] = []
        self.current: dict[str, Any] = {}
        self.events = Events(self)
        self.prompt_number = 0
        self.queued_context: list[dict[str, Any]] = []
        self.test_file = os.environ.get("AGENT_MANAGER_TEST_FILE")

    def publish_state(self) -> None:
        send(
            {
                "jsonrpc": "2.0",
                "method": "broker/state",
                "params": {"agents": [agent(record) for record in self.records]},
            }
        )

    def set_state(
        self,
        value: str,
        turn_id: str | None = None,
        pending_approvals: int = 0,
    ) -> None:
        self.current["state"] = value
        self.current["turn_id"] = turn_id
        self.current["pending_approvals"] = pending_approvals
        self.publish_state()

    def launch(
        self,
        request: dict[str, Any],
        session_id: str,
        provider: str,
        cwd: str,
        title: str,
    ) -> None:
        record = {
            "id": f"agent-lua-{len(self.records) + 1}",
            "provider": provider,
            "session_id": session_id,
            "cwd": cwd,
            "title": title,
            "state": "idle",
            "turn_id": None,
            "pending_approvals": 0,
        }
        self.records.append(record)
        self.current = record
        self.publish_state()
        respond(request, {"agent": agent(record)})

    def request_approval(self) -> None:
        self.events.send(
            "approval.requested",
            {
                "id": "approval-lua-1",
                "kind": "approval",
                "tool_name": "Command",
                "summary": "Update the M2 fixture file",
                "command": "fixture --write-file",
                "cwd": self.current["cwd"],
                "paths": [self.test_file] if self.test_file else [],
                "choices": ["allow", "deny"],
                "deferrable": False,
            },
        )
        self.set_state("waiting_approval", "turn-lua-1", 1)
        self.events.send("message.delta", {"delta": "waiting "})

    def request_question(self) -> None:
        self.events.send(
            "question.requested",
            {
                "id": "question-lua-1",
                "kind": "question",
                "questions": [
                    {
                        "id": "mode",
                        "index": 0,
                        "header": "Mode",
                        "question": "Which safe mode should the fixture use?",
                        "options": [
                            {"label": "careful", "description": "Preserve local edits"},
                            {"label": "fast", "description": "Use the short path"},
                        ],
                        "multi_select": False,
                        "secret": False,
                    }
                ],
                "choices": ["answer", "deny"],
                "deferrable": False,
            },
        )
        self.set_state("waiting_input", "turn-lua-1")

    def finish_interactive_turn(self) -> None:
        if self.test_file:
            Path(self.test_file).write_text("disk changed by fixture\n", encoding="utf-8")
        self.events.send(
            "usage.updated",
            {"input_tokens": 12, "output_tokens": 7, "cost_usd": 0.01},
        )
        if self.test_file:
            self.events.send("file.changed", {"path": self.test_file, "operation": "update"})
        self.events.send("message.delta", {"delta": "interactive"})
        self.events.send("message.delta", {"delta": " answer"})
        self.events.send("message.completed", {"text": "waiting interactive answer"})
        self.events.send("turn.completed", {"turn": {"id": "turn-lua-1", "status": "completed"}})
        self.set_state("completed")

    def handle(self, request: dict[str, Any]) -> bool:
        method = request.get("method")
        params = request.get("params", {})
        if method == "agent/list":
            respond(request, {"agents": [agent(record) for record in self.records]})
        elif method == "provider/session/list":
            provider = params["provider"]
            if params.get("active_only"):
                sessions = {
                    "codex": [
                        {
                            "provider": "codex",
                            "provider_session_id": "codex-cli-running",
                            "cwd": "/workspace/repos/alpha/api",
                            "title": "Codex terminal session",
                            "updated_at": "2026-09-01T00:00:02Z",
                            "active": True,
                            "state": "running",
                        }
                    ],
                    "claude": [
                        {
                            "provider": "claude",
                            "provider_session_id": "claude-cli-running",
                            "cwd": "/workspace/repos/alpha/web",
                            "title": "Claude terminal session",
                            "updated_at": "2026-09-01T00:00:01Z",
                            "active": True,
                            "state": "running",
                        }
                    ],
                }
                respond(
                    request,
                    {
                        "sessions": sessions[provider],
                        "cursor": None,
                        "activity_available": True,
                    },
                )
                return True
            respond(
                request,
                {
                    "sessions": [
                        {
                            "provider": provider,
                            "provider_session_id": f"{provider}-resumable-lua",
                            "cwd": params["cwd"],
                            "title": f"{provider} resumable fixture",
                            "updated_at": "2026-09-01T00:00:00Z",
                        }
                    ],
                    "cursor": None,
                    "activity_available": True,
                },
            )
        elif method == "agent/start":
            self.launch(request, "thread-lua-1", params["provider"], params["cwd"], "lua fixture")
        elif method == "agent/resume":
            self.launch(
                request,
                params["provider_session_id"],
                params["provider"],
                params["cwd"],
                "resumed lua fixture",
            )
        elif method == "agent/attach":
            record = next(record for record in self.records if record["id"] == params["agent_id"])
            self.current = record
            respond(request, {"agent": agent(record)})
        elif method == "agent/context/add":
            context = params["context"]
            if context.get("kind") not in {"buffer", "range", "diagnostics", "diff"}:
                reject(request, "invalid context kind")
            else:
                self.queued_context.append(context)
                respond(
                    request,
                    {"queued": True, "count": len(self.queued_context), "context": context},
                )
        elif method == "agent/prompt":
            self.prompt_number += 1
            turn_id = f"turn-lua-{self.prompt_number}"
            respond(request, {"accepted": True, "turn_id": turn_id})
            self.set_state("running", turn_id)
            self.events.send("turn.started", {"turn": {"id": turn_id}})
            if self.prompt_number == 1:
                if not self.queued_context:
                    raise AssertionError("first M2 prompt must have explicit editor context")
                self.queued_context.clear()
                self.events.send(
                    "tool.started",
                    {"item": {"id": "tool-lua-1", "type": "commandExecution", "command": "fixture"}},
                )
                self.request_approval()
            else:
                self.events.send("message.delta", {"delta": "active"})
        elif method == "agent/approval/respond":
            if params["approval_id"] != "approval-lua-1":
                reject(request, "unknown approval")
            elif params["decision"] == "defer":
                reject(request, "this provider request cannot be deferred")
            else:
                respond(request, {"accepted": True})
                self.events.send(
                    "approval.resolved",
                    {"id": "approval-lua-1", "decision": params["decision"], "reason": None},
                )
                self.request_question()
        elif method == "agent/question/respond":
            if params["question_id"] != "question-lua-1":
                reject(request, "unknown question")
            else:
                if params["decision"] == "answer" and params["answers"].get("mode") != "careful":
                    reject(request, "unexpected fixture answer")
                    return True
                respond(request, {"accepted": True})
                self.events.send(
                    "question.resolved",
                    {"id": "question-lua-1", "decision": params["decision"], "reason": None},
                )
                self.finish_interactive_turn()
        elif method == "agent/history":
            respond(
                request,
                {
                    "messages": [
                        {"id": "history-user", "role": "user", "text": "historic question"},
                        {"id": "history-assistant", "role": "assistant", "text": "historic answer"},
                    ],
                    "cursor": None,
                },
            )
        elif method == "agent/steer":
            respond(request, {"accepted": True})
            self.events.send("message.delta", {"delta": " steered"})
        elif method == "agent/interrupt":
            respond(request, {"interrupted": True})
            self.events.send(
                "turn.completed",
                {"turn": {"id": f"turn-lua-{self.prompt_number}", "status": "interrupted"}},
            )
            self.set_state("interrupted")
        elif method == "agent/diff":
            respond(
                request,
                {
                    "cwd": self.current["cwd"],
                    "diff": "diff --git a/fixture b/fixture\n-old\n+new\n",
                    "truncated": False,
                },
            )
        elif method == "agent/fork":
            source = self.current
            source["state"] = "disconnected"
            self.launch(
                request,
                source["session_id"] + "-fork",
                source["provider"],
                source["cwd"],
                "forked lua fixture",
            )
        elif method == "broker/shutdown":
            respond(request, {"shutdown": True})
            return False
        else:
            send(
                {
                    "jsonrpc": "2.0",
                    "id": request.get("id"),
                    "error": {"code": -32601, "message": "Method not found"},
                }
            )
        return True


def main() -> None:
    initialize = read()
    if initialize.get("method") != "initialize":
        raise AssertionError("expected initialize")
    respond(
        initialize,
        {
            "protocol_version": 1,
            "broker_version": "0.2.0",
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

    broker = Broker()
    broker.publish_state()
    while broker.handle(read()):
        pass


if __name__ == "__main__":
    main()
