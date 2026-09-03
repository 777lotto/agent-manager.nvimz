#!/usr/bin/env python3
"""Validate schemas and every committed cross-language contract fixture."""

from __future__ import annotations

import json
from pathlib import Path
from typing import Any

from jsonschema import Draft202012Validator, FormatChecker

ROOT = Path(__file__).resolve().parents[1]
CONTRACTS = (
    (ROOT / "protocol/broker/v1/broker.schema.json", ROOT / "protocol/broker/v1/fixtures"),
    (
        ROOT / "protocol/claude-worker/v1/worker.schema.json",
        ROOT / "protocol/claude-worker/v1/fixtures",
    ),
)
INVALID_CASES: dict[str, tuple[dict[str, Any], ...]] = {
    "broker.schema.json": (
        {"jsonrpc": "2.0", "id": None, "method": "agent/list", "params": {}},
        {
            "jsonrpc": "2.0",
            "id": 1,
            "result": {},
            "error": {"code": -32603, "message": "both branches are invalid"},
        },
        {
            "jsonrpc": "2.0",
            "method": "agent/event",
            "params": {
                "protocol_version": 1,
                "sequence": 0,
                "timestamp": "2026-08-31T18:00:00Z",
                "agent_id": "agent-1",
                "provider": "codex",
                "type": "provider.notice",
                "payload": {},
                "provider_event": {},
            },
        },
        {
            "jsonrpc": "2.0",
            "id": 7,
            "method": "agent/approval/respond",
            "params": {
                "agent_id": "agent-1",
                "approval_id": "approval-1",
                "decision": "allow_always",
            },
        },
        {
            "jsonrpc": "2.0",
            "id": 8,
            "method": "agent/question/respond",
            "params": {
                "agent_id": "agent-1",
                "question_id": "question-1",
                "decision": "allow",
                "answers": {},
            },
        },
    ),
    "worker.schema.json": (
        {"jsonrpc": "2.0", "id": True, "method": "session/list", "params": {}},
        {
            "jsonrpc": "2.0",
            "method": "session/event",
            "params": {
                "agent_id": "agent-1",
                "provider_session_id": None,
                "worker_sequence": 0,
                "event_type": "provider.notice",
                "payload": {},
            },
        },
        {
            "jsonrpc": "2.0",
            "id": "worker:callback",
            "method": "approval/request",
            "params": {
                "callback_id": "callback",
                "agent_id": "agent-1",
                "provider_session_id": None,
                "tool_name": "Bash",
                "input": {},
                "context": {},
                "unexpected": True,
            },
        },
    ),
}


def load_json(path: Path) -> Any:  # noqa: ANN401
    with path.open("r", encoding="utf-8") as handle:
        return json.load(handle)


def main() -> None:
    checked = 0
    rejected = 0
    for schema_path, fixtures_path in CONTRACTS:
        schema = load_json(schema_path)
        Draft202012Validator.check_schema(schema)
        validator = Draft202012Validator(schema, format_checker=FormatChecker())
        for fixture_path in sorted(fixtures_path.glob("*.json")):
            validator.validate(load_json(fixture_path))
            checked += 1
        for invalid in INVALID_CASES[schema_path.name]:
            if validator.is_valid(invalid):
                raise AssertionError(f"{schema_path.name} accepted a known-invalid message")
            rejected += 1
    print(f"validated {checked} protocol fixtures and {rejected} rejection cases")


if __name__ == "__main__":
    main()
