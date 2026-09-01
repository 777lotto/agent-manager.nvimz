from __future__ import annotations

import math
import unittest
from dataclasses import dataclass

from agent_manager_claude_worker.encoding import encode_json_value, encode_sdk_message
from agent_manager_claude_worker.protocol import ProtocolFault


@dataclass(frozen=True)
class AssistantMessage:
    content: list[dict[str, str]]
    model: str


@dataclass(frozen=True)
class FutureSdkMessage:
    opaque: object


class EncodingTests(unittest.TestCase):
    def test_known_sdk_message_is_explicitly_tagged(self) -> None:
        event_type, payload = encode_sdk_message(
            AssistantMessage(content=[{"text": "hello"}], model="claude-test")
        )

        self.assertEqual(event_type, "message.assistant")
        self.assertEqual(
            payload,
            {
                "content": [{"text": "hello"}],
                "model": "claude-test",
                "sdk_type": "AssistantMessage",
            },
        )

    def test_unknown_sdk_message_becomes_notice_without_object_dump(self) -> None:
        event_type, payload = encode_sdk_message(FutureSdkMessage(opaque=object()))

        self.assertEqual(event_type, "provider.notice")
        self.assertEqual(
            payload,
            {
                "sdk_type": "FutureSdkMessage",
                "notice": "unsupported Claude SDK message variant",
            },
        )

    def test_encoder_rejects_unreviewed_object_types(self) -> None:
        with self.assertRaisesRegex(ProtocolFault, "unsupported provider value type"):
            encode_json_value(object())

    def test_encoder_rejects_non_finite_numbers(self) -> None:
        for value in (math.inf, -math.inf, math.nan):
            with self.subTest(value=value), self.assertRaisesRegex(ProtocolFault, "finite"):
                encode_json_value(value)


if __name__ == "__main__":
    unittest.main()
