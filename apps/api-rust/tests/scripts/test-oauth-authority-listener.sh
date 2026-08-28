#!/usr/bin/env bash
set -Eeuo pipefail

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
repo_root=$(cd -- "$script_dir/../../../.." && pwd -P)
database_url=${LMM_OAUTH_TEST_DATABASE_URL:?LMM_OAUTH_TEST_DATABASE_URL is required}
valkey_url=${LMM_OAUTH_TEST_VALKEY_URL:?LMM_OAUTH_TEST_VALKEY_URL is required}
[[ ${LMM_OAUTH_TEST_ALLOW_SCHEMA_RESET:-} == 1 ]] || {
  echo 'LMM_OAUTH_TEST_ALLOW_SCHEMA_RESET=1 is required' >&2
  exit 1
}

runtime=$(mktemp -d "${TMPDIR:-/tmp}/lmm-oauth-authority.XXXXXX")
secret='OAuthAuthority-CI-2026!Synthetic-Session-Secret'
crypto='OAuthAuthority-CI-2026!Synthetic-Crypto-Secret'
rust_pid=
cleanup() {
  set +e
  [[ -n ${rust_pid:-} ]] && kill "$rust_pid" 2>/dev/null
  wait "$rust_pid" 2>/dev/null
  rm -rf -- "$runtime"
}
trap cleanup EXIT
trap 'cat "$runtime/rust.log" >&2 2>/dev/null || true' ERR

port=$(python3 - <<'PY'
import socket
sock = socket.socket()
sock.bind(('127.0.0.1', 0))
print(sock.getsockname()[1])
sock.close()
PY
)
base="http://127.0.0.1:$port"

psql "$database_url" -v ON_ERROR_STOP=1 <<'SQL' >/dev/null
DROP SCHEMA public CASCADE;
CREATE SCHEMA public;
SQL
psql "$database_url" -v ON_ERROR_STOP=1 \
  -f "$repo_root/apps/api-rust/crates/lmm-db-migrate/schema/postgresql-baseline.sql" >/dev/null
for migration in \
  0001_schema_contract.sql \
  0002_open_source_bounty_schema.sql \
  0003_current_dashboard_schema.sql \
  0004_oauth_authority.sql; do
  sed 's/__LMM_APP_SCHEMA__/public/g' "$repo_root/apps/api-rust/migrations/$migration" |
    psql "$database_url" -v ON_ERROR_STOP=1 >/dev/null
done
psql "$database_url" -v ON_ERROR_STOP=1 <<SQL >/dev/null
INSERT INTO lmm_schema_contract(
  singleton, contract_id, contract_sha256,
  min_reader_version, max_reader_version,
  min_writer_version, max_writer_version
) VALUES (TRUE, 4, repeat('a', 64), 1, 4, 4, 4);
INSERT INTO users(
  id, username, password, display_name, role, status,
  created_at, console_activated_at
) VALUES (
  1, 'oauth-ci-user', 'disabled', 'OAuth CI', 1, 1,
  EXTRACT(EPOCH FROM NOW())::BIGINT, 1
);
INSERT INTO options(key, value)
VALUES ('ServerAddress', '$base')
ON CONFLICT(key) DO UPDATE SET value = excluded.value;
SQL

binary="$repo_root/apps/api-rust/target/debug/lmm-api-rs"
[[ -x $binary ]] || {
  echo "Rust API binary is unavailable: $binary" >&2
  exit 1
}
env \
  DATABASE_URL="$database_url" \
  VALKEY_URL="$valkey_url" \
  LMM_RS_LISTEN_ADDR="127.0.0.1:$port" \
  LMM_RS_SLOT=blue \
  LMM_SCHEMA_CONTRACT=4 \
  SESSION_SECRET="$secret" \
  CRYPTO_SECRET="$crypto" \
  PASSWORD_LOGIN_ENABLED=false \
  GLOBAL_API_RATE_LIMIT_ENABLE=false \
  CRITICAL_RATE_LIMIT_ENABLE=false \
  AUTH_COOKIE_SECURE=false \
  VERSION=v0.0.0 \
  "$binary" >"$runtime/rust.log" 2>&1 &
rust_pid=$!
ready=false
for _ in $(seq 1 200); do
  if curl --fail --silent --show-error "$base/readyz" >/dev/null 2>&1; then
    ready=true
    break
  fi
  kill -0 "$rust_pid" 2>/dev/null || exit 1
  sleep 0.1
done
$ready || { echo 'OAuth authority listener did not become ready' >&2; exit 1; }

malformed_status=$(curl --silent --show-error \
  --output "$runtime/malformed-token.json" \
  --dump-header "$runtime/malformed-token.headers" \
  --write-out '%{http_code}' --request POST \
  --header 'content-type: application/json' --data '{' \
  "$base/oauth/token")
[[ $malformed_status == 400 ]]
[[ $(jq -r .error "$runtime/malformed-token.json") == invalid_request ]]
tr -d '\r' <"$runtime/malformed-token.headers" | grep -Fiqx 'cache-control: no-store'

metadata=$(curl --fail --silent --show-error \
  "$base/.well-known/oauth-authorization-server")
[[ $(jq -r .issuer <<<"$metadata") == "$base" ]]
[[ $(jq -r .code_challenge_methods_supported[0] <<<"$metadata") == S256 ]]

device=$(curl --fail --silent --show-error --request POST \
  --header 'content-type: application/x-www-form-urlencoded' \
  --data-urlencode client_id=lmm-api-rs \
  --data-urlencode 'scope=api_keys:list api_keys:create api_keys:reveal cc_switch:import' \
  "$base/oauth/device/code")
