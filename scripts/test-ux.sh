#!/usr/bin/env bash
set -euo pipefail

repo_root="$(git rev-parse --show-toplevel)"

# The repository root is resolved dynamically.
# shellcheck disable=SC1091
source "$repo_root/tests/ux-pins.env"

resolve_checkout() {
  local configured="$1"
  shift
  if [[ -n "$configured" ]]; then
    test -d "$configured"
    printf '%s\n' "$configured"
    return
  fi
  local candidate
  for candidate in "$@"; do
    if [[ -d "$candidate/.git" ]]; then
      printf '%s\n' "$candidate"
      return
    fi
  done
  return 1
}

foundation_root="$(resolve_checkout "${UX_FOUNDATION_ROOT:-}" \
  "$repo_root/UX-foundation.nvim" \
  "$(dirname "$repo_root")/UX-foundation.nvim" \
  "/home/ai/ux-foundation")" || {
    echo "UX Foundation checkout not found; set UX_FOUNDATION_ROOT" >&2
    exit 1
  }
styling_root="$(resolve_checkout "${UX_STYLING_ROOT:-}" \
  "$repo_root/UX-styling.nvim" \
  "$(dirname "$repo_root")/UX-styling.nvim" \
  "/home/ai/ux-styling")" || {
    echo "UX Styling checkout not found; set UX_STYLING_ROOT" >&2
    exit 1
  }
chrome_root="$(resolve_checkout "${UX_CHROME_ROOT:-}" \
  "$repo_root/UX-chrome.nvim" \
  "$(dirname "$repo_root")/UX-chrome.nvim" \
  "/home/ai/ux-chrome")" || {
    echo "UX Chrome checkout not found; set UX_CHROME_ROOT" >&2
    exit 1
  }

require_pin() {
  local checkout="$1"
  local pin="$2"
  local label="$3"
  if ! git -C "$checkout" cat-file -e "$pin^{commit}" 2>/dev/null \
    || ! git -C "$checkout" merge-base --is-ancestor "$pin" HEAD; then
    echo "$label checkout does not contain required promoted pin $pin" >&2
    exit 1
  fi
}

require_pin "$foundation_root" "$UX_FOUNDATION_PIN" "UX Foundation"
require_pin "$styling_root" "$UX_STYLING_PIN" "UX Styling"
require_pin "$chrome_root" "$UX_CHROME_PIN" "UX Chrome"

nvim --headless --clean \
  -l "$foundation_root/scripts/validate-manifest.lua" \
  "$repo_root/lua/agent_manager/presentation.lua"

common_env=(
  "AGENT_MANAGER_TEST_ROOT=$repo_root"
  "UX_FOUNDATION_ROOT=$foundation_root"
  "UX_STYLING_ROOT=$styling_root"
  "UX_CHROME_ROOT=$chrome_root"
)

env "${common_env[@]}" nvim --headless -u NONE -i NONE \
  -l "$repo_root/tests/lua/m3_foundation.lua"
env "${common_env[@]}" nvim --headless -u NONE -i NONE \
  -l "$repo_root/tests/lua/m3_styling.lua"
env "${common_env[@]}" nvim --headless -u NONE -i NONE \
  -l "$repo_root/tests/lua/m3_chrome.lua"
