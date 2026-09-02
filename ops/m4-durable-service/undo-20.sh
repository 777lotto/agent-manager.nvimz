#!/usr/bin/env bash
set -euo pipefail

phase_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=m4.env
source "$phase_dir/m4.env"
state_file="$(dirname -- "$REGISTRY_PATH")/m4-service-before.env"

test "$(id -un)" = "$SERVICE_USER"
test -f "$state_file" || {
  printf 'PASS no M4 enable-state record; preserved service\n'
  exit 0
}
# shellcheck disable=SC1090
source "$state_file"
case "${WAS_ENABLED:-}" in 0 | 1) ;; *) exit 1 ;; esac
case "${WAS_ACTIVE:-}" in 0 | 1) ;; *) exit 1 ;; esac

if test "$WAS_ACTIVE" -eq 0; then
  systemctl --user stop "$UNIT_NAME"
fi
if test "$WAS_ENABLED" -eq 0; then
  systemctl --user disable "$UNIT_NAME"
fi
rm -- "$state_file"
printf 'PASS restored prior enable/active state\n'