device_code=$(jq -r .device_code <<<"$device")
user_code=$(jq -r .user_code <<<"$device")
user_hash=$(python3 - "$secret" "$user_code" <<'PY'
import hashlib
import hmac
import sys
key = ('auth-flow-v1:' + sys.argv[1]).encode()
code = sys.argv[2].strip().replace('-', '').upper()
print(hmac.new(key, ('oauth:user-code:' + code).encode(), hashlib.sha256).hexdigest())
PY
)
psql "$database_url" -v ON_ERROR_STOP=1 -c \
  "UPDATE oauth_device_grants SET status='approved', user_id=1 WHERE user_code_hash='$user_hash'" >/dev/null

tokens=$(curl --fail --silent --show-error --request POST \
  --header 'content-type: application/x-www-form-urlencoded' \
  --data-urlencode grant_type='urn:ietf:params:oauth:grant-type:device_code' \
  --data-urlencode client_id=lmm-api-rs \
  --data-urlencode device_code="$device_code" \
  "$base/oauth/token")
access=$(jq -r .access_token <<<"$tokens")
refresh=$(jq -r .refresh_token <<<"$tokens")
[[ $access == lmm_oat_* && $refresh == lmm_ort_* ]]

malformed_status=$(curl --silent --show-error \
  --output "$runtime/malformed-key.json" \
  --dump-header "$runtime/malformed-key.headers" \
  --write-out '%{http_code}' --request POST \
  --header "authorization: Bearer $access" \
  --header 'content-type: application/json' --data '{' \
  "$base/api/oauth/bootstrap/keys")
[[ $malformed_status == 400 ]]
[[ $(jq -r .error "$runtime/malformed-key.json") == invalid_request ]]
tr -d '\r' <"$runtime/malformed-key.headers" | grep -Fiqx 'cache-control: no-store'

key=$(curl --fail --silent --show-error --request POST \
  --header "authorization: Bearer $access" \
  --header 'content-type: application/json' \
  --data '{"name":"oauth-rust-ci"}' \
  "$base/api/oauth/bootstrap/keys")
key_id=$(jq -r .id <<<"$key")
key_secret=$(jq -r .key <<<"$key")
[[ ${#key_secret} == 48 ]]
keys=$(curl --fail --silent --show-error \
  --header "authorization: Bearer $access" \
  "$base/api/oauth/bootstrap/keys")
jq -e --argjson id "$key_id" 'any(.[]; .id == $id)' <<<"$keys" >/dev/null
revealed=$(curl --fail --silent --show-error --request POST \
  --header "authorization: Bearer $access" \
  "$base/api/oauth/bootstrap/keys/$key_id/reveal")
[[ $(jq -r .key <<<"$revealed") == "$key_secret" ]]

rotated=$(curl --fail --silent --show-error --request POST \
  --header 'content-type: application/x-www-form-urlencoded' \
  --data-urlencode grant_type=refresh_token \
  --data-urlencode client_id=lmm-api-rs \
  --data-urlencode refresh_token="$refresh" \
  "$base/oauth/token")
new_access=$(jq -r .access_token <<<"$rotated")
new_refresh=$(jq -r .refresh_token <<<"$rotated")

(
  curl --silent --show-error --output "$runtime/race-rotate.json" \
    --write-out '%{http_code}' --request POST \
    --header 'content-type: application/x-www-form-urlencoded' \
    --data-urlencode grant_type=refresh_token \
    --data-urlencode client_id=lmm-api-rs \
    --data-urlencode refresh_token="$new_refresh" \
    "$base/oauth/token" >"$runtime/race-rotate.status"
) &
rotate_pid=$!
(
  curl --silent --show-error --output "$runtime/race-revoke.json" \
    --write-out '%{http_code}' --request POST \
    --header 'content-type: application/x-www-form-urlencoded' \
    --data-urlencode client_id=lmm-api-rs \
    --data-urlencode token="$new_refresh" \
    "$base/oauth/revoke" >"$runtime/race-revoke.status"
) &
revoke_pid=$!
wait "$rotate_pid" "$revoke_pid"
[[ $(<"$runtime/race-revoke.status") == 200 ]]
rotate_status=$(<"$runtime/race-rotate.status")
[[ $rotate_status == 200 || $rotate_status == 400 ]]
if [[ $rotate_status == 200 ]]; then
  raced_access=$(jq -r .access_token "$runtime/race-rotate.json")
  status=$(curl --silent --show-error --output /dev/null --write-out '%{http_code}' \
    --header "authorization: Bearer $raced_access" \
    "$base/api/oauth/bootstrap/keys")
  [[ $status == 401 ]]
else
  [[ $(jq -r .error "$runtime/race-rotate.json") == invalid_grant ]]
fi

replay_status=$(curl --silent --show-error --output "$runtime/replay.json" \
  --write-out '%{http_code}' --request POST \
  --header 'content-type: application/x-www-form-urlencoded' \
  --data-urlencode grant_type=refresh_token \
  --data-urlencode client_id=lmm-api-rs \
  --data-urlencode refresh_token="$refresh" \
  "$base/oauth/token")
[[ $replay_status == 400 ]]
[[ $(jq -r .error "$runtime/replay.json") == invalid_grant ]]
status=$(curl --silent --show-error --output /dev/null --write-out '%{http_code}' \
  --header "authorization: Bearer $new_access" \
  "$base/api/oauth/bootstrap/keys")
[[ $status == 401 ]]

echo 'OAuth authority PostgreSQL/Valkey listener gate passed'
