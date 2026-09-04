#!/usr/bin/env bash
set -euo pipefail

repo_root="$(git rev-parse --show-toplevel)"
report_failure() {
  status="$?"
  trap - ERR
  if test "${GITHUB_ACTIONS:-}" = true; then
    printf '::error title=Lua editor tests failed::headless Neovim tests exited %s\n' \
      "$status"
  fi
  exit "$status"
}
trap report_failure ERR

test "$(nvim --version | sed -n '1s/^NVIM v//p')" = "0.12.4"

AGENT_MANAGER_TEST_ROOT="$repo_root" \
  nvim --headless -u NONE -i NONE -l "$repo_root/tests/lua/run.lua"
