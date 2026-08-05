#!/usr/bin/env bash
# A pre-build failure must remain non-zero even though the wrapper tees output.
set -euo pipefail

repo_root=$(git rev-parse --show-toplevel)
runtime=$(mktemp -d /tmp/lmm-missing-routes-wrapper-test.XXXXXX)
cleanup() { rm -rf "$runtime"; }
trap cleanup EXIT

log_dir="$runtime/log"
if LMM_MISSING_ROUTES_RUNTIME_BASE="$runtime/absent" \
  LMM_MISSING_ROUTES_LOG_DIR="$log_dir" \
  "$repo_root/apps/api-rust/tests/behavior-oracle/run-missing-routes-local-listeners.sh"; then
  echo "missing-routes wrapper converted a failing runner into success" >&2
  exit 1
fi

grep -Fq 'runtime base does not exist:' "$log_dir/run.log"
