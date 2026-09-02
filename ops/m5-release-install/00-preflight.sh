#!/usr/bin/env bash
set -euo pipefail

phase_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.bash
source "$phase_dir/common.bash"

require_service_user
require_service_inactive
test "$(uname -s)" = Linux || fail "the pinned release requires Linux"
test "$(uname -m)" = x86_64 || fail "the pinned release requires x86_64"
test -x "$PYTHON_BIN" || fail "pinned Python is not executable: $PYTHON_BIN"
test "$($PYTHON_BIN --version)" = "Python 3.13.15" || fail "pinned Python must be 3.13.15"
test -f "$RELEASE_ARCHIVE" || fail "release archive is missing: $RELEASE_ARCHIVE"
test -f "$RELEASE_CHECKSUMS" || fail "release checksums are missing: $RELEASE_CHECKSUMS"

require_managed_link_or_absent "$BROKER_LINK" "$RELEASES_DIR" "broker link"
require_managed_link_or_absent "$VENV_LINK" "$VENVS_DIR" "worker venv link"

"$PYTHON_BIN" "$metadata_script" verify-archive \
  --archive "$RELEASE_ARCHIVE" \
  --checksum-file "$RELEASE_CHECKSUMS" \
  --expected-root "$bundle_name" \
  --version "$RELEASE_VERSION" \
  --target "$RELEASE_TARGET" \
  "${clean_source_args[@]}"

printf 'PASS M5 release preflight\n'
