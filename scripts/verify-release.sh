#!/usr/bin/env bash
set -euo pipefail

repo_root="$(git rev-parse --show-toplevel)"
temporary="$(mktemp -d)"
release_stage="initialization"
report_failure() {
  status="$?"
  trap - ERR
  if test "${GITHUB_ACTIONS:-}" = true; then
    printf '::error title=Release verification failed::%s (exit %s)\n' \
      "$release_stage" "$status"
  fi
  exit "$status"
}
cleanup() {
  if test -d "$temporary"; then
    find "$temporary" -depth -delete
  fi
}
trap report_failure ERR
trap cleanup EXIT

first="$temporary/first"
second="$temporary/second"
release_stage="first release build"
RELEASE_ALLOW_DIRTY=1 "$repo_root/scripts/build-release.sh" "$first"
release_stage="second release build"
RELEASE_ALLOW_DIRTY=1 "$repo_root/scripts/build-release.sh" "$second"

release_stage="compatibility metadata read"
release_version="$("$repo_root/python/.venv/bin/python" -c \
  'import json,sys; print(json.load(open(sys.argv[1], encoding="utf-8"))["release_version"])' \
  "$repo_root/release/compatibility-v1.json")"
archive_name="agent-manager-v${release_version}-x86_64-unknown-linux-gnu.tar.gz"
release_stage="release archive reproducibility comparison"
cmp -s "$first/$archive_name" "$second/$archive_name" \
  || {
    printf 'FAIL repeated release builds are not byte-identical\n' >&2
    exit 1
  }
release_stage="release checksum reproducibility comparison"
cmp -s "$first/SHA256SUMS" "$second/SHA256SUMS" \
  || {
    printf 'FAIL repeated release checksum files differ\n' >&2
    exit 1
  }
printf 'PASS repeated release builds are byte-identical\n'

release_stage="release installer lifecycle test"
RELEASE_TEST_ARTIFACT_DIR="$first" "$repo_root/scripts/test-release-install.sh"
