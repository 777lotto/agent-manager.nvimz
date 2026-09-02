#!/usr/bin/env bash
set -euo pipefail

phase_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.bash
source "$phase_dir/common.bash"

require_service_user
test -L "$BROKER_LINK" || fail "stable broker path is not a symlink"
test -L "$VENV_LINK" || fail "stable worker venv path is not a symlink"
test "$(link_target "$BROKER_LINK")" = "$RELEASE_DIR/bin/agent-manager-broker" \
  || fail "stable broker path selects a different release"
test "$(link_target "$VENV_LINK")" = "$VERSIONED_VENV" \
  || fail "stable worker venv selects a different release"

"$PYTHON_BIN" "$phase_dir/verify_install.py" \
  "$RELEASE_DIR" \
  "$BROKER_LINK" \
  "$VENV_LINK/bin/python" \
  "$STATUS_FILE" \
  "$RELEASE_VERSION" \
  "$RELEASE_TARGET" \
  "$REQUIRE_CLEAN_SOURCE"

printf 'PASS verified M5 release installation\n'
