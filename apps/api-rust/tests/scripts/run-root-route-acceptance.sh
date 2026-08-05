#!/usr/bin/env bash
set -euo pipefail

repo_root=$(git rev-parse --show-toplevel)
manifest="$repo_root/apps/api-rust/tests/root-route-acceptance/Cargo.toml"
target_dir=${CARGO_TARGET_DIR:-"$repo_root/apps/api-rust/target/root-route-acceptance"}

[[ -f $manifest ]] || {
  echo "missing root-route acceptance manifest: $manifest" >&2
  exit 1
}

CARGO_TARGET_DIR="$target_dir" cargo run --offline --locked \
  --manifest-path "$manifest" --features runtime
