#!/usr/bin/env bash
set -euo pipefail

phase_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=m4.env
source "$phase_dir/m4.env"
state_dir="$(dirname -- "$REGISTRY_PATH")"
state_file="$state_dir/m4-service-before.env"

test "$(id -un)" = "$SERVICE_USER"
install -d -m 0700 "$state_dir"
if ! test -e "$state_file"; then
  was_enabled=0
  was_active=0
  systemctl --user is-enabled --quiet "$UNIT_NAME" && was_enabled=1
  systemctl --user is-active --quiet "$UNIT_NAME" && was_active=1
  umask 077
  {
    printf 'WAS_ENABLED=%s\n' "$was_enabled"
    printf 'WAS_ACTIVE=%s\n' "$was_active"
  } >"$state_file"
fi
systemctl --user enable --now "$UNIT_NAME"
printf 'PASS enabled and started durable broker\n'
