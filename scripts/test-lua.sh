#!/usr/bin/env bash
set -euo pipefail

repo_root="$(git rev-parse --show-toplevel)"
test_log="$(mktemp)"
trap 'rm -- "$test_log"' EXIT

if ! test "$(nvim --version | sed -n '1s/^NVIM v//p')" = "0.12.4"; then
  if test "${GITHUB_ACTIONS:-}" = true; then
    printf '%s\n' '::error title=Lua editor tests failed::Neovim is not the pinned 0.12.4 release'
  fi
  exit 1
fi

set +e
AGENT_MANAGER_TEST_ROOT="$repo_root" \
  nvim --headless -u NONE -i NONE -l "$repo_root/tests/lua/run.lua" \
  2>&1 | tee "$test_log"
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
  failure_summary="$(tail -n 80 "$test_log")"
  failure_summary="${failure_summary//%/%25}"
  failure_summary="${failure_summary//$'\r'/%0D}"
  failure_summary="${failure_summary//$'\n'/%0A}"
  printf '::error title=Lua editor tests failed::%s\n' "$failure_summary"
fi
exit "$test_status"
