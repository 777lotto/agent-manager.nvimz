#!/usr/bin/env bash
set -euo pipefail

phase_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.bash
source "$phase_dir/common.bash"

require_service_user
require_service_inactive
"$PYTHON_BIN" "$metadata_script" verify-tree \
  --root "$RELEASE_DIR" \
  --version "$RELEASE_VERSION" \
  --target "$RELEASE_TARGET" \
  "${source_revision_args[@]}" \
  "${clean_source_args[@]}"
test -x "$RELEASE_DIR/python/bin/python" || fail "bundled worker Python is unavailable"
require_managed_link_or_absent "$BROKER_LINK" "$RELEASES_DIR" "broker link"
require_managed_link_or_absent "$VENV_LINK" "$RELEASES_DIR" "worker runtime link"
install -d -m 0700 "$STATE_DIR"
install -d -m 0755 "$(dirname -- "$BROKER_LINK")"

state="$STATE_DIR/20-before"
if ! test -e "$state" && ! test -L "$state"; then
  temporary_state="$state.tmp.$$"
  test ! -e "$temporary_state" && test ! -L "$temporary_state" \
    || fail "preserve unexpected activation-state staging path"
  install -d -m 0700 "$temporary_state"
  if test -L "$BROKER_LINK"; then
    printf '1\n' >"$temporary_state/broker-existed"
    link_target "$BROKER_LINK" >"$temporary_state/broker-target"
  else
    printf '0\n' >"$temporary_state/broker-existed"
  fi
  if test -L "$VENV_LINK"; then
    printf '1\n' >"$temporary_state/venv-existed"
    link_target "$VENV_LINK" >"$temporary_state/venv-target"
  else
    printf '0\n' >"$temporary_state/venv-existed"
  fi
  mv -T -- "$temporary_state" "$state"
elif ! test -d "$state" || test -L "$state"; then
  fail "preserve unexpected activation state: $state"
fi

atomic_link "$RELEASE_DIR/bin/agent-manager-broker" "$BROKER_LINK"
atomic_link "$RELEASE_DIR/python" "$VENV_LINK"

printf 'PASS activated stable broker and worker paths\n'
