#!/usr/bin/env python3
"""Behavioral M4 socket/status/registry verifier with durable evidence."""

from __future__ import annotations

import json
import os
import socket
import stat
import sys
from datetime import UTC, datetime
from pathlib import Path
from typing import Any


def fail(label: str, detail: str) -> None:
    print(f"FAIL {label}: {detail}")
    raise SystemExit(1)


def check_private(path: Path, expected_type: str, forbidden: int) -> os.stat_result:
    try:
        metadata = path.lstat()
    except OSError as error:
        fail(expected_type, str(error))
    if expected_type == "socket" and not stat.S_ISSOCK(metadata.st_mode):
        fail(expected_type, "path is not a socket")
    if expected_type == "file" and not stat.S_ISREG(metadata.st_mode):
        fail(expected_type, "path is not a regular file")
    if stat.S_IMODE(metadata.st_mode) & forbidden:
        fail(expected_type, "permissions are too broad")
    print(f"PASS {expected_type} path and permissions")
    return metadata


def read_json(path: Path) -> dict[str, Any]:
    value = json.loads(path.read_text(encoding="utf-8"))
    if not isinstance(value, dict):
        fail(path.name, "expected JSON object")
    return value


def main() -> None:
    if len(sys.argv) != 5:
        raise SystemExit("usage: verify_runtime.py SOCKET REGISTRY STATUS EVIDENCE")
    socket_path, registry_path, status_path, evidence_path = map(Path, sys.argv[1:])
    check_private(socket_path, "socket", 0o077)
    check_private(registry_path, "registry file", 0o077)
    check_private(status_path, "status file", 0o007)

    client = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    client.settimeout(5)
    client.connect(str(socket_path))
    initialize = {
        "jsonrpc": "2.0",
        "id": "m4-verify",
        "method": "initialize",
        "params": {
            "protocol_version": 1,
            "client": {"name": "m4-verify", "version": "1"},
            "last_sequence": 0,
        },
    }
    client.sendall(json.dumps(initialize, separators=(",", ":")).encode() + b"\n")
    response = json.loads(client.makefile("rb").readline())
    client.close()
    if response.get("result", {}).get("mode") != "durable":
        fail("socket handshake", "broker did not report durable mode")
    print("PASS socket handshake")

    registry = read_json(registry_path)

    def all_keys(value: Any) -> set[str]:
        if isinstance(value, dict):
            return {str(key).lower() for key in value} | set().union(
                *(all_keys(item) for item in value.values())
            )
        if isinstance(value, list):
            return set().union(*(all_keys(item) for item in value))
        return set()

    forbidden_keys = {"prompt", "tool_payload", "response", "credential", "token"}
    present_forbidden = all_keys(registry) & forbidden_keys
    if present_forbidden:
        fail("registry redaction", f"forbidden keys: {sorted(present_forbidden)}")
    print("PASS registry metadata boundary")

    status = read_json(status_path)
    required = {
        "last_success_at",
        "last_failure_at",
        "last_error",
        "object_count",
        "byte_count",
    }
    if not required.issubset(status):
        fail("status schema", "required monitoring fields are absent")
    if status.get("state") != "running":
        fail("status state", str(status.get("state")))
    print("PASS status schema and running state")

    evidence = {
        "schema_version": 1,
        "verified_at": datetime.now(UTC).isoformat(),
        "service": "agent-manager",
        "socket": str(socket_path),
        "registry_object_count": len(registry.get("agents", [])),
        "registry_byte_count": registry_path.stat().st_size,
        "status_object_count": status["object_count"],
        "status_byte_count": status["byte_count"],
        "result": "PASS",
    }
    temporary = evidence_path.with_name(f".{evidence_path.name}.{os.getpid()}.tmp")
    temporary.write_text(json.dumps(evidence, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    os.chmod(temporary, 0o640)
    os.replace(temporary, evidence_path)
    print(f"PASS evidence written: {evidence_path}")


if __name__ == "__main__":
    main()
