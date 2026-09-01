"""Small, strict JSON-RPC helpers for the private worker boundary."""

from __future__ import annotations

import json
from dataclasses import dataclass
from math import isfinite
from typing import Final

type JsonScalar = bool | int | float | str | None
type JsonValue = JsonScalar | list[JsonValue] | dict[str, JsonValue]
type JsonObject = dict[str, JsonValue]
type RequestId = int | str

JSONRPC_VERSION: Final = "2.0"
MAX_FRAME_BYTES: Final = 1_048_576


@dataclass(frozen=True, slots=True)
class ProtocolFault(Exception):
    """A JSON-RPC error that is safe to return to the broker."""

    code: int
    message: str
    data: JsonValue = None

    def __str__(self) -> str:
        return self.message


def parse_frame(raw: bytes) -> JsonObject:
    """Parse one bounded UTF-8 JSON object without accepting NaN values."""

    if not raw:
        raise ProtocolFault(-32700, "empty protocol frame")
    if len(raw) > MAX_FRAME_BYTES:
        raise ProtocolFault(-32010, "protocol frame exceeds size limit")

    try:
        decoded = raw.decode("utf-8")
        decoded_value: JsonValue = json.loads(
            decoded,
            object_pairs_hook=_reject_duplicate_keys,
            parse_constant=_reject_non_finite,
            parse_float=_parse_finite_float,
        )
    except (UnicodeDecodeError, json.JSONDecodeError, RecursionError, ValueError) as error:
        raise ProtocolFault(-32700, "invalid JSON protocol frame") from error

    if not isinstance(decoded_value, dict):
        raise ProtocolFault(-32600, "protocol frame must be a JSON object")
    if decoded_value.get("jsonrpc") != JSONRPC_VERSION:
        raise ProtocolFault(-32600, 'protocol frame must declare jsonrpc "2.0"')
    return decoded_value


def request(request_id: RequestId, method: str, params: JsonObject) -> JsonObject:
    return {"jsonrpc": JSONRPC_VERSION, "id": request_id, "method": method, "params": params}


def notification(method: str, params: JsonObject) -> JsonObject:
    return {"jsonrpc": JSONRPC_VERSION, "method": method, "params": params}


def result(request_id: RequestId, value: JsonValue) -> JsonObject:
    return {"jsonrpc": JSONRPC_VERSION, "id": request_id, "result": value}


def error_response(request_id: RequestId | None, fault: ProtocolFault) -> JsonObject:
    error: JsonObject = {"code": fault.code, "message": fault.message}
    if fault.data is not None:
        error["data"] = fault.data
    return {"jsonrpc": JSONRPC_VERSION, "id": request_id, "error": error}


def encode_frame(message: JsonObject) -> bytes:
    encoded = json.dumps(
        message,
        ensure_ascii=False,
        allow_nan=False,
        separators=(",", ":"),
        sort_keys=True,
    ).encode("utf-8")
    if len(encoded) > MAX_FRAME_BYTES:
        raise ProtocolFault(-32010, "outbound protocol frame exceeds size limit")
    return encoded + b"\n"


def require_object(value: JsonValue, name: str) -> JsonObject:
    if not isinstance(value, dict):
        raise ProtocolFault(-32602, f"{name} must be an object")
    return value


def require_string(value: JsonValue, name: str, *, allow_empty: bool = False) -> str:
    if not isinstance(value, str) or (not allow_empty and not value):
        raise ProtocolFault(-32602, f"{name} must be a non-empty string")
    return value


def optional_string(value: JsonValue, name: str) -> str | None:
    if value is None:
        return None
    return require_string(value, name)


def request_id_of(message: JsonObject) -> RequestId | None:
    value = message.get("id")
    if value is None:
        return None
    if isinstance(value, bool) or not isinstance(value, (int, str)):
        raise ProtocolFault(-32600, "request id must be a string or integer")
    return value


def _reject_non_finite(value: str) -> JsonValue:
    raise ValueError(f"non-finite JSON number: {value}")


def _parse_finite_float(value: str) -> float:
    parsed = float(value)
    if not isfinite(parsed):
        raise ValueError(f"non-finite JSON number: {value}")
    return parsed


def _reject_duplicate_keys(pairs: list[tuple[str, JsonValue]]) -> JsonObject:
    value: JsonObject = {}
    for key, item in pairs:
        if key in value:
            raise ValueError(f"duplicate JSON object key: {key}")
        value[key] = item
    return value
