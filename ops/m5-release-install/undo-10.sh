#!/usr/bin/env bash
set -euo pipefail

phase_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.bash
source "$phase_dir/common.bash"

require_service_user
require_service_inactive
state="$STATE_DIR/10-before"
test -d "$state" && test ! -L "$state" || fail "release installation state is unavailable"
release_preexisted="$(read_flag "$state/release-preexisted" "release")"
venv_preexisted="$(read_flag "$state/venv-preexisted" "venv")"

if test -L "$BROKER_LINK" \
  && test "$(link_target "$BROKER_LINK")" = "$RELEASE_DIR/bin/agent-manager-broker"; then
  fail "run undo-20.sh before removing the active broker release"
fi
if test -L "$VENV_LINK" && test "$(link_target "$VENV_LINK")" = "$VERSIONED_VENV"; then
  fail "run undo-20.sh before removing the active worker venv"
fi

case "$venv_preexisted" in
  0)
    if test -d "$VERSIONED_VENV"; then
      test -f "$VERSIONED_VENV/lib/python3.13/site-packages/agent-manager-release.pth" \
        || fail "preserve changed versioned venv"
      remove_managed_tree "$VERSIONED_VENV" "$VENVS_DIR" "versioned venv"
    fi
    printf 'PASS removed M5-created versioned venv\n'
    ;;
  1) printf 'PASS preserved pre-existing versioned venv\n' ;;
  *) fail "versioned venv installation state is malformed" ;;
esac

case "$release_preexisted" in
  0)
    if test -d "$RELEASE_DIR"; then
      "$PYTHON_BIN" "$metadata_script" verify-tree \
        --root "$RELEASE_DIR" \
        --version "$RELEASE_VERSION" \
        --target "$RELEASE_TARGET" \
        "${clean_source_args[@]}"
      remove_managed_tree "$RELEASE_DIR" "$RELEASES_DIR" "versioned release"
    fi
    printf 'PASS removed M5-created versioned release\n'
    ;;
  1) printf 'PASS preserved pre-existing versioned release\n' ;;
  *) fail "release installation state is malformed" ;;
esac
