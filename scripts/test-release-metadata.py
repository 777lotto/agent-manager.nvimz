#!/usr/bin/env python3
"""Negative cases for M5 archive and checksum validation."""

from __future__ import annotations

import hashlib
import io
import tarfile
import tempfile
import unittest
from collections.abc import Sequence
from pathlib import Path

from release_metadata import (
    ArtifactExpectation,
    ReleaseError,
    parse_payload_checksums,
    safe_archive_members,
    verify_manifest_shape,
    verify_outer_checksum,
)


def tar_bytes(entries: Sequence[tuple[tarfile.TarInfo, bytes]]) -> bytes:
    output = io.BytesIO()
    with tarfile.open(fileobj=output, mode="w") as archive:
        for info, payload in entries:
            info.size = len(payload)
            archive.addfile(info, io.BytesIO(payload) if payload else None)
    return output.getvalue()


def regular(name: str, payload: bytes = b"payload") -> tuple[tarfile.TarInfo, bytes]:
    return tarfile.TarInfo(name), payload


class ArchiveSafetyTests(unittest.TestCase):
    def assert_archive_rejected(
        self, entries: Sequence[tuple[tarfile.TarInfo, bytes]], pattern: str
    ) -> None:
        with (
            tarfile.open(fileobj=io.BytesIO(tar_bytes(entries)), mode="r:") as archive,
            self.assertRaisesRegex(ReleaseError, pattern),
        ):
            safe_archive_members(archive, "agent-manager-v0.1.0")

    def test_duplicate_member_is_rejected(self) -> None:
        self.assert_archive_rejected(
            [
                regular("agent-manager-v0.1.0/file"),
                regular("agent-manager-v0.1.0/file"),
            ],
            "unsafe release archive member",
        )

    def test_noncanonical_member_is_rejected(self) -> None:
        self.assert_archive_rejected(
            [regular("agent-manager-v0.1.0//file")], "unsafe release archive member"
        )

    def test_link_member_is_rejected(self) -> None:
        link = tarfile.TarInfo("agent-manager-v0.1.0/link")
        link.type = tarfile.SYMTYPE
        link.linkname = "file"
        self.assert_archive_rejected([(link, b"")], "unsafe release archive member")


class ChecksumTests(unittest.TestCase):
    def test_outer_checksum_requires_one_exact_entry(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            archive = root / "release.tar.gz"
            checksums = root / "SHA256SUMS"
            archive.write_bytes(b"release")
            digest = hashlib.sha256(b"release").hexdigest()

            checksums.write_text(f"{digest}  {archive.name}\n", encoding="utf-8")
            verify_outer_checksum(archive, checksums)

            checksums.write_text(
                f"{digest}  {archive.name}\n{digest}  extra.tar.gz\n", encoding="utf-8"
            )
            with self.assertRaisesRegex(ReleaseError, "exactly one entry"):
                verify_outer_checksum(archive, checksums)

    def test_payload_checksum_rejects_traversal_and_duplicates(self) -> None:
        digest = "0" * 64
        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary) / "PAYLOAD.SHA256"
            path.write_text(f"{digest}  ../escape\n", encoding="utf-8")
            with self.assertRaisesRegex(ReleaseError, "invalid payload checksum"):
                parse_payload_checksums(path)

            path.write_text(f"{digest}  file\n{digest}  file\n", encoding="utf-8")
            with self.assertRaisesRegex(ReleaseError, "invalid payload checksum"):
                parse_payload_checksums(path)


class ManifestTests(unittest.TestCase):
    def test_production_expectation_rejects_dirty_source(self) -> None:
        manifest = {
            "schema_version": 1,
            "version": "0.1.0",
            "source_revision": "1" * 40,
            "source_dirty": True,
            "source_date_epoch": 1,
            "target": "x86_64-unknown-linux-gnu",
            "compatibility": {
                "release_version": "0.1.0",
                "target": "x86_64-unknown-linux-gnu",
            },
        }
        with self.assertRaisesRegex(ReleaseError, "clean source"):
            verify_manifest_shape(
                manifest,
                ArtifactExpectation(
                    version="0.1.0",
                    target="x86_64-unknown-linux-gnu",
                    require_clean_source=True,
                ),
            )

    def test_source_revision_expectation_is_exact(self) -> None:
        manifest = {
            "schema_version": 1,
            "version": "0.1.0",
            "source_revision": "1" * 40,
            "source_dirty": False,
            "source_date_epoch": 1,
            "target": "x86_64-unknown-linux-gnu",
            "compatibility": {
                "release_version": "0.1.0",
                "target": "x86_64-unknown-linux-gnu",
            },
        }
        with self.assertRaisesRegex(ReleaseError, "requested revision"):
            verify_manifest_shape(
                manifest,
                ArtifactExpectation(source_revision="2" * 40),
            )


if __name__ == "__main__":
    unittest.main()
