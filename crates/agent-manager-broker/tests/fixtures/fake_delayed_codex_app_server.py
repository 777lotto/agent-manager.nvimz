#!/usr/bin/env python3
"""Codex fixture whose thread open completes after an editor reconnect."""

from __future__ import annotations

import json
import sys
import time
from typing import Any


def read() -> dict[str, Any]:
    value = json.loads(sys.stdin.readline())
    if not isinstance(value, dict):
        raise TypeError("expected object frame")
    return value


def send(value: dict[str, Any]) -> None:
    sys.stdout.write(json.dumps(value, separators=(",", ":")) + "\n")
    sys.stdout.flush()


initialize = read()
send({"id": initialize["id"], "result": {"userAgent": "codex_cli_rs/0.152.0"}})
if read().get("method") != "initialized":
    raise AssertionError("expected initialized notification")
opening = read()
if opening.get("method") != "thread/start":
    raise AssertionError("expected thread/start")
time.sleep(0.2)
send({"method": "thread/started", "params": {"thread": {"id": "thread-delayed"}}})
send({"id": opening["id"], "result": {"thread": {"id": "thread-delayed", "turns": []}}})
while sys.stdin.readline():
    pass
