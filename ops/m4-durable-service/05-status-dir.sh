#!/usr/bin/env bash
set -euo pipefail

phase_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=m4.env
source "$phase_dir/m4.env"
marker="$STATUS_DIR/.agent-manager-m4-created"

test "$(id -u)" -eq 0 || {
  printf 'FAIL status-directory phase requires the operator control plane\n' >&2
  exit 1
}
getent passwd "$SERVICE_USER" >/dev/null
getent group "$SERVICE_GROUP" >/dev/null

if test -e "$STATUS_DIR"; then
  test -d "$STATUS_DIR"
  test "$(stat -c '%U:%G' "$STATUS_DIR")" = "$SERVICE_USER:$SERVICE_GROUP"
  case "$(stat -c '%a' "$STATUS_DIR")" in
    700 | 710 | 750) ;;
    *)
      printf 'FAIL preserve existing status directory with unexpected mode\n' >&2
      exit 1
      ;;
  esac
else
  install -d -o "$SERVICE_USER" -g "$SERVICE_GROUP" -m 0750 "$STATUS_DIR"
  install -o root -g root -m 0600 /dev/null "$marker"
fi

printf 'PASS status directory ready\n'
