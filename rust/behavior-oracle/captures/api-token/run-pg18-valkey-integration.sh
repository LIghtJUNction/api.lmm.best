#!/usr/bin/env bash
# Runs the API-token candidate against disposable PostgreSQL 18 and Valkey.
# This is intentionally native-process based, matching the repository's other
# real-listener gates; no container runtime or network service is required.
set -euo pipefail

repo_root=$(git rev-parse --show-toplevel)
runtime=$(mktemp -d /tmp/lmm-api-token-pg18.XXXXXX)
pg_port=${LMM_API_TOKEN_TEST_PG_PORT:-55455}
valkey_port=${LMM_API_TOKEN_TEST_VALKEY_PORT:-56385}

cleanup() {
  valkey-cli -h 127.0.0.1 -p "$valkey_port" shutdown nosave >/dev/null 2>&1 || true
  [[ -d $runtime/pg ]] && pg_ctl -D "$runtime/pg" -m fast -w stop >/dev/null 2>&1 || true
  case "$runtime" in
    /tmp/lmm-api-token-pg18.*) rm -rf "$runtime" ;;
    *) echo "refusing to remove unexpected runtime: $runtime" >&2 ;;
  esac
}
trap cleanup EXIT INT TERM

for command in cargo createdb initdb pg_ctl postgres psql valkey-cli valkey-server; do
  command -v "$command" >/dev/null || { echo "required command is unavailable: $command" >&2; exit 1; }
done
[[ $(postgres --version) == *"PostgreSQL) 18."* ]] || {
  echo "API-token integration requires PostgreSQL 18" >&2
  exit 1
}

initdb --no-locale --encoding=UTF8 --auth=trust -D "$runtime/pg" >/dev/null
pg_ctl -D "$runtime/pg" -l "$runtime/postgres.log" \
  -o "-h 127.0.0.1 -p $pg_port -k $runtime" -w start >/dev/null
createdb -h 127.0.0.1 -p "$pg_port" api_token_test
valkey-server --bind 127.0.0.1 --port "$valkey_port" --save '' --appendonly no \
  --daemonize yes --dir "$runtime" --logfile "$runtime/valkey.log"
for _ in {1..100}; do
  valkey-cli -h 127.0.0.1 -p "$valkey_port" ping >/dev/null 2>&1 && break
  sleep .05
done
valkey-cli -h 127.0.0.1 -p "$valkey_port" ping >/dev/null

export LMM_API_TOKEN_TEST_DATABASE_URL="postgresql://127.0.0.1:$pg_port/api_token_test"
export LMM_API_TOKEN_TEST_VALKEY_URL="redis://127.0.0.1:$valkey_port"
cargo test --manifest-path "$repo_root/rust/Cargo.toml" -p lmm-api-rs \
  --test migration_api_token --locked -- --ignored --test-threads=1

jq -cn '{
  test:"api-token-pg18-valkey-integration",
  postgres_major:18,
  real_valkey:true,
  ignored_tests:10,
  cases:[
    "batch-db-fault",
    "cache-hash-ttl-atomic",
    "concurrent-create",
    "delete-replay-concurrency",
    "mixed-case-deleted-at",
    "options-last-good",
    "query-overflow-listener",
    "row-decode-faults",
    "token-limit-owner-scope",
    "update-without-post-select"
  ],
  result:"passed"
}'
