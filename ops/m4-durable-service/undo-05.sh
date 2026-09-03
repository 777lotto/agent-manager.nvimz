#!/usr/bin/env bash
set -euo pipefail

phase_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=m4.env
source "$phase_dir/m4.env"
marker="$STATUS_DIR/.agent-manager-m4-created"

test "$(id -u)" -eq 0 || {
  printf 'FAIL status-directory undo requires the operator control plane\n' >&2
  exit 1
}
if ! test -f "$marker"; then
  printf 'PASS status directory predates this phase; preserved\n'
  exit 0
fi
test ! -L "$STATUS_FILE"
test ! -L "$VERIFY_FILE"
if test -e "$STATUS_FILE"; then
  test -f "$STATUS_FILE"
  grep '"service": "agent-manager"' "$STATUS_FILE" >/dev/null
  rm -- "$STATUS_FILE"
fi
if test -e "$VERIFY_FILE"; then
  test -f "$VERIFY_FILE"
  grep '"service": "agent-manager"' "$VERIFY_FILE" >/dev/null
  rm -- "$VERIFY_FILE"
fi
rm -- "$marker"
if rmdir -- "$STATUS_DIR" 2>/dev/null; then
  printf 'PASS removed phase-created empty status directory\n'
else
  printf 'PASS preserved non-empty status directory\n'
fi
