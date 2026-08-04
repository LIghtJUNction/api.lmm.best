#!/usr/bin/env bash
# Preserve the listener differential's exit status while retaining its log.
set -euo pipefail

repo_root=$(git rev-parse --show-toplevel)
runner="$repo_root/apps/api-rust/behavior-oracle/tests/missing-routes-local-listeners.sh"
log_dir=${LMM_MISSING_ROUTES_LOG_DIR:-$(mktemp -d /tmp/lmm-missing-routes-rerun.XXXXXX)}
log_file="$log_dir/run.log"

mkdir -p "$log_dir"
printf 'log_file=%s\n' "$log_file"

if "$runner" 2>&1 | tee "$log_file"; then
  exit 0
else
  status=${PIPESTATUS[0]}
  exit "$status"
fi
