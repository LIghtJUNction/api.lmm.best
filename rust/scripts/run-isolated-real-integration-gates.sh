#!/usr/bin/env bash
# Starts disposable loopback-only PostgreSQL 18 and Valkey instances, then
# delegates to the ignored real-integration test runner.  It deliberately has
# no production-service discovery, no shared data directory, and no defaults
# that could target a non-loopback endpoint.
set -euo pipefail

repo_root=$(git rev-parse --show-toplevel)
runner="$repo_root/rust/scripts/run-real-integration-gates.sh"
suite=${1:-all}
tmp_base=${TMPDIR:-/tmp}
runtime=
pg_pid=
valkey_pid=

usage() {
  echo "usage: $0 {auth|models|api-token|all}" >&2
  exit 2
}

case "$suite" in
  auth|models|api-token|all) ;;
  *) usage ;;
esac

require_command() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "missing required command: $1" >&2
    exit 1
  }
}

for command_name in initdb postgres psql valkey-server valkey-cli ss mktemp od; do
  require_command "$command_name"
done
[[ -x $runner || -f $runner ]] || {
  echo "missing integration runner: $runner" >&2
  exit 1
}

port_is_unused() {
  local port=$1
  ! ss -H -ltn "sport = :$port" | grep -q . \
    && ! ss -H -lun "sport = :$port" | grep -q .
}

random_port() {
  local candidate attempts=0
  while (( attempts < 128 )); do
    candidate=$((20000 + (16#$(od -An -N2 -tx2 /dev/urandom | tr -d ' ') % 30000)))
    if port_is_unused "$candidate"; then
      printf '%s\n' "$candidate"
      return 0
    fi
    ((attempts += 1))
  done
  echo "could not reserve an unused local port after 128 attempts" >&2
  return 1
}

stop_pid() {
  local pid=$1
  [[ $pid =~ ^[0-9]+$ ]] || return 0
  kill -0 "$pid" 2>/dev/null || return 0
  kill -TERM "$pid" 2>/dev/null || return 0
  for _ in {1..100}; do
    if ! kill -0 "$pid" 2>/dev/null; then
      wait "$pid" 2>/dev/null || true
      return 0
    fi
    sleep 0.05
  done
  kill -KILL "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
}

listener_belongs_to_pid() {
  local port=$1 pid=$2
  ss -H -ltnp "sport = :$port" 2>/dev/null | grep -Eq "pid=$pid([,)]|$)"
}

safe_runtime_dir() {
  [[ -n $runtime && -d $runtime ]] || return 1
  case "$runtime" in
    "$tmp_base"/lmm-real-integration.*) ;;
    *) return 1 ;;
  esac
}

cleanup() {
  local exit_status=$?
  stop_pid "$valkey_pid"
  valkey_pid=
  stop_pid "$pg_pid"
  pg_pid=
  if safe_runtime_dir; then
    rm -rf -- "$runtime"
  else
    echo "refusing to remove unexpected integration runtime directory" >&2
  fi
  exit "$exit_status"
}

trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

wait_for_postgres() {
  local port=$1
  for _ in {1..200}; do
    if psql "postgresql://127.0.0.1:$port/postgres" -Atqc 'SELECT 1' >/dev/null 2>&1; then
      return 0
    fi
    kill -0 "$pg_pid" 2>/dev/null || return 1
    sleep 0.05
  done
  return 1
}

wait_for_valkey() {
  local port=$1
  for _ in {1..200}; do
    if VALKEYCLI_AUTH="$valkey_password" valkey-cli --no-auth-warning -h 127.0.0.1 -p "$port" ping 2>/dev/null | grep -qx PONG; then
      return 0
    fi
    kill -0 "$valkey_pid" 2>/dev/null || return 1
    sleep 0.05
  done
  return 1
}

tail_startup_log() {
  local log_file=$1
  [[ -f $log_file ]] || return 0
  tail -n 80 -- "$log_file" >&2
}

umask 077
runtime=$(mktemp -d "$tmp_base/lmm-real-integration.XXXXXX")
pg_port=$(random_port)
valkey_port=$(random_port)
while [[ $valkey_port == "$pg_port" ]]; do
  valkey_port=$(random_port)
done
valkey_password=$(od -An -N32 -tx1 /dev/urandom | tr -d '[:space:]')
[[ ${#valkey_password} == 64 ]] || {
  echo "failed to generate Valkey secret" >&2
  exit 1
}

pgdata="$runtime/postgres"
valkey_config="$runtime/valkey.conf"
initdb --auth-local=trust --auth-host=trust --no-locale --encoding=UTF8 -D "$pgdata" >/dev/null
port_is_unused "$pg_port" || {
  echo "isolated PostgreSQL port became unavailable before startup" >&2
  exit 1
}
postgres -D "$pgdata" -h 127.0.0.1 -p "$pg_port" -k "$runtime" >"$runtime/postgres.log" 2>&1 &
pg_pid=$!
wait_for_postgres "$pg_port" || {
  echo "isolated PostgreSQL did not become ready" >&2
  tail_startup_log "$runtime/postgres.log"
  exit 1
}
listener_belongs_to_pid "$pg_port" "$pg_pid" || {
  echo "isolated PostgreSQL listener ownership check failed" >&2
  exit 1
}
for database in lmm_auth lmm_models lmm_api_token; do
  psql "postgresql://127.0.0.1:$pg_port/postgres" -v ON_ERROR_STOP=1 -qc "CREATE DATABASE $database" >/dev/null
done

printf '%s\n' \
  'bind 127.0.0.1' \
  "port $valkey_port" \
  'protected-mode yes' \
  'save ""' \
  'appendonly no' \
  "requirepass $valkey_password" \
  >"$valkey_config"
chmod 600 "$valkey_config"
port_is_unused "$valkey_port" || {
  echo "isolated Valkey port became unavailable before startup" >&2
  exit 1
}
valkey-server "$valkey_config" >"$runtime/valkey.log" 2>&1 &
valkey_pid=$!
wait_for_valkey "$valkey_port" || {
  echo "isolated Valkey did not become ready" >&2
  tail_startup_log "$runtime/valkey.log"
  exit 1
}
listener_belongs_to_pid "$valkey_port" "$valkey_pid" || {
  echo "isolated Valkey listener ownership check failed" >&2
  exit 1
}

export LMM_AUTH_TEST_ALLOW_SCHEMA_RESET=1
export LMM_AUTH_TEST_DATABASE_URL="postgresql://127.0.0.1:$pg_port/lmm_auth"
export LMM_AUTH_TEST_VALKEY_URL="redis://:$valkey_password@127.0.0.1:$valkey_port"
export LMM_MODELS_TEST_DATABASE_URL="postgresql://127.0.0.1:$pg_port/lmm_models"
export LMM_MODELS_TEST_VALKEY_URL="redis://:$valkey_password@127.0.0.1:$valkey_port"
export LMM_API_TOKEN_TEST_DATABASE_URL="postgresql://127.0.0.1:$pg_port/lmm_api_token"
export LMM_API_TOKEN_TEST_VALKEY_URL="redis://:$valkey_password@127.0.0.1:$valkey_port"

bash "$runner" "$suite"
