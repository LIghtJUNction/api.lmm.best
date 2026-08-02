#!/usr/bin/env bash
# Invoked by ../run-isolated-oracle.sh.  It only uses the disposable listener.
set -euo pipefail

base=${GO_BASE_URL:?run through run-isolated-oracle.sh}
marker=${ORACLE_ISOLATED_LOOPBACK_MARKER:?run through run-isolated-oracle.sh}
runtime=${ORACLE_RUNTIME_DIR:?run through run-isolated-oracle.sh}
if [[ ! -f $marker || $marker != "$runtime/.isolated-loopback-marker" || $base =~ @ || ! $base =~ ^http://(127\.0\.0\.1|localhost|\[::1\]):[1-9][0-9]*$ ]]; then
  echo 'capture requires the wrapper-issued loopback http listener URL and marker' >&2
  exit 2
fi
if [[ ${CAPTURE_LIVE_VALIDATE_ONLY:-0} == 1 ]]; then
  exit 0
fi
auth_header=''

setup_and_login() {
  curl -fsS -H 'content-type: application/json' \
    -d '{"username":"oracle","password":"oracle-pass-123","confirmPassword":"oracle-pass-123","SelfUseModeEnabled":true,"DemoSiteEnabled":false}' \
    "$base/api/setup" >/dev/null
  local login
  login=$(curl -fsS -H 'content-type: application/json' \
    -d '{"username":"oracle","password":"oracle-pass-123"}' "$base/api/user/login")
  auth_header="authorization: Bearer $(jq -r '.data.access_token' <<<"$login")"
}

request() {
  local method=$1 path=$2 body=${3-}
  local headers response status
  headers=$(mktemp)
  response=$(mktemp)
  if [[ -n $body ]]; then
    status=$(curl -sS -o "$response" -D "$headers" -w '%{http_code}' -X "$method" \
      -H "$auth_header" -H 'content-type: application/json' -d "$body" "$base$path")
  else
    status=$(curl -sS -o "$response" -D "$headers" -w '%{http_code}' -X "$method" \
      -H "$auth_header" "$base$path")
  fi
  jq -cn --arg method "$method" --arg path "$path" --arg status "$status" \
    --argjson body "$(jq 'if (.data | type) == "object" then .data |= with_entries(if .key == "access_token" or .key == "key" then .value = "<REDACTED_TOKEN_KEY>" else . end) | if .data.keys then .data.keys |= with_entries(.value = "<REDACTED_TOKEN_KEY>") else . end else . end' "$response")" \
    --arg content_type "$(awk 'BEGIN{IGNORECASE=1} /^content-type:/{sub(/\r$/, ""); sub(/^[^:]+: /, ""); print; exit}' "$headers")" \
    --arg auth_version "$(awk 'BEGIN{IGNORECASE=1} /^auth-version:/{sub(/\r$/, ""); sub(/^[^:]+: /, ""); print; exit}' "$headers")" \
    --arg cache_control "$(awk 'BEGIN{IGNORECASE=1} /^cache-control:/{sub(/\r$/, ""); sub(/^[^:]+: /, ""); print; exit}' "$headers")" \
    '{method:$method,path:$path,status:($status|tonumber),headers:{"content-type":$content_type,"auth-version":$auth_version,"cache-control":$cache_control},body:$body}'
  rm -f "$headers" "$response"
}

setup_and_login
create='{"name":"oracle-alpha","expired_time":-1,"remain_quota":100,"unlimited_quota":false,"model_limits_enabled":false,"model_limits":"","group":"default","cross_group_retry":false}'
request POST /api/token/ "$create" > /tmp/oracle-add-alpha.json
request GET '/api/token/?p=1&size=10' > /tmp/oracle-list.json
alpha_id=$(jq -r '.body.data.items[0].id' /tmp/oracle-list.json)
request GET '/api/token/search?keyword=oracle-alpha&p=1&size=10' > /tmp/oracle-search.json
request GET "/api/token/$alpha_id" > /tmp/oracle-detail.json
request POST "/api/token/$alpha_id/key" '{}' > /tmp/oracle-key.json
request POST /api/token/ "${create/oracle-alpha/oracle-beta}" > /tmp/oracle-add-beta.json
beta_id=$(request GET '/api/token/search?keyword=oracle-beta&p=1&size=10' | jq -r '.body.data.items[0].id')
update=$(jq -cn --argjson id "$beta_id" '{id:$id,name:"oracle-beta-updated",status:1,expired_time:-1,remain_quota:200,unlimited_quota:false,model_limits_enabled:false,model_limits:"",group:"default",cross_group_retry:false}')
request PUT /api/token/ "$update" > /tmp/oracle-update.json
request DELETE "/api/token/$beta_id" > /tmp/oracle-delete.json
request POST /api/token/ "${create/oracle-alpha/oracle-gamma}" > /tmp/oracle-add-gamma.json
gamma_id=$(request GET '/api/token/search?keyword=oracle-gamma&p=1&size=10' | jq -r '.body.data.items[0].id')
request POST /api/token/batch "{\"ids\":[$gamma_id]}" > /tmp/oracle-batch-delete.json
request POST /api/token/batch/keys "{\"ids\":[$alpha_id]}" > /tmp/oracle-batch-keys.json

for f in /tmp/oracle-{list,search,detail,key,add-alpha,update,delete,batch-delete,batch-keys}.json; do
  printf '%s\n' "$(basename "$f" .json)"
  cat "$f"
done
printf 'rows\n'
sqlite3 -json "$ORACLE_SQLITE_PATH" 'select id,user_id,name,status,expired_time,remain_quota,unlimited_quota,model_limits_enabled,model_limits,"group",cross_group_retry,deleted_at from tokens order by id;'
printf 'valkey\n'
redis-cli -u "$ORACLE_REDIS_URL" --scan | sort
