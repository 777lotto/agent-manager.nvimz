#!/usr/bin/env bash
set -euo pipefail

phase_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=m4.env
source "$phase_dir/m4.env"
unit_source="$phase_dir/agent-manager-broker.service"
backup="$UNIT_TARGET.pre-m4"

test "$(id -un)" = "$SERVICE_USER"
if systemctl --user is-active --quiet "$UNIT_NAME"; then
  printf 'FAIL run undo-20.sh before removing an active unit\n' >&2
  exit 1
fi
if test -e "$backup"; then
  install -m 0644 "$backup" "$UNIT_TARGET"
  rm -- "$backup"
elif test -e "$UNIT_TARGET"; then
  cmp -s -- "$unit_source" "$UNIT_TARGET" || {
    printf 'FAIL preserve unit changed after M4 installation\n' >&2
    exit 1
  }
  rm -- "$UNIT_TARGET"
fi
systemctl --user daemon-reload
printf 'PASS restored prior unit state\n'
