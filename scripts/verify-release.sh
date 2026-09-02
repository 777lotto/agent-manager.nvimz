#!/usr/bin/env bash
set -euo pipefail

repo_root="$(git rev-parse --show-toplevel)"
temporary="$(mktemp -d)"
cleanup() {
  if test -d "$temporary"; then
    find "$temporary" -depth -delete
  fi
}
trap cleanup EXIT

first="$temporary/first"
second="$temporary/second"
RELEASE_ALLOW_DIRTY=1 "$repo_root/scripts/build-release.sh" "$first"
RELEASE_ALLOW_DIRTY=1 "$repo_root/scripts/build-release.sh" "$second"

archive_name="agent-manager-v0.1.0-x86_64-unknown-linux-gnu.tar.gz"
cmp -s "$first/$archive_name" "$second/$archive_name" \
  || {
    printf 'FAIL repeated release builds are not byte-identical\n' >&2
    exit 1
  }
cmp -s "$first/SHA256SUMS" "$second/SHA256SUMS" \
  || {
    printf 'FAIL repeated release checksum files differ\n' >&2
    exit 1
  }
printf 'PASS repeated release builds are byte-identical\n'

RELEASE_TEST_ARTIFACT_DIR="$first" "$repo_root/scripts/test-release-install.sh"
