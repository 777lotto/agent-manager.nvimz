#!/usr/bin/env bash
set -euo pipefail

repo_root="$(git rev-parse --show-toplevel)"
phase_dir="$repo_root/ops/m4-durable-service"

bash -n "$phase_dir"/*.sh
shellcheck -x -P "$phase_dir" "$phase_dir"/*.sh
for phase_script in "$phase_dir"/*.sh "$phase_dir/verify_runtime.py"; do
  test -x "$phase_script"
done
(
  cd "$repo_root/python"
  uv run ruff format --check ../ops/m4-durable-service/verify_runtime.py
  uv run ruff check ../ops/m4-durable-service/verify_runtime.py
)
python3 -c 'from pathlib import Path; import sys; path = Path(sys.argv[1]); compile(path.read_text(), str(path), "exec")' \
  "$phase_dir/verify_runtime.py"

unit_check="$(mktemp --suffix=.service)"
trap 'rm -- "$unit_check"' EXIT
sed 's#^ExecStart=.*#ExecStart=/bin/true#' \
  "$phase_dir/agent-manager-broker.service" >"$unit_check"
systemd-analyze --user verify "$unit_check"
