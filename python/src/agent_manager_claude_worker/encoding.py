"""Explicit conversion of pinned Claude SDK records into JSON-safe values."""

from __future__ import annotations

from dataclasses import fields, is_dataclass
from enum import Enum
from math import isfinite
from pathlib import Path
from typing import Final, cast

from .protocol import JsonObject, JsonValue, ProtocolFault

MAX_DEPTH: Final = 24
MAX_COLLECTION_ITEMS: Final = 10_000
MAX_STRING_CHARS: Final = 512_000

_MESSAGE_EVENTS: Final[dict[str, str]] = {
    "AssistantMessage": "message.assistant",
    "ConversationResetMessage": "conversation.reset",
    "HookEventMessage": "hook.event",
    "RateLimitEvent": "rate_limit",
    "ResultMessage": "result",
    "StreamEvent": "stream.event",
    "SystemMessage": "message.system",
    "TaskNotificationMessage": "task.notification",
    "TaskProgressMessage": "task.progress",
    "TaskStartedMessage": "task.started",
    "UserMessage": "message.user",
}


def encode_sdk_message(message: object) -> tuple[str, JsonObject]:
    """Encode only the SDK message variants reviewed for the pinned release."""

    sdk_type = type(message).__name__
    event_type = _MESSAGE_EVENTS.get(sdk_type)
    if event_type is None:
        return (
            "provider.notice",
            {
                "sdk_type": sdk_type,
                "notice": "unsupported Claude SDK message variant",
            },
        )

    encoded = encode_json_value(message)
    if not isinstance(encoded, dict):
        raise ProtocolFault(-32020, f"encoded {sdk_type} record is not an object")
    payload = cast(JsonObject, encoded)
    payload["sdk_type"] = sdk_type
    return event_type, payload


def encode_json_value(value: object, *, _depth: int = 0) -> JsonValue:  # noqa: PLR0911, PLR0912
    """Convert reviewed data shapes without falling back to repr or object dumps."""

    if _depth > MAX_DEPTH:
        raise ProtocolFault(-32020, "provider value exceeds nesting limit")
    if value is None or isinstance(value, (bool, int)):
        return value
    if isinstance(value, float):
        if not isfinite(value):
            raise ProtocolFault(-32020, "provider number must be finite")
        return value
    if isinstance(value, str):
        if len(value) > MAX_STRING_CHARS:
            raise ProtocolFault(-32020, "provider string exceeds size limit")
        return value
    if isinstance(value, Path):
        return str(value)
    if isinstance(value, Enum):
        return encode_json_value(value.value, _depth=_depth + 1)
    if isinstance(value, dict):
        mapping = cast(dict[object, object], value)
        if len(mapping) > MAX_COLLECTION_ITEMS:
            raise ProtocolFault(-32020, "provider object exceeds item limit")
        encoded_object: JsonObject = {}
        for key, item in mapping.items():
            if not isinstance(key, str):
                raise ProtocolFault(-32020, "provider object keys must be strings")
            encoded_object[key] = encode_json_value(item, _depth=_depth + 1)
        return encoded_object
    if isinstance(value, (list, tuple)):
        items = cast(list[object] | tuple[object, ...], value)
        if len(items) > MAX_COLLECTION_ITEMS:
            raise ProtocolFault(-32020, "provider array exceeds item limit")
        return [encode_json_value(item, _depth=_depth + 1) for item in items]
    if is_dataclass(value) and not isinstance(value, type):
        encoded_dataclass: JsonObject = {}
        for field in fields(value):
            encoded_dataclass[field.name] = encode_json_value(
                getattr(value, field.name), _depth=_depth + 1
            )
        return encoded_dataclass

    raise ProtocolFault(-32020, f"unsupported provider value type: {type(value).__name__}")
