#!/usr/bin/env bash
# Reverse the current portable install through the reviewed M5 undo phases.
set -euo pipefail

phase_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd -- "$phase_dir/../.." && pwd)"
command -v realpath >/dev/null || {
  printf 'FAIL realpath is required to locate the release state\n' >&2
  exit 1
}
verify_python="${AGENT_MANAGER_VERIFY_PYTHON:-$(command -v python3 || true)}"
test -x "$verify_python" || {
  printf 'FAIL Python 3.11 or newer is required to locate the release state\n' >&2
  exit 1
}
"$verify_python" -c 'import sys; raise SystemExit(sys.version_info < (3, 11))' || {
  printf 'FAIL Python 3.11 or newer is required to locate the release state\n' >&2
  exit 1
}
read -r release_version release_target < <(
  cd -- "$repo_root"
  "$verify_python" -c '
import json
from pathlib import Path

compatibility = json.loads(Path("release/compatibility-v1.json").read_text(encoding="utf-8"))
print(compatibility["release_version"], compatibility["target"])
'
)
state_home="${XDG_STATE_HOME:-$HOME/.local/state}"
default_env="$(realpath -m -s -- "$state_home/agent-manager/release-install/v${release_version}-${release_target}/install.env")"
env_file="${M5_ENV_FILE:-$default_env}"
test -f "$env_file" && test ! -L "$env_file" || {
  printf 'FAIL release-install environment is unavailable: %s\n' "$env_file" >&2
  exit 1
}

M5_ENV_FILE="$env_file" "$phase_dir/undo-20.sh"
M5_ENV_FILE="$env_file" "$phase_dir/undo-10.sh"
printf 'PASS restored the runtime state recorded before this release\n'
