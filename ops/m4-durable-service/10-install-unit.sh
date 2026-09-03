#!/usr/bin/env bash
set -euo pipefail

phase_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=m4.env
source "$phase_dir/m4.env"
unit_source="$phase_dir/agent-manager-broker.service"
unit_dir="$(dirname -- "$UNIT_TARGET")"
backup="$UNIT_TARGET.pre-m4"

test "$(id -un)" = "$SERVICE_USER"
install -d -m 0700 "$unit_dir"
if test -e "$UNIT_TARGET" && ! cmp -s -- "$unit_source" "$UNIT_TARGET"; then
  grep '^# managed by agent-manager M4 durable-service phase$' "$UNIT_TARGET" >/dev/null || {
    printf 'FAIL preserve unknown existing unit: %s\n' "$UNIT_TARGET" >&2
    exit 1
  }
  test -e "$backup" || install -m 0644 "$UNIT_TARGET" "$backup"
fi
install -m 0644 "$unit_source" "$UNIT_TARGET"
systemctl --user daemon-reload
printf 'PASS installed user unit\n'
