#!/usr/bin/env bash
set -euo pipefail

repo_root="$(git rev-parse --show-toplevel)"
cd "$repo_root"

test "$(codex --version)" = "codex-cli 0.151.0"

bash -n scripts/*.sh
shellcheck scripts/*.sh

(
  cd protocol/vendor/codex/0.151.0
  sha256sum --check --quiet SHA256SUMS
)

(
  cd python
  uv sync --frozen --all-groups
  uv run ruff format --check .
  uv run ruff check .
  uv run pyright src tests
  uv run python -m unittest discover -s tests -v
  uv run python ../scripts/validate_protocol.py
)

cargo fmt --all -- --check
cargo clippy --workspace --all-targets --all-features -- -D warnings
cargo test --workspace --all-features

git diff --check
