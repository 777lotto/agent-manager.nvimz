#!/usr/bin/env bash
set -euo pipefail

phase_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.bash
source "$phase_dir/common.bash"

require_service_user
require_service_inactive
install -d -m 0700 "$STATE_DIR"
install -d -m 0755 "$INSTALL_ROOT" "$RELEASES_DIR" "$VENVS_DIR"

state="$STATE_DIR/10-before"
if ! test -e "$state" && ! test -L "$state"; then
  release_preexisted=0
  venv_preexisted=0
  test -d "$RELEASE_DIR" && release_preexisted=1
  test -d "$VERSIONED_VENV" && venv_preexisted=1
  temporary_state="$state.tmp.$$"
  test ! -e "$temporary_state" && test ! -L "$temporary_state" \
    || fail "preserve unexpected installation-state staging path"
  install -d -m 0700 "$temporary_state"
  printf '%s\n' "$release_preexisted" >"$temporary_state/release-preexisted"
  printf '%s\n' "$venv_preexisted" >"$temporary_state/venv-preexisted"
  chmod 0600 "$temporary_state"/*
  mv -T -- "$temporary_state" "$state"
elif ! test -d "$state" || test -L "$state"; then
  fail "preserve unexpected installation state: $state"
fi

if test -d "$RELEASE_DIR"; then
  "$PYTHON_BIN" "$metadata_script" verify-tree \
    --root "$RELEASE_DIR" \
    --version "$RELEASE_VERSION" \
    --target "$RELEASE_TARGET" \
    "${clean_source_args[@]}"
  printf 'PASS preserved verified versioned release\n'
else
  release_staging="$(mktemp -d "$RELEASES_DIR/.m5-release.XXXXXX")"
  cleanup_release_staging() {
    if test -d "$release_staging"; then
      find "$release_staging" -depth -delete
    fi
  }
  trap cleanup_release_staging EXIT
  "$PYTHON_BIN" "$metadata_script" extract \
    --archive "$RELEASE_ARCHIVE" \
    --destination "$release_staging" \
    --expected-root "$bundle_name" \
    --version "$RELEASE_VERSION" \
    --target "$RELEASE_TARGET" \
    "${clean_source_args[@]}"
  mv -T -- "$release_staging/$bundle_name" "$RELEASE_DIR"
  rmdir -- "$release_staging"
  trap - EXIT
  printf 'PASS installed immutable versioned release\n'
fi

if test -d "$VERSIONED_VENV"; then
  test -f "$VERSIONED_VENV/lib/python3.13/site-packages/agent-manager-release.pth" \
    || fail "preserve incomplete versioned venv"
  "$VERSIONED_VENV/bin/python" -B -I -c \
    'import agent_manager_claude_worker, claude_agent_sdk'
  printf 'PASS preserved verified versioned venv\n'
else
  venv_staging="$(mktemp -d "$VENVS_DIR/.m5-venv.XXXXXX")"
  cleanup_venv_staging() {
    if test -d "$venv_staging"; then
      find "$venv_staging" -depth -delete
    fi
  }
  trap cleanup_venv_staging EXIT
  "$PYTHON_BIN" -m venv --without-pip "$venv_staging"
  printf '%s\n' "$RELEASE_DIR/python/site-packages" \
    >"$venv_staging/lib/python3.13/site-packages/agent-manager-release.pth"
  "$venv_staging/bin/python" -B -I -c \
    'import agent_manager_claude_worker, claude_agent_sdk'
  mv -T -- "$venv_staging" "$VERSIONED_VENV"
  trap - EXIT
  printf 'PASS installed locked versioned venv\n'
fi
