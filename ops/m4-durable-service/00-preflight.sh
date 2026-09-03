#!/usr/bin/env bash
set -euo pipefail

phase_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=m4.env
source "$phase_dir/m4.env"

fail() {
  printf 'FAIL %s\n' "$1" >&2
  exit 1
}

test "$(id -un)" = "$SERVICE_USER" || fail "run preflight as $SERVICE_USER"
test "$(id -gn)" = "$SERVICE_GROUP" || fail "primary group must be $SERVICE_GROUP"
test "$(id -u)" = "$SERVICE_UID" || fail "SERVICE_UID does not match $SERVICE_USER"
test -x "$BROKER_BIN" || fail "broker artifact is not executable: $BROKER_BIN"
test -x "$CODEX_BIN" || fail "Codex executable is not available: $CODEX_BIN"
test -x "$CLAUDE_PYTHON" || fail "locked Claude Python is not executable: $CLAUDE_PYTHON"
test -x "$WORKSPACE_LIFECYCLE" \
  || fail "workspace lifecycle is not executable: $WORKSPACE_LIFECYCLE"
test "${UNIT_TARGET:0:1}" = / || fail "UNIT_TARGET must be absolute"
test "${STATUS_FILE:0:1}" = / || fail "STATUS_FILE must be absolute"
test "${SOCKET_PATH:0:1}" = / || fail "SOCKET_PATH must be absolute"
test "${REGISTRY_PATH:0:1}" = / || fail "REGISTRY_PATH must be absolute"
command -v systemctl >/dev/null || fail "systemctl is unavailable"
command -v loginctl >/dev/null || fail "loginctl is unavailable"
test "$(loginctl show-user "$SERVICE_USER" -p Linger --value 2>/dev/null)" = yes \
  || fail "the container lifecycle manager must already have linger enabled for $SERVICE_USER"

if test -e "$STATUS_DIR"; then
  test -d "$STATUS_DIR" || fail "status path exists but is not a directory"
  test "$(stat -c '%U:%G' "$STATUS_DIR")" = "$SERVICE_USER:$SERVICE_GROUP" \
    || fail "existing status directory has unexpected ownership"
  status_mode="$(stat -c '%a' "$STATUS_DIR")"
  case "$status_mode" in
    700 | 710 | 750) ;;
    *) fail "existing status directory must not be world-accessible" ;;
  esac
fi

printf 'PASS preflight\n'
