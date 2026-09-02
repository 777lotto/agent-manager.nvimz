#!/usr/bin/env bash
set -euo pipefail

repo_root="$(git rev-parse --show-toplevel)"
phase="$repo_root/ops/m5-release-install"
artifact_dir="${RELEASE_TEST_ARTIFACT_DIR:?RELEASE_TEST_ARTIFACT_DIR is required}"
archive="$artifact_dir/agent-manager-v0.1.0-x86_64-unknown-linux-gnu.tar.gz"
checksums="$artifact_dir/SHA256SUMS"
test -f "$archive"
test -f "$checksums"

test_root="$(mktemp -d)"
cleanup() {
  if test -d "$test_root"; then
    find "$test_root" -depth -delete
  fi
}
trap cleanup EXIT

install_root="$test_root/share/agent-manager"
releases_dir="$install_root/releases"
venvs_dir="$install_root/venvs"
release_dir="$releases_dir/v0.1.0-x86_64-unknown-linux-gnu"
versioned_venv="$venvs_dir/v0.1.0-x86_64-unknown-linux-gnu"
broker_link="$test_root/bin/agent-manager-broker"
venv_link="$install_root/venv"
state_dir="$test_root/state"
status_file="$state_dir/status.json"
env_file="$test_root/m5-test.env"

mkdir -p "$releases_dir/v0.0.0/bin" "$venvs_dir/v0.0.0" "$(dirname -- "$broker_link")"
printf 'old broker\n' >"$releases_dir/v0.0.0/bin/agent-manager-broker"
ln -s "$releases_dir/v0.0.0/bin/agent-manager-broker" "$broker_link"
ln -s "$venvs_dir/v0.0.0" "$venv_link"

{
  printf 'SERVICE_USER=%s\n' "$(id -un)"
  printf 'SERVICE_GROUP=%s\n' "$(id -gn)"
  printf 'SERVICE_UNIT=agent-manager-m5-test.service\n'
  printf 'SERVICE_STATE_CHECK=test-none\n'
  printf 'REQUIRE_CLEAN_SOURCE=0\n'
  printf 'RELEASE_VERSION=0.1.0\n'
  printf 'RELEASE_TARGET=x86_64-unknown-linux-gnu\n'
  printf 'RELEASE_ARCHIVE=%s\n' "$archive"
  printf 'RELEASE_CHECKSUMS=%s\n' "$checksums"
  printf 'PYTHON_BIN=%s\n' "$repo_root/python/.venv/bin/python"
  printf 'INSTALL_ROOT=%s\n' "$install_root"
  printf 'RELEASES_DIR=%s\n' "$releases_dir"
  printf 'RELEASE_DIR=%s\n' "$release_dir"
  printf 'VENVS_DIR=%s\n' "$venvs_dir"
  printf 'VERSIONED_VENV=%s\n' "$versioned_venv"
  printf 'BROKER_LINK=%s\n' "$broker_link"
  printf 'VENV_LINK=%s\n' "$venv_link"
  printf 'STATE_DIR=%s\n' "$state_dir"
  printf 'STATUS_FILE=%s\n' "$status_file"
} >"$env_file"

export M5_ENV_FILE="$env_file"
"$phase/00-preflight.sh"
"$phase/10-install-release.sh"
"$phase/10-install-release.sh"
"$phase/20-activate-release.sh"
"$phase/20-activate-release.sh"
"$phase/90-verify.sh"

test "$(readlink -- "$broker_link")" = "$release_dir/bin/agent-manager-broker"
test "$(readlink -- "$venv_link")" = "$versioned_venv"
test -s "$status_file"
grep '"last_error": null' "$status_file" >/dev/null

"$phase/undo-20.sh"
"$phase/undo-20.sh"
test "$(readlink -- "$broker_link")" = "$releases_dir/v0.0.0/bin/agent-manager-broker"
test "$(readlink -- "$venv_link")" = "$venvs_dir/v0.0.0"
"$phase/undo-10.sh"
"$phase/undo-10.sh"
test ! -e "$release_dir"
test ! -e "$versioned_venv"

printf 'PASS release install apply, verify, idempotence, and paired undo\n'
