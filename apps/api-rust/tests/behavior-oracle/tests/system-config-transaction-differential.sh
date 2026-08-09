#!/usr/bin/env bash
# Isolated real-TCP differential for the fourteen system-config/setup routes.
#
# This runner intentionally has no remote gateway inputs: project-update and
# Waffo paths are represented only by the test-instance's injected loopback
# deny fixtures.  It proves the PostgreSQL/Valkey/runtime-write boundary and
# must fail rather than treating a deny-only candidate as parity.
set -euo pipefail

repo_root=$(git rev-parse --show-toplevel)
legacy_revision=5418ce6b6d45ed69167b0aad53f2f595e5bc8de9
legacy_root=${LMM_GO_ORACLE_ROOT:-}
[[ -n $legacy_root ]] || { echo "LMM_GO_ORACLE_ROOT is required; set it to an absolute external immutable Go oracle tree ($legacy_revision)" >&2; exit 2; }
[[ $legacy_root == /* && -d $legacy_root && ! -L $legacy_root ]] || { echo 'LMM_GO_ORACLE_ROOT must be an absolute, non-symlink directory' >&2; exit 2; }
legacy_root=$(realpath -e -- "$legacy_root")
case "$legacy_root" in "$repo_root"|"$repo_root"/*) echo 'LMM_GO_ORACLE_ROOT must be external to the current repository' >&2; exit 2 ;; esac
runtime_base=${LMM_SYSTEM_CONFIG_RUNTIME_BASE:-/tmp}
pg_port=${LMM_SYSTEM_CONFIG_PG_PORT:-55468}
go_port=${LMM_SYSTEM_CONFIG_GO_PORT:-13038}
rust_port=${LMM_SYSTEM_CONFIG_RUST_PORT:-33068}
valkey_requested_port=${LMM_SYSTEM_CONFIG_VALKEY_PORT:-6381}
runtime=$(mktemp -d "$runtime_base/lmm-system-config-differential.XXXXXX")
cargo_target=${LMM_SYSTEM_CONFIG_CARGO_TARGET_DIR:-"$runtime/cargo-target"}
rust_binary=${LMM_SYSTEM_CONFIG_RUST_BINARY:-"$cargo_target/debug/lmm-api-rs"}
go_schema=lmm_test_system_config_go
rust_schema=lmm_test_system_config_rust
go_role=lmm_test_system_config_go
rust_role=lmm_test_system_config_rust
database=lmm_test_system_config
valkey_password=$(openssl rand -hex 32)
go_pid=
rust_pid=
valkey_pid=
go_pid_start=
rust_pid_start=
valkey_pid_start=

cleanup() {
  for pid_name in go_pid rust_pid valkey_pid; do
    stop_owned_process "$pid_name" || true
  done
  if [[ -d $runtime/pg ]]; then
    pg_ctl -D "$runtime/pg" -m fast -w stop >/dev/null 2>&1 || true
  fi
  case "$runtime" in
    "$runtime_base"/lmm-system-config-differential.*) rm -rf "$runtime" ;;
    *) echo "refusing unexpected runtime cleanup target: $runtime" >&2 ;;
  esac
}
trap cleanup EXIT INT TERM

for command in cargo createdb curl git go initdb jq openssl pg_ctl postgres psql ss valkey-cli valkey-server; do
  command -v "$command" >/dev/null || { echo "required command unavailable: $command" >&2; exit 127; }
done
[[ $(postgres --version) == *"PostgreSQL) 18."* ]] || { echo "requires PostgreSQL 18" >&2; exit 1; }
[[ -d $legacy_root ]] || { echo "missing frozen Go source: $legacy_root" >&2; exit 1; }
[[ -d $runtime_base && -w $runtime_base ]] || { echo "runtime base is not writable: $runtime_base" >&2; exit 1; }
pid_start_time() { [[ -r /proc/$1/stat ]] || return 1; awk '{print $22}' "/proc/$1/stat"; }
record_pid() { local pid_name=$1 pid=$2 start; printf -v "$pid_name" '%s' "$pid"; start=$(pid_start_time "$pid") || { echo "failed to record pid $pid" >&2; wait "$pid" 2>/dev/null || true; printf -v "$pid_name" ''; printf -v "${pid_name}_start" ''; return 1; }; printf -v "${pid_name}_start" '%s' "$start"; }
owned_pid_is_live() { local pid_name=$1 pid start_name expected; pid=${!pid_name:-}; start_name="${pid_name}_start"; expected=${!start_name:-}; [[ -n $pid && -n $expected ]] && kill -0 "$pid" 2>/dev/null && [[ $(pid_start_time "$pid" 2>/dev/null || true) == "$expected" ]]; }
stop_owned_process() { local pid_name=$1 pid; pid=${!pid_name:-}; if [[ -n $pid ]]; then if owned_pid_is_live "$pid_name"; then kill "$pid" 2>/dev/null || true; wait "$pid" 2>/dev/null || true; else echo "refusing to signal unowned or recycled PID $pid ($pid_name)" >&2; fi; fi; printf -v "$pid_name" ''; printf -v "${pid_name}_start" ''; }
port_free() { [[ -z $(ss -H -ltn "sport = :$1" 2>/dev/null) ]]; }
random_free_port() { local p; while :; do p=$((20000 + 0x$(od -An -N2 -tx2 /dev/urandom | tr -d ' ') % 35000)); [[ -z $(ss -H -ltn "sport = :$p" 2>/dev/null) ]] && { echo "$p"; return; }; done; }
select_unused_port() {
  local requested=$1 label=$2 candidate
  if port_free "$requested"; then echo "$requested"; return 0; fi
  echo "requested $label port $requested is occupied, selecting a free port" >&2
  for _ in {1..200}; do
    candidate=$(random_free_port)
    if port_free "$candidate"; then echo "$candidate"; return 0; fi
  done
  return 1
}
for entry in \
  "postgres:$pg_port" "go:$go_port" "rust:$rust_port"; do
  name=${entry%%:*}; port=${entry##*:}
  if ss -ltn "sport = :$port" | grep -q LISTEN; then
    echo "refusing occupied $name port: $port" >&2
    exit 1
  fi
done
valkey_port=$(select_unused_port "$valkey_requested_port" system-config-valkey) || { echo "unable to allocate an unused valkey port" >&2; exit 1; }
[[ $valkey_port == "$valkey_requested_port" ]] || echo "using fallback valkey port: $valkey_port" >&2

wait_for_pid_http() {
  local pid=$1 port=$2 path=$3
  for _ in {1..300}; do
    kill -0 "$pid" 2>/dev/null || return 1
    curl --silent --output /dev/null "http://127.0.0.1:$port$path" && return 0
    sleep 0.05
  done
  return 1
}

admin_sql() {
  psql -h 127.0.0.1 -p "$pg_port" -d "$database" -qAt -v ON_ERROR_STOP=1 -c "$1"
}

schema_sql() {
  local engine=$1 statement=$2 schema role
  case "$engine" in
    go) schema=$go_schema; role=$go_role ;;
    rust) schema=$rust_schema; role=$rust_role ;;
    *) return 2 ;;
  esac
  PGOPTIONS="-c search_path=$schema" \
    psql -h 127.0.0.1 -p "$pg_port" -U "$role" -d "$database" -qAt -v ON_ERROR_STOP=1 -c "$statement"
}

start_listeners() {
  local go_dsn rust_dsn
  go_dsn="postgresql://$go_role@127.0.0.1:$pg_port/$database?sslmode=disable&options=-csearch_path=$go_schema"
  rust_dsn="postgresql://$rust_role@127.0.0.1:$pg_port/$database?options=-csearch_path=$rust_schema"
  SQL_DSN="$go_dsn" PORT="$go_port" REDIS_CONN_STRING="redis://:$valkey_password@127.0.0.1:$valkey_port/5" \
    SESSION_SECRET='SystemConfigOracle-2026-SyntheticOnly' CRYPTO_SECRET='SystemConfigOracle-Crypto-SyntheticOnly' \
    PASSWORD_LOGIN_ENABLED=true GLOBAL_API_RATE_LIMIT_ENABLE=false CRITICAL_RATE_LIMIT_ENABLE=false GIN_MODE=release \
    "$runtime/go-build/legacy-go" >"$runtime/go.log" 2>&1 & record_pid go_pid "$!" || exit 1
  wait_for_pid_http "$go_pid" "$go_port" /api/status || { sed -n '1,220p' "$runtime/go.log" >&2; return 1; }
  LMM_RS_TEST_INSTANCE=1 LMM_RS_SLOT=blue LMM_RS_LISTEN_ADDR="127.0.0.1:$rust_port" \
    DATABASE_URL="$rust_dsn" VALKEY_URL="redis://:$valkey_password@127.0.0.1:$valkey_port/6" LMM_SCHEMA_CONTRACT=1 \
    SESSION_SECRET='SystemConfigOracle-2026-SyntheticOnly' CRYPTO_SECRET='SystemConfigOracle-Crypto-SyntheticOnly' \
    PASSWORD_LOGIN_ENABLED=true GLOBAL_API_RATE_LIMIT_ENABLE=false CRITICAL_RATE_LIMIT_ENABLE=false TRUSTED_PROXIES=none VERSION=v0.0.0 \
    "$rust_binary" >"$runtime/rust.log" 2>&1 & record_pid rust_pid "$!" || exit 1
  wait_for_pid_http "$rust_pid" "$rust_port" /readyz || { sed -n '1,220p' "$runtime/rust.log" >&2; return 1; }
}

call() {
  local engine=$1 name=$2 method=$3 path=$4 body=${5:-} token=${6:-} port prefix
  [[ $engine == go ]] && port=$go_port || port=$rust_port
  prefix="$runtime/$engine.$name"
  local args=(--silent --show-error --dump-header "$prefix.headers" --output "$prefix.body" --write-out '%{http_code}' --request "$method")
  [[ -z $token ]] || args+=(--header "authorization: Bearer $token")
  [[ -z $body ]] || args+=(--header 'content-type: application/json' --data-binary "$body")
  curl "${args[@]}" "http://127.0.0.1:$port$path" >"$prefix.status"
  jq -e . <"$prefix.body" >/dev/null
}

pair() {
  local name=$1 method=$2 path=$3 body=${4:-} token_go=${5:-} token_rust=${6:-}
  call go "$name" "$method" "$path" "$body" "$token_go"
  call rust "$name" "$method" "$path" "$body" "$token_rust"
  diff -u "$runtime/go.$name.status" "$runtime/rust.$name.status"
  diff -u <(jq -S . <"$runtime/go.$name.body") <(jq -S . <"$runtime/rust.$name.body")
}

login() {
  local engine=$1 port
  [[ $engine == go ]] && port=$go_port || port=$rust_port
  curl --silent --show-error --header 'content-type: application/json' \
    --data '{"username":"root","password":"password"}' "http://127.0.0.1:$port/api/user/login" |
    jq -er 'select(.success == true) | .data.access_token | strings'
}

mkdir -p "$runtime/go-build/go-source"
cp -a "$legacy_root/." "$runtime/go-build/go-source"
mkdir -p "$runtime/go-build/go-source/web/dist"
: >"$runtime/go-build/go-source/web/dist/index.html"
TMPDIR="$runtime" CARGO_TARGET_DIR="$cargo_target" cargo build --manifest-path "$repo_root/apps/api-rust/Cargo.toml" -p lmm-api-rs --locked
[[ -x $rust_binary ]] || { echo "Rust test-instance binary unavailable: $rust_binary" >&2; exit 1; }
(cd "$runtime/go-build/go-source" && GOTOOLCHAIN=local CGO_ENABLED=1 go build -buildvcs=false -o "$runtime/go-build/legacy-go" .)

initdb --no-locale --encoding=UTF8 --auth=trust -D "$runtime/pg" >/dev/null
pg_ctl -D "$runtime/pg" -l "$runtime/postgres.log" -o "-h 127.0.0.1 -p $pg_port -k $runtime" -w start >/dev/null
createdb -h 127.0.0.1 -p "$pg_port" "$database"
admin_sql "CREATE ROLE $go_role LOGIN; CREATE ROLE $rust_role LOGIN; CREATE SCHEMA $go_schema; CREATE SCHEMA $rust_schema;"
for schema in "$go_schema" "$rust_schema"; do
  sed "s/public\\./$schema./g" "$repo_root/apps/api-rust/crates/lmm-db-migrate/schema/postgresql-baseline.sql" >"$runtime/$schema.sql"
  PGOPTIONS="-c search_path=$schema" psql -h 127.0.0.1 -p "$pg_port" -d "$database" -q -v ON_ERROR_STOP=1 -f "$runtime/$schema.sql" >/dev/null
  admin_sql "CREATE TABLE $schema.lmm_schema_contract (singleton BOOLEAN PRIMARY KEY, min_reader_version BIGINT NOT NULL, max_reader_version BIGINT NOT NULL); INSERT INTO $schema.lmm_schema_contract VALUES(TRUE,1,1);"
done
# Explicit ownership is required because each listener runs an isolated schema.
for pair_value in "$go_schema:$go_role" "$rust_schema:$rust_role"; do
  schema=${pair_value%%:*}; role=${pair_value##*:}
  admin_sql "DO \$\$ DECLARE r record; BEGIN FOR r IN SELECT c.relkind,c.relname FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace WHERE n.nspname='$schema' AND c.relkind IN ('r','S') LOOP EXECUTE format('ALTER %s %I OWNER TO $role', CASE WHEN r.relkind='S' THEN 'SEQUENCE' ELSE 'TABLE' END, r.relname); END LOOP; END \$\$; ALTER SCHEMA $schema OWNER TO $role;"
done
valkey-server --bind 127.0.0.1 --port "$valkey_port" --requirepass "$valkey_password" --save '' --appendonly no --dir "$runtime" --logfile "$runtime/valkey.log" > /dev/null 2>&1 & record_pid valkey_pid "$!" || exit 1
for _ in {1..100}; do
  kill -0 "$valkey_pid" 2>/dev/null || { sed -n '1,220p' "$runtime/valkey.log" >&2; exit 1; }
  valkey-cli -h 127.0.0.1 -p "$valkey_port" --pass "$valkey_password" ping >/dev/null 2>&1 && break
  sleep 0.05
done
valkey-cli -h 127.0.0.1 -p "$valkey_port" --pass "$valkey_password" ping >/dev/null

for engine in go rust; do
  schema_sql "$engine" "INSERT INTO users (id,username,password,display_name,role,status,\"group\",setting,auth_version,quota,aff_quota) VALUES (1,'root','\$2a\$10\$5Rm09lSOGBsP.6RiFTuleun103cKGxh/grNS/rcy7HPxJDvY9EEt2','Root User',100,1,'default','{}',1,100000000,0);"
done
start_listeners
pair setup-public GET /api/setup
go_token=$(login go)
rust_token=$(login rust)
# This assertion deliberately exposes an incomplete migration: until listener
# composition supplies SystemConfigRuntimeWriter, Rust must reject the write
# rather than persist a value that no live runtime will consume.
pair runtime-write-boundary PUT /api/option/ '{"key":"SystemConfigOracleProbe","value":"after"}' "$go_token" "$rust_token"
