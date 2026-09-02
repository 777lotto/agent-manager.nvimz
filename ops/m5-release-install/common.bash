phase_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
m5_env_file="${M5_ENV_FILE:-$phase_dir/m5.env}"

fail() {
  printf 'FAIL %s\n' "$1" >&2
  exit 1
}

test -f "$m5_env_file" || fail "release-install environment is missing: $m5_env_file"
# The selected file is the reviewed parameter boundary. Tests use an isolated fixture file.
# shellcheck disable=SC1090
source "$m5_env_file"

metadata_script="$phase_dir/../../scripts/release_metadata.py"
# Sourced consumers use this derived archive root.
# shellcheck disable=SC2034
bundle_name="agent-manager-v${RELEASE_VERSION}-${RELEASE_TARGET}"
# Sourced consumers append this reviewed verification policy to metadata checks.
# shellcheck disable=SC2034
clean_source_args=()
case "$REQUIRE_CLEAN_SOURCE" in
  0) ;;
  1) clean_source_args+=(--require-clean-source) ;;
  *) fail "REQUIRE_CLEAN_SOURCE must be 0 or 1" ;;
esac

require_absolute() {
  local value="$1"
  local label="$2"
  test "${value:0:1}" = / || fail "$label must be absolute"
  test "$value" = "$(realpath -m -s -- "$value")" || fail "$label must be canonical"
}

validate_parameters() {
  local variable
  for variable in \
    RELEASE_ARCHIVE RELEASE_CHECKSUMS PYTHON_BIN INSTALL_ROOT RELEASES_DIR RELEASE_DIR \
    VENVS_DIR VERSIONED_VENV BROKER_LINK VENV_LINK STATE_DIR STATUS_FILE; do
    require_absolute "${!variable}" "$variable"
  done
  test "$RELEASE_DIR" = "$RELEASES_DIR/v${RELEASE_VERSION}-${RELEASE_TARGET}" \
    || fail "RELEASE_DIR does not match the pinned release"
  test "$VERSIONED_VENV" = "$VENVS_DIR/v${RELEASE_VERSION}-${RELEASE_TARGET}" \
    || fail "VERSIONED_VENV does not match the pinned release"
  test "$VENV_LINK" = "$INSTALL_ROOT/venv" || fail "VENV_LINK must be the stable runtime path"
  test -x "$metadata_script" || fail "release metadata verifier is unavailable"
  case "$SERVICE_STATE_CHECK" in
    systemd) ;;
    test-none)
      test "$m5_env_file" != "$phase_dir/m5.env" \
        || fail "the production environment cannot disable the service-state check"
      ;;
    *) fail "SERVICE_STATE_CHECK must be systemd or test-none" ;;
  esac
}

require_service_user() {
  test "$(id -un)" = "$SERVICE_USER" || fail "run this phase as $SERVICE_USER"
  test "$(id -gn)" = "$SERVICE_GROUP" || fail "primary group must be $SERVICE_GROUP"
}

require_service_inactive() {
  test "$SERVICE_STATE_CHECK" = systemd || return 0
  command -v systemctl >/dev/null || fail "systemctl is required for the service-state check"
  local active_state
  active_state="$(systemctl --user show --property=ActiveState --value "$SERVICE_UNIT")" \
    || fail "cannot query the systemd user manager"
  case "$active_state" in
    inactive | failed) ;;
    active | activating | deactivating | reloading)
      fail "$SERVICE_UNIT must be stopped before changing release links"
      ;;
    *) fail "unexpected $SERVICE_UNIT state: $active_state" ;;
  esac
}

link_target() {
  readlink -- "$1"
}

require_managed_link_or_absent() {
  local path="$1"
  local root="$2"
  local label="$3"
  if test -L "$path"; then
    local target
    target="$(link_target "$path")"
    test "$target" = "$(realpath -m -s -- "$target")" \
      || fail "$label target is not canonical"
    case "$target" in
      "$root"/*) ;;
      *) fail "$label points outside its managed version root" ;;
    esac
  elif test -e "$path"; then
    fail "preserve non-symlink $label: $path"
  fi
}

atomic_link() {
  local target="$1"
  local path="$2"
  local temporary="$path.m5-link.$$"
  test ! -e "$temporary" && test ! -L "$temporary" \
    || fail "preserve unexpected temporary link: $temporary"
  ln -s -- "$target" "$temporary"
  if ! mv -Tf -- "$temporary" "$path"; then
    rm -- "$temporary"
    fail "could not activate $path"
  fi
}

read_flag() {
  local path="$1"
  local label="$2"
  local value
  test -f "$path" && test ! -L "$path" || fail "$label state is unavailable"
  value="$(tr -d '\n' <"$path")"
  case "$value" in
    0 | 1) printf '%s\n' "$value" ;;
    *) fail "$label state is malformed" ;;
  esac
}

remove_managed_tree() {
  local path="$1"
  local root="$2"
  local label="$3"
  case "$path" in
    "$root"/*) ;;
    *) fail "refusing to remove $label outside its managed root" ;;
  esac
  test -d "$path" && test ! -L "$path" || fail "$label is not a managed directory"
  find "$path" -depth -delete
}

validate_parameters
