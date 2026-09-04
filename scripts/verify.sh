#!/usr/bin/env bash
set -euo pipefail

repo_root="$(git rev-parse --show-toplevel)"
cd "$repo_root"

verify_stage="initialization"
report_failure() {
  status="$?"
  trap - ERR
  if test "${GITHUB_ACTIONS:-}" = true; then
    printf '::error title=Agent Manager verification failed::%s (exit %s)\n' \
      "$verify_stage" "$status"
  fi
  exit "$status"
}
trap report_failure ERR

verify_stage="shell and workflow validation"
bash -n scripts/*.sh
shellcheck scripts/*.sh
actionlint

verify_stage="vendored protocol checksum validation"
(
  cd protocol/vendor/codex/0.152.0
  sha256sum --check --quiet SHA256SUMS
)

verify_stage="Python formatting, typing, and tests"
(
  cd python
  uv sync --frozen --all-groups
  uv run ruff format --check \
    . \
    ../scripts/release_metadata.py \
    ../scripts/test-release-metadata.py
  uv run ruff check \
    . \
    ../scripts/release_metadata.py \
    ../scripts/test-release-metadata.py
  uv run pyright \
    src \
    tests \
    ../scripts/release_metadata.py \
    ../scripts/test-release-metadata.py
  uv run python -m unittest discover -s tests -v
  uv run python ../scripts/validate_protocol.py
  uv run python ../scripts/test-release-metadata.py
)

verify_stage="Rust formatting, linting, and tests"
cargo fmt --all -- --check
cargo clippy --workspace --all-targets --all-features -- -D warnings
scripts/test-rust.sh

verify_stage="Lua broker and editor tests"
scripts/test-lua.sh

verify_stage="UX integration tests"
scripts/test-ux.sh

verify_stage="service and installer validation"
scripts/verify-ops.sh

verify_stage="reproducible release and installer tests"
scripts/verify-release.sh

verify_stage="Git whitespace validation"
git diff --check
