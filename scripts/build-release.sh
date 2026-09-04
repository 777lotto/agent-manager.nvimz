#!/usr/bin/env bash
set -euo pipefail

repo_root="$(git rev-parse --show-toplevel)"
output_dir="${1:-$repo_root/dist}"
target="x86_64-unknown-linux-gnu"
compatibility="$repo_root/release/compatibility-v1.json"
metadata="$repo_root/scripts/release_metadata.py"
python_dir="$repo_root/python"
python_bin="$python_dir/.venv/bin/python"
python_version=3.13
build_stage="initialization"

fail() {
  printf 'release build: %s\n' "$1" >&2
  if test "${GITHUB_ACTIONS:-}" = true; then
    printf '::error title=Release build failed::%s: %s\n' "$build_stage" "$1"
  fi
  exit 1
}

report_failure() {
  status="$?"
  trap - ERR
  if test "${GITHUB_ACTIONS:-}" = true; then
    printf '::error title=Release build failed::%s (exit %s)\n' \
      "$build_stage" "$status"
  fi
  exit "$status"
}
trap report_failure ERR

build_stage="pinned toolchain and metadata preflight"
test -f "$compatibility" || fail "compatibility metadata is missing"
test -x "$python_bin" || fail "run mise run setup before building a release"
test "$($python_bin --version)" = "Python 3.13.15" || fail "release Python must be 3.13.15"
case "$(rustc --version)" in
  "rustc 1.98.0 "*) ;;
  *) fail "release Rust must be 1.98.0" ;;
esac
case "$(uv --version)" in
  "uv 0.12.7 (x86_64-unknown-linux-gnu)" | \
    "uv 0.12.7 (x86_64-unknown-linux-musl)") ;;
  *) fail "release uv must be 0.12.7 for x86_64 Linux" ;;
esac
test "$(uname -s)" = Linux || fail "the release target is Linux"
test "$(uname -m)" = x86_64 || fail "the release target is x86_64"

build_stage="source revision validation"
source_revision="${RELEASE_SOURCE_REVISION:-$(git -C "$repo_root" rev-parse HEAD)}"
source_date_epoch="${SOURCE_DATE_EPOCH:-$(git -C "$repo_root" show -s --format=%ct "$source_revision")}"
source_dirty=0
if ! git -C "$repo_root" diff --quiet --ignore-submodules -- \
  || ! git -C "$repo_root" diff --cached --quiet --ignore-submodules -- \
  || test -n "$(git -C "$repo_root" ls-files --others --exclude-standard)"; then
  source_dirty=1
fi
if test "$source_dirty" = 1 && test "${RELEASE_ALLOW_DIRTY:-0}" != 1; then
  fail "the release source is dirty (set RELEASE_ALLOW_DIRTY=1 only for local reproducibility tests)"
fi

version="$($python_bin -c 'import json,sys; print(json.load(open(sys.argv[1], encoding="utf-8"))["release_version"])' "$compatibility")"
bundle_name="agent-manager-v${version}-${target}"
archive="$output_dir/$bundle_name.tar.gz"
checksums="$output_dir/SHA256SUMS"
test ! -e "$archive" || fail "refusing to overwrite $archive"
test ! -e "$checksums" || fail "refusing to overwrite $checksums"

build_stage="temporary release tree setup"
temporary="$(mktemp -d)"
cleanup() {
  if test -d "$temporary"; then
    find "$temporary" -depth -delete
  fi
}
trap cleanup EXIT
stage="$temporary/$bundle_name"
runtime_site_packages="$stage/python/lib/python${python_version}/site-packages"
mkdir -p "$stage/bin" "$stage/python/bin" "$runtime_site_packages" \
  "$stage/python/wheels" "$output_dir"

export SOURCE_DATE_EPOCH="$source_date_epoch"
export CARGO_INCREMENTAL=0
export CARGO_PROFILE_RELEASE_INCREMENTAL=false
export RUSTFLAGS="--remap-path-prefix=$repo_root=/usr/src/agent-manager -C link-arg=-Wl,--build-id=none"
export UV_LINK_MODE=copy
export UV_PYTHON_DOWNLOADS=never

