#!/usr/bin/env bash
set -euo pipefail

repo_root="$(git rev-parse --show-toplevel)"
test "$(nvim --version | sed -n '1s/^NVIM v//p')" = "0.12.4"

AGENT_MANAGER_TEST_ROOT="$repo_root" \
  nvim --headless -u NONE -i NONE -l "$repo_root/tests/lua/run.lua"
