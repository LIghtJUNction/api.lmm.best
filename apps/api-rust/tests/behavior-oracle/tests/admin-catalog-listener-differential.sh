#!/usr/bin/env bash
# Real loopback differential for the administrator catalog read surface.
# The runner owns every process, database, schema, and port it creates.
set -euo pipefail
set +x

repo_root=$(git rev-parse --show-toplevel)
legacy_revision=5418ce6b6d45ed69167b0aad53f2f595e5bc8de9
legacy_root=${LMM_GO_ORACLE_ROOT:-}
[[ -n $legacy_root ]] || { echo "LMM_GO_ORACLE_ROOT is required ($legacy_revision)" >&2; exit 2; }
[[ $legacy_root == /* && -d $legacy_root && ! -L $legacy_root ]] || {
  echo 'LMM_GO_ORACLE_ROOT must be an external non-symlink directory' >&2
  exit 2
}
legacy_root=$(realpath -e -- "$legacy_root")
case "$legacy_root" in
  "$repo_root"|"$repo_root"/*)
    echo 'LMM_GO_ORACLE_ROOT must be external to the repository' >&2
    exit 2
    ;;
esac

runtime=$(mktemp -d /tmp/lmm-admin-catalog-listener.XXXXXX)
go_pid='' rust_pid='' go_valkey_pid='' rust_valkey_pid=''
pg_port=$(shuf -i 20000-60000 -n 1)
go_port=$(shuf -i 20000-60000 -n 1)
rust_port=$(shuf -i 20000-60000 -n 1)
go_valkey_port=$(shuf -i 20000-60000 -n 1)
rust_valkey_port=$(shuf -i 20000-60000 -n 1)
go_valkey_password=$(openssl rand -hex 32)
rust_valkey_password=$(openssl rand -hex 32)
crypto_secret=$(openssl rand -hex 32)
session_secret='AdminCatalogListener-2026!SyntheticSecret'
go_db="$runtime/legacy.db"
rust_db=lmm_test_admin_catalog_rust
rust_role=lmm_test_admin_catalog_runtime
rust_schema=lmm_test_admin_catalog_schema

pid_live() { [[ -n ${1:-} ]] && kill -0 "$1" 2>/dev/null; }
stop_pid() {
  local pid=${1:-}
  pid_live "$pid" && kill "$pid" 2>/dev/null || true
  [[ -n $pid ]] && wait "$pid" 2>/dev/null || true
}
cleanup() {
  local code=$?
  stop_pid "$go_pid"
  stop_pid "$rust_pid"
  stop_pid "$go_valkey_pid"
  stop_pid "$rust_valkey_pid"
  [[ -f "$runtime/pg/postmaster.pid" ]] && pg_ctl -D "$runtime/pg" -m fast -w stop >/dev/null 2>&1 || true
  case "$runtime" in
    /tmp/lmm-admin-catalog-listener.*) rm -rf -- "$runtime" ;;
  esac
  exit "$code"
}
trap cleanup EXIT INT TERM

for command in cargo createdb curl go initdb jq pg_ctl psql sqlite3 valkey-cli valkey-server; do
  command -v "$command" >/dev/null || { echo "required command is unavailable: $command" >&2; exit 1; }
done
for port in "$pg_port" "$go_port" "$rust_port" "$go_valkey_port" "$rust_valkey_port"; do
  [[ -z $(ss -H -ltn "sport = :$port") ]] || { echo "occupied random port: $port" >&2; exit 1; }
done

cp -a "$legacy_root/." "$runtime/go-source"
mkdir -p "$runtime/go-source/web/dist"
: >"$runtime/go-source/web/dist/index.html"
(cd "$runtime/go-source" && GOTOOLCHAIN=local CGO_ENABLED=1 go build -buildvcs=false -o "$runtime/legacy-go" .)

initdb --no-locale --encoding=UTF8 --auth=trust -D "$runtime/pg" >/dev/null
pg_ctl -D "$runtime/pg" -l "$runtime/postgres.log" -o "-h 127.0.0.1 -p $pg_port -k $runtime" -w start >/dev/null
createdb -h 127.0.0.1 -p "$pg_port" "$rust_db"

start_valkey() {
  local name=$1 port=$2 password=$3
  local config="$runtime/$name-valkey.conf"
  umask 077
  printf 'bind 127.0.0.1\nport %s\nprotected-mode yes\nrequirepass %s\nsave ""\nappendonly no\ndaemonize no\ndir %s\nlogfile %s\n' \
    "$port" "$password" "$runtime" "$runtime/$name-valkey.log" >"$config"
  valkey-server "$config" >"$runtime/$name-valkey.stdout" 2>&1 &
  local pid=$!
  if [[ $name == go ]]; then go_valkey_pid=$pid; else rust_valkey_pid=$pid; fi
  for _ in {1..200}; do
    if VALKEYCLI_AUTH="$password" valkey-cli -h 127.0.0.1 -p "$port" ping >/dev/null 2>&1; then return; fi
    sleep .05
  done
  echo "$name Valkey did not become ready" >&2
  exit 1
}
start_valkey go "$go_valkey_port" "$go_valkey_password"
start_valkey rust "$rust_valkey_port" "$rust_valkey_password"

go_env=(SQL_DSN=local SQLITE_PATH="$go_db?_busy_timeout=30000" PORT="$go_port"
  REDIS_CONN_STRING="redis://:$go_valkey_password@127.0.0.1:$go_valkey_port"
  CRYPTO_SECRET="$crypto_secret" SESSION_SECRET="$session_secret"
  PASSWORD_LOGIN_ENABLED=true SYNC_FREQUENCY=60 GLOBAL_API_RATE_LIMIT_ENABLE=false GIN_MODE=release)
env "${go_env[@]}" "$runtime/legacy-go" >"$runtime/go.log" 2>&1 &
go_pid=$!
for _ in {1..300}; do
  [[ -n $(ss -H -ltn "sport = :$go_port") ]] && break
  pid_live "$go_pid" || { tail -n 80 "$runtime/go.log" >&2; exit 1; }
  sleep .05
done
[[ -n $(ss -H -ltn "sport = :$go_port") ]] || { tail -n 80 "$runtime/go.log" >&2; exit 1; }
curl -fsS --max-time 3 "http://127.0.0.1:$go_port/api/status" >/dev/null
kill "$go_pid"
wait "$go_pid" 2>/dev/null || true
go_pid=

# Seed the Go ORM-created schema. All timestamps are fixed so read responses
# can be compared after JSON key sorting.
sqlite3 "$go_db" <<'SQL'
INSERT OR REPLACE INTO options (key,value) VALUES
 ('SelfUseModeEnabled','false'),
 ('ModelRatio','{"fixture-model":1}'),
 ('UserUsableGroups','{"default":"default"}'),
 ('GroupRatio','{"default":1}'),
 ('payment_setting.compliance_confirmed','true'),
 ('payment_setting.compliance_terms_version','v1');
INSERT OR REPLACE INTO users (id,username,password,display_name,role,status,email,quota,"group",setting,auth_version)
 VALUES (42,'admin-catalog-root','$2a$10$5Rm09lSOGBsP.6RiFTuleun103cKGxh/grNS/rcy7HPxJDvY9EEt2','Admin Catalog Root',100,1,'',0,'default','{}',1);
INSERT OR REPLACE INTO vendors (id,name,description,icon,status,created_time,updated_time)
 VALUES (11,'FixtureVendor','','',1,1700000000,1700000001);
INSERT OR REPLACE INTO models (id,model_name,description,icon,tags,vendor_id,endpoints,status,sync_official,created_time,updated_time,name_rule)
 VALUES (21,'fixture-model','','','',11,'',1,1,1700000000,1700000001,0),
        (22,'disabled-model','hidden','','',11,'',0,1,1700000002,1700000003,0);
INSERT OR REPLACE INTO channels (id,type,key,name,status,models,"group")
 VALUES (101,1,'fixture-key','Fixture Channel',1,'fixture-model','default');
INSERT OR REPLACE INTO abilities ("group",model,channel_id,enabled,priority,weight)
 VALUES ('default','fixture-model',101,1,10,10);
INSERT OR REPLACE INTO prefill_groups (id,name,type,items,description,created_time,updated_time)
 VALUES (31,'Fixture Group','model','["fixture-model"]','',1700000004,1700000005);
INSERT OR REPLACE INTO redemptions (id,user_id,key,status,name,quota,created_time,redeemed_time,used_user_id,expired_time)
 VALUES (41,42,'fixture-redemption-0000000000000',1,'Fixture',100,1700000006,0,0,0);
SQL

# Use the frozen PostgreSQL baseline, then isolate it behind a test-only role,
# schema contract, and search_path. The names satisfy the Rust validator.
psql -h 127.0.0.1 -p "$pg_port" -d "$rust_db" -v ON_ERROR_STOP=1 <<SQL >/dev/null
CREATE ROLE $rust_role LOGIN;
CREATE SCHEMA $rust_schema AUTHORIZATION $rust_role;
SQL
sed "s/public\\./$rust_schema./g" "$repo_root/apps/api-rust/crates/lmm-db-migrate/schema/postgresql-baseline.sql" >"$runtime/baseline.sql"
psql -h 127.0.0.1 -p "$pg_port" -d "$rust_db" -v ON_ERROR_STOP=1 -f "$runtime/baseline.sql" >/dev/null
rust_dsn="postgresql://$rust_role@127.0.0.1:$pg_port/$rust_db?options=-csearch_path%3D$rust_schema"
psql -h 127.0.0.1 -p "$pg_port" -d "$rust_db" -v ON_ERROR_STOP=1 <<SQL >/dev/null
CREATE TABLE $rust_schema.lmm_schema_contract (singleton BOOLEAN PRIMARY KEY,min_reader_version BIGINT NOT NULL,max_reader_version BIGINT NOT NULL);
INSERT INTO $rust_schema.lmm_schema_contract VALUES (TRUE,1,1);
GRANT USAGE,CREATE ON SCHEMA $rust_schema TO $rust_role;
GRANT ALL PRIVILEGES ON ALL TABLES IN SCHEMA $rust_schema TO $rust_role;
GRANT ALL PRIVILEGES ON ALL SEQUENCES IN SCHEMA $rust_schema TO $rust_role;
SQL
# The normal Rust readiness contract includes the reviewed forward-only
# open-source-bounty relations even when this matrix exercises only catalog
# reads. Apply that contract inside the disposable schema so `/readyz` is a
# real dependency check rather than an unrelated fixture failure.
sed "s/__LMM_APP_SCHEMA__/$rust_schema/g" \
  "$repo_root/apps/api-rust/migrations/0002_open_source_bounty_schema.sql" \
  >"$runtime/open-source-bounty.sql"
PGOPTIONS="-c search_path=$rust_schema" psql -h 127.0.0.1 -p "$pg_port" -d "$rust_db" \
  -q -v ON_ERROR_STOP=1 -f "$runtime/open-source-bounty.sql" >/dev/null
PGOPTIONS="-c search_path=$rust_schema" psql -h 127.0.0.1 -p "$pg_port" -d "$rust_db" -v ON_ERROR_STOP=1 -c \
  "GRANT SELECT ON open_source_bounty_projects, open_source_bounty_challenges, open_source_bounty_ledgers, open_source_bounty_disputes, open_source_bounty_mcp_tokens, open_source_bounty_mcp_confirmations, open_source_bounty_mcp_operations, open_source_bounty_rest_operations TO $rust_role" \
  >/dev/null
psql "$rust_dsn" -v ON_ERROR_STOP=1 <<'SQL' >/dev/null
INSERT INTO options (key,value) VALUES
 ('SelfUseModeEnabled','false'),
 ('ModelRatio','{"fixture-model":1}'),
 ('UserUsableGroups','{"default":"default"}'),
 ('GroupRatio','{"default":1}'),
 ('payment_setting.compliance_confirmed','true'),
 ('payment_setting.compliance_terms_version','v1');
INSERT INTO users (id,username,password,display_name,role,status,email,quota,"group",setting,auth_version)
 VALUES (42,'admin-catalog-root','$2a$10$5Rm09lSOGBsP.6RiFTuleun103cKGxh/grNS/rcy7HPxJDvY9EEt2','Admin Catalog Root',100,1,'',0,'default','{}',1);
INSERT INTO vendors (id,name,description,icon,status,created_time,updated_time)
 VALUES (11,'FixtureVendor','','',1,1700000000,1700000001);
INSERT INTO models (id,model_name,description,icon,tags,vendor_id,endpoints,status,sync_official,created_time,updated_time,name_rule)
 VALUES (21,'fixture-model','','','',11,'',1,1,1700000000,1700000001,0),
        (22,'disabled-model','hidden','','',11,'',0,1,1700000002,1700000003,0);
INSERT INTO channels (id,type,key,name,status,models,"group")
 VALUES (101,1,'fixture-key','Fixture Channel',1,'fixture-model','default');
INSERT INTO abilities ("group",model,channel_id,enabled,priority,weight)
 VALUES ('default','fixture-model',101,TRUE,10,10);
INSERT INTO prefill_groups (id,name,type,items,description,created_time,updated_time)
 VALUES (31,'Fixture Group','model','["fixture-model"]','',1700000004,1700000005);
INSERT INTO redemptions (id,user_id,key,status,name,quota,created_time,redeemed_time,used_user_id,expired_time)
 VALUES (41,42,'fixture-redemption-0000000000000',1,'Fixture',100,1700000006,0,0,0);
SQL

rust_env=(DATABASE_URL="$rust_dsn" VALKEY_URL="redis://:$rust_valkey_password@127.0.0.1:$rust_valkey_port"
  SESSION_SECRET="$session_secret" CRYPTO_SECRET="$crypto_secret" PASSWORD_LOGIN_ENABLED=true
  LMM_RS_TEST_INSTANCE=1 LMM_RS_TEST_VALKEY_PORT="$rust_valkey_port" LMM_RS_SLOT=single
  LMM_RS_LISTEN_ADDR="127.0.0.1:$rust_port" LMM_SCHEMA_CONTRACT=1 VERSION=v0.0.0
  GLOBAL_API_RATE_LIMIT_ENABLE=false CRITICAL_RATE_LIMIT_ENABLE=false AUTH_COOKIE_SECURE=false)
env "${rust_env[@]}" "$repo_root/apps/api-rust/target/debug/lmm-api-rs" >"$runtime/rust.log" 2>&1 &
rust_pid=$!
for _ in {1..300}; do
  [[ -n $(ss -H -ltn "sport = :$rust_port") ]] && break
  pid_live "$rust_pid" || { tail -n 120 "$runtime/rust.log" >&2; exit 1; }
  sleep .05
done
[[ -n $(ss -H -ltn "sport = :$rust_port") ]] || { tail -n 120 "$runtime/rust.log" >&2; exit 1; }
curl -fsS --max-time 3 "http://127.0.0.1:$rust_port/readyz" >/dev/null

env "${go_env[@]}" "$runtime/legacy-go" >"$runtime/go.log" 2>&1 &
go_pid=$!
for _ in {1..300}; do
  [[ -n $(ss -H -ltn "sport = :$go_port") ]] && break
  pid_live "$go_pid" || { tail -n 120 "$runtime/go.log" >&2; exit 1; }
  sleep .05
done
[[ -n $(ss -H -ltn "sport = :$go_port") ]] || { tail -n 120 "$runtime/go.log" >&2; exit 1; }

capture() {
  local name=$1 base=$2 method=$3 path=$4 token=${5:-}
  local auth=()
  [[ -n $token ]] && auth=(-H "authorization: Bearer $token")
  curl -sS --max-time 5 -X "$method" -H 'accept: application/json' "${auth[@]}" \
    -D "$runtime/$name.headers" -o "$runtime/$name.body" -w '%{http_code}' \
    "$base$path" >"$runtime/$name.status"
}
login() {
  local name=$1 base=$2
  curl -sS --max-time 5 -X POST -H 'content-type: application/json' \
    --data-binary '{"username":"admin-catalog-root","password":"password"}' \
    -o "$runtime/$name.login.json" -w '%{http_code}' "$base/api/user/login" >"$runtime/$name.login.status"
  [[ $(<"$runtime/$name.login.status") == 200 ]]
  jq -er '.data.access_token' "$runtime/$name.login.json"
}
canonical() { jq -S . "$1"; }
pair() {
  local name=$1 method=$2 path=$3
  capture "go-$name" "http://127.0.0.1:$go_port" "$method" "$path" "$go_token"
  capture "rust-$name" "http://127.0.0.1:$rust_port" "$method" "$path" "$rust_token"
  diff -u "$runtime/go-$name.status" "$runtime/rust-$name.status"
  canonical "$runtime/go-$name.body" >"$runtime/go-$name.json"
  canonical "$runtime/rust-$name.body" >"$runtime/rust-$name.json"
  diff -u "$runtime/go-$name.json" "$runtime/rust-$name.json"
  cases=$((cases + 1))
}

go_token=$(login go "http://127.0.0.1:$go_port")
rust_token=$(login rust "http://127.0.0.1:$rust_port")
cases=0
# Authentication must precede body/query parsing on the complete admin read family.
for entry in \
  'GET|/api/models/' 'GET|/api/models/search?keyword=fixture' 'GET|/api/models/21' \
  'GET|/api/vendors/' 'GET|/api/vendors/search?keyword=Fixture' 'GET|/api/vendors/11' \
  'GET|/api/prefill_group/' 'GET|/api/prefill_group/?type=model' \
  'GET|/api/redemption/' 'GET|/api/redemption/search?status=1' 'GET|/api/redemption/41'; do
  IFS='|' read -r method path <<<"$entry"
  name="${method,,}-$(echo "$path" | tr '/?=&' '____' | tr -cd '[:alnum:]_-')"
  pair "$name" "$method" "$path"
done

jq -cn --argjson cases "$cases" --arg legacy_revision "$legacy_revision" \
  '{test:"admin-catalog-listener-differential",mode:"isolated-tcp",real_tcp:true,production_access:false,cases:$cases,legacy_go_revision:$legacy_revision,routes:["GET /api/models/","GET /api/models/search","GET /api/models/:id","GET /api/vendors/","GET /api/vendors/search","GET /api/vendors/:id","GET /api/prefill_group/","GET /api/redemption/","GET /api/redemption/search","GET /api/redemption/:id"],result:"passed"}'
