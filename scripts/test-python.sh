#!/usr/bin/env bash
set -euo pipefail

repo_root="$(git rev-parse --show-toplevel)"
test_log="$(mktemp)"
trap 'rm -- "$test_log"' EXIT

run_stage() {
  local stage="$1"
  shift
  : >"$test_log"
  set +e
  "$@" 2>&1 | tee "$test_log"
  local pipeline_status=("${PIPESTATUS[@]}")
  set -e

  local test_status="${pipeline_status[0]}"
  if test "${pipeline_status[1]}" -ne 0 && test "$test_status" -eq 0; then
    test_status=1
  fi
  if test "$test_status" -eq 0; then
    return 0
  fi

  if test "${GITHUB_ACTIONS:-}" = true; then
    local failure_summary
    failure_summary="$(tail -n 40 "$test_log")"
    failure_summary="${failure_summary//%/%25}"
    failure_summary="${failure_summary//$'\r'/%0D}"
    failure_summary="${failure_summary//$'\n'/%0A}"
    printf '::error title=%s::%s\n' "$stage" "$failure_summary"
  fi
  return "$test_status"
}

cd "$repo_root/python"
run_stage "Python unit test failure" \
  uv run python -m unittest discover -s tests -v
run_stage "Protocol validation failure" \
  uv run python "$repo_root/scripts/validate_protocol.py"
