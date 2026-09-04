#!/usr/bin/env bash
set -euo pipefail

test_log="$(mktemp)"
trap 'rm -- "$test_log"' EXIT

set +e
cargo test --workspace --all-features 2>&1 | tee "$test_log"
pipeline_status=("${PIPESTATUS[@]}")
set -e

test_status="${pipeline_status[0]}"
if test "${pipeline_status[1]}" -ne 0 && test "$test_status" -eq 0; then
  test_status=1
fi
if test "$test_status" -eq 0; then
  exit 0
fi

if test "${GITHUB_ACTIONS:-}" = true; then
  failure_summary="$(tail -n 40 "$test_log")"
  failure_summary="${failure_summary//%/%25}"
  failure_summary="${failure_summary//$'\r'/%0D}"
  failure_summary="${failure_summary//$'\n'/%0A}"
  printf '::error title=Rust test failure::%s\n' "$failure_summary"
fi
exit "$test_status"
