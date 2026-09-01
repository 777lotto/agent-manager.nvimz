#!/usr/bin/env bash
set -euo pipefail

expected_version="codex-cli 0.152.0"
actual_version="$(codex --version)"
if [[ "$actual_version" != "$expected_version" ]]; then
  echo "expected $expected_version, found $actual_version" >&2
  exit 1
fi

repo_root="$(git rev-parse --show-toplevel)"
destination="$repo_root/protocol/vendor/codex/0.152.0"
generated="$(mktemp -d)"
trap 'rm -rf -- "$generated"' EXIT

codex app-server generate-json-schema --out "$generated"
mkdir -p "$destination/v1"

files=(
  ClientRequest.json
  ServerNotification.json
  ServerRequest.json
  CommandExecutionRequestApprovalParams.json
  CommandExecutionRequestApprovalResponse.json
  FileChangeRequestApprovalParams.json
  FileChangeRequestApprovalResponse.json
  PermissionsRequestApprovalParams.json
  PermissionsRequestApprovalResponse.json
  ToolRequestUserInputParams.json
  ToolRequestUserInputResponse.json
  codex_app_server_protocol.schemas.json
  v1/InitializeParams.json
  v1/InitializeResponse.json
)

for relative_path in "${files[@]}"; do
  install -m 0644 "$generated/$relative_path" "$destination/$relative_path"
done

(
  cd "$destination"
  sha256sum "${files[@]}" > SHA256SUMS
)

echo "updated Codex App Server schemas for 0.152.0"
