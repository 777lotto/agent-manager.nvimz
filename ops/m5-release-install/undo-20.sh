#!/usr/bin/env bash
set -euo pipefail

phase_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.bash
source "$phase_dir/common.bash"

require_service_user
require_service_inactive
state="$STATE_DIR/20-before"
test -d "$state" || fail "activation state is unavailable"

restore_link() {
  local path="$1"
  local current_target="$2"
  local existed_file="$3"
  local target_file="$4"
  local managed_root="$5"
  local label="$6"
  local existed
  existed="$(read_flag "$existed_file" "$label existence")"
  case "$existed" in
    0)
      if test ! -e "$path" && test ! -L "$path"; then
        printf 'PASS %s already absent\n' "$label"
      elif test -L "$path" && test "$(link_target "$path")" = "$current_target"; then
        rm -- "$path"
        printf 'PASS removed activated %s\n' "$label"
      else
        fail "preserve changed $label"
      fi
      ;;
    1)
      local prior
      test -f "$target_file" && test ! -L "$target_file" \
        || fail "$label restore target is unavailable"
      prior="$(tr -d '\n' <"$target_file")"
      test "$prior" = "$(realpath -m -s -- "$prior")" \
        || fail "$label restore target is not canonical"
      case "$prior" in
        "$managed_root"/*) ;;
        *) fail "$label restore target is outside its managed root" ;;
      esac
      if test -L "$path" && test "$(link_target "$path")" = "$prior"; then
        printf 'PASS %s already restored\n' "$label"
      elif test -L "$path" && test "$(link_target "$path")" = "$current_target"; then
        atomic_link "$prior" "$path"
        printf 'PASS restored previous %s\n' "$label"
      else
        fail "preserve changed $label"
      fi
      ;;
    *) fail "$label activation state is malformed" ;;
  esac
}

restore_link \
  "$BROKER_LINK" \
  "$RELEASE_DIR/bin/agent-manager-broker" \
  "$state/broker-existed" \
  "$state/broker-target" \
  "$RELEASES_DIR" \
  "broker link"
restore_link \
  "$VENV_LINK" \
  "$RELEASE_DIR/python" \
  "$state/venv-existed" \
  "$state/venv-target" \
  "$RELEASES_DIR" \
  "worker runtime link"
