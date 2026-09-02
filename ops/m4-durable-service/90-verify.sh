#!/usr/bin/env bash
set -euo pipefail

phase_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=m4.env
source "$phase_dir/m4.env"

test "$(id -un)" = "$SERVICE_USER"
if systemctl --user is-enabled "$UNIT_NAME" >/dev/null; then
  printf 'PASS unit enabled\n'
else
  printf 'FAIL unit is not enabled\n' >&2
  exit 1
fi
if systemctl --user is-active "$UNIT_NAME" >/dev/null; then
  printf 'PASS unit active\n'
else
  printf 'FAIL unit is not active\n' >&2
  exit 1
fi
python3 "$phase_dir/verify_runtime.py" \
  "$SOCKET_PATH" "$REGISTRY_PATH" "$STATUS_FILE" "$VERIFY_FILE"
