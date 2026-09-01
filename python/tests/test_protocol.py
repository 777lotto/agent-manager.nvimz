from __future__ import annotations

import unittest
from typing import Any

from agent_manager_claude_worker.protocol import (
    MAX_FRAME_BYTES,
    ProtocolFault,
    encode_frame,
    parse_frame,
    request,
)


class ProtocolTests(unittest.TestCase):
    def test_protocol_round_trip(self) -> None:
        message = request("request-1", "worker/initialize", {"protocol_version": 1})
        self.assertEqual(parse_frame(encode_frame(message).rstrip(b"\n")), message)

    def test_protocol_rejects_invalid_frames(self) -> None:
        invalid_frames = [
            b"",
            b"[]",
            b'{"id":1}',
            b'{"jsonrpc":"1.0"}',
            b'{"jsonrpc":"2.0","value":NaN}',
            b'{"jsonrpc":"2.0","value":1e400}',
            b'{"jsonrpc":"2.0","id":1,"id":2}',
            b"\xff",
        ]
        for raw in invalid_frames:
            with self.subTest(raw=raw), self.assertRaises(ProtocolFault):
                parse_frame(raw)

    def test_protocol_rejects_oversized_frames(self) -> None:
        with self.assertRaisesRegex(ProtocolFault, "size limit"):
            parse_frame(b"{" + (b" " * MAX_FRAME_BYTES) + b"}")

    def test_protocol_encoder_rejects_non_finite_values(self) -> None:
        unsafe: dict[str, Any] = {"jsonrpc": "2.0", "value": float("inf")}
        with self.assertRaises(ValueError):
            encode_frame(unsafe)  # type: ignore[arg-type]


if __name__ == "__main__":
    unittest.main()