build_stage="Rust broker build"
cargo_target="$temporary/cargo-target"
CARGO_TARGET_DIR="$cargo_target" cargo build \
  --locked \
  --release \
  --target "$target" \
  --package agent-manager-broker
install -m 0755 \
  "$cargo_target/$target/release/agent-manager-broker" \
  "$stage/bin/agent-manager-broker"

# Ship the exact interpreter with the worker. Neovim and the installer never
# need to create a venv or resolve Python dependencies on the destination
# machine; Python discovers this relocatable prefix from python/bin/python.
build_stage="relocatable Python runtime assembly"
python_base="$($python_bin -I -c 'import sys; print(sys.base_prefix)')"
test "${python_base:0:1}" = / || fail "Python base prefix must be absolute"
test -x "$python_base/bin/python3.13" || fail "Python base interpreter is missing"
test -d "$python_base/lib/python${python_version}" || fail "Python standard library is missing"
install -m 0755 "$python_base/bin/python3.13" "$stage/python/bin/python"
cp -a "$python_base/lib/python${python_version}/." "$stage/python/lib/python${python_version}/"
find "$stage/python/lib/python${python_version}/site-packages" -mindepth 1 -depth -delete
find "$stage/python/lib/python${python_version}" -depth \
  \( -type d -name __pycache__ -o -type f -name '*.pyc' \) -delete

build_stage="Claude worker wheel build"
wheel_dir="$temporary/wheels"
mkdir -p "$wheel_dir"
uv build \
  --wheel \
  --no-build-isolation \
  --python "$python_bin" \
  --out-dir "$wheel_dir" \
  --clear \
  "$python_dir"
worker_wheel="$(find "$wheel_dir" -maxdepth 1 -type f -name 'agent_manager_claude_worker-*.whl' -print)"
test -n "$worker_wheel" || fail "the worker wheel was not produced"
install -m 0644 "$worker_wheel" "$stage/python/wheels/$(basename "$worker_wheel")"

build_stage="locked worker dependency installation"
uv export \
  --quiet \
  --directory "$python_dir" \
  --frozen \
  --no-dev \
  --no-emit-project \
  --no-annotate \
  --no-header \
  --output-file "$stage/python/requirements.lock"
uv pip install \
  --python "$python_bin" \
  --python-version 3.13.15 \
  --python-platform "$target" \
  --target "$runtime_site_packages" \
  --require-hashes \
  --only-binary :all: \
  --requirements "$stage/python/requirements.lock"
rm -f -- "$runtime_site_packages/.lock"
"$python_bin" -m zipfile -e "$worker_wheel" "$runtime_site_packages"
build_stage="self-contained worker import check"
"$stage/python/bin/python" -B -I -c \
  'import agent_manager_claude_worker, claude_agent_sdk'

build_stage="release manifest and archive generation"
install -m 0644 "$compatibility" "$stage/compatibility-v1.json"
install -m 0644 "$repo_root/LICENSE" "$stage/LICENSE"
"$python_bin" "$metadata" checksums --root "$stage"
manifest_args=(
  manifest
  --repository "$repo_root"
  --root "$stage"
  --broker "$stage/bin/agent-manager-broker"
  --source-revision "$source_revision"
  --source-date-epoch "$source_date_epoch"
  --target "$target"
)
if test "$source_dirty" = 1; then
  manifest_args+=(--source-dirty)
fi
"$python_bin" "$metadata" "${manifest_args[@]}"
"$python_bin" "$metadata" verify-tree \
  --root "$stage" \
  --version "$version" \
  --target "$target"
"$python_bin" "$metadata" archive \
  --root "$stage" \
  --output "$archive" \
  --epoch "$source_date_epoch"
archive_hash="$(sha256sum "$archive" | cut -d ' ' -f 1)"
printf '%s  %s\n' "$archive_hash" "$(basename "$archive")" >"$checksums"
"$python_bin" "$metadata" verify-archive \
  --archive "$archive" \
  --checksum-file "$checksums" \
  --expected-root "$bundle_name" \
  --version "$version" \
  --target "$target"

printf 'release build: %s\n' "$archive"
printf 'release build: %s\n' "$checksums"
