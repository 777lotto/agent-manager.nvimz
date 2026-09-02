#!/usr/bin/env bash
set -euo pipefail

repo_root="$(git rev-parse --show-toplevel)"
cd "$repo_root"

bash -n scripts/*.sh
shellcheck scripts/*.sh
actionlint

(
  cd protocol/vendor/codex/0.152.0
  sha256sum --check --quiet SHA256SUMS
)

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

cargo fmt --all -- --check
cargo clippy --workspace --all-targets --all-features -- -D warnings
cargo test --workspace --all-features
scripts/test-lua.sh
scripts/test-ux.sh
scripts/verify-ops.sh
scripts/verify-release.sh

git diff --check
