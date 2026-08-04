#!/usr/bin/env bash
# Real TCP differential for the legacy dashboard API-token routes and edge matrix.
#
# Both listeners must point at isolated databases with independent, equivalent
# users. The script never emits a bearer token or an unmasked API key.
set -Eeuo pipefail

# The inner probe is intentionally explicit about the scenarios it can report.
# The listener-free guard invokes this mode to check that the scenario names,
# effect assertions, and final count computation remain wired together.
if [[ ${1:-} == --static-guard ]]; then
  source=${BASH_SOURCE[0]}
  # The provenance guard is deliberately listener-free.  A static 48-character
  # key and a different database key must remain visible, while only a key
  # explicitly registered as runtime-generated may be canonicalized.
  printf -v static_key '%*s' 48 ''
  static_key=${static_key// /S}
  printf -v mismatched_key '%*s' 48 ''
  mismatched_key=${mismatched_key// /M}
  printf -v generated_key '%*s' 48 ''
  generated_key=${generated_key// /G}
  generated_registry=$(jq -cn --arg key "$generated_key" '[$key]')
  provenance_probe=$(jq -cn \
    --arg static "$static_key" --arg mismatched "$mismatched_key" \
    --arg generated "$generated_key" \
    '{data:{key:$static,keys:{"17":$static,"23":$mismatched,"41":$generated}}}' |
    jq -S --arg static "$static_key" --arg mismatched "$mismatched_key" \
      --argjson generated "$generated_registry" '
      def canonical_generated:
        . as $candidate
        | if ($candidate | type) == "string"
          and ($candidate | test("^[A-Za-z0-9]{48}$"))
          and (($generated | index($candidate)) != null)
          then "<KEY>" else . end;
      walk(if type == "object" then
        (if has("key") then .key |= canonical_generated else . end)
        | (if has("keys") and (.keys | type) == "object" then
            .keys |= with_entries(.value |= canonical_generated)
          else . end)
      else . end)')
  jq -e --arg static "$static_key" --arg mismatched "$mismatched_key" \
    '.data.key == $static and .data.keys["17"] == $static and
     .data.keys["23"] == $mismatched and .data.keys["41"] == "<KEY>"' \
    <<<"$provenance_probe" >/dev/null || {
    echo 'static guard: key provenance canonicalization masked a static or mismatched key' >&2
    exit 1
  }
  expected_effects=(
    missing-content-type wrong-content-type oversized-body top-level-null-create
    create-zero-expiration create-null-expiration deleted-at-null-create
    deleted-at-valid-create case-insensitive-fields name-alias unknown-ids-ignored
    duplicate-fields trailing-second-json encoded-query-key create-missing
    update-missing status-only-missing
  )
  expected_no_effects=(
    malformed-json batch-top-level-null batch-null-ids batch-float-element
    batch-wrong-element batch-non-array wrong-field-type wrong-quota-type
    wrong-status-type wrong-batch-type update-raw-error batch-localized-error
    bad-integer-query deleted-at-invalid-string deleted-at-wrong-type
    update-negative-id known-unused-field-type float-int exponent-int overflow-int
    top-level-null-update "\"detail-id-\${path##*/}\"" "\"key-id-\${path##*/}\""
    "\"delete-id-\${path##*/}\"" search-exact-total "\"page-\${query//[^[:alnum:]]/_}\""
    "\"search-\${query//[^[:alnum:]]/_}\"" user-setting-locale-batch
  )
  mapfile -t effect_calls < <(awk '$1 == "matrix_effect" { print $2 "\t" $3 "\t" $4 }' "$source")
  [[ ${#effect_calls[@]} -eq ${#expected_effects[@]} ]] || {
    printf 'static guard: expected %d matrix_effect calls, found %d\n' \
      "${#expected_effects[@]}" "${#effect_calls[@]}" >&2
    exit 1
  }
  for index in "${!expected_effects[@]}"; do
    IFS=$'\t' read -r name sql_expect value <<<"${effect_calls[$index]}"
    [[ $name == "${expected_effects[$index]}" && $sql_expect == *SELECT* && -n $value ]] || {
      printf 'static guard: matrix_effect #%d lacks an explicit database assertion (%s)\n' \
        "$((index + 1))" "${effect_calls[$index]}" >&2
      exit 1
    }
  done
  mapfile -t no_effect_calls < <(awk '$1 == "matrix_no_effect" { print $2 }' "$source")
  [[ ${#no_effect_calls[@]} -eq ${#expected_no_effects[@]} ]] || {
    printf 'static guard: expected %d named matrix_no_effect calls, found %d\n' \
      "${#expected_no_effects[@]}" "${#no_effect_calls[@]}" >&2
    exit 1
  }
  for index in "${!expected_no_effects[@]}"; do
    [[ ${no_effect_calls[$index]} == "${expected_no_effects[$index]}" ]] || {
      printf 'static guard: matrix_no_effect scenario mismatch at #%d\n' "$((index + 1))" >&2
      exit 1
    }
  done
  expected_normal_markers=(
    create list-masked detail batch-delete key-no-store update search
    batch-keys-no-store delete delete-replay-not-found dynamic-token-limit
    dynamic-quota-limit
  )
  mapfile -t normal_markers < <(
    awk 'BEGIN { active = 0 }
      /^exercise\(\) \{/ { active = 1; next }
      /^exercise go / { active = 0 }
      !active || $0 !~ /mark_executed[[:space:]]/ || $0 ~ /mark_executed "\$name"/ { next }
      { line = $0; sub(/^.*mark_executed[[:space:]]+/, "", line); print line }
    ' "$source" | sort
  )
  mapfile -t expected_normal_markers_sorted < <(printf '%s\n' "${expected_normal_markers[@]}" | sort)
  [[ ${#normal_markers[@]} -eq ${#expected_normal_markers[@]} ]] || {
    printf 'static guard: expected %d normal scenario markers, found %d\n' \
      "${#expected_normal_markers[@]}" "${#normal_markers[@]}" >&2
    exit 1
  }
  for index in "${!expected_normal_markers[@]}"; do
    [[ ${normal_markers[$index]} == "${expected_normal_markers_sorted[$index]}" ]] || {
      printf 'static guard: normal scenario marker mismatch at #%d\n' "$((index + 1))" >&2
      exit 1
    }
  done
  grep -Fq "expanded_cases: (\$executed_scenarios | length)" "$source"
  if grep -Eq 'expanded_cases:[[:space:]]*[0-9]+' "$source"; then
    exit 1
  fi
  grep -Fq "mark_executed \"\$name\"" "$source"
  grep -Fq 'mark_skipped "dynamic-token-limit"' "$source"
  grep -Fq 'mark_skipped "dynamic-quota-limit"' "$source"
  bash -n "$source"
  printf 'api-token TCP differential static coverage: passed (%d effect scenarios)\n' \
    "${#expected_effects[@]}"
  exit 0
fi

: "${GO_BASE_URL:?set the isolated Go listener URL}"
: "${RUST_BASE_URL:?set the isolated Rust listener URL}"
: "${GO_AUTH_BEARER:?set an isolated Go dashboard access token}"
: "${RUST_AUTH_BEARER:?set an isolated Rust dashboard access token}"

runtime=$(mktemp -d /tmp/lmm-api-token-tcp.XXXXXX)
go_static_keys="$runtime/go.static.keys"
rust_static_keys="$runtime/rust.static.keys"
go_generated_keys="$runtime/go.generated.keys"
rust_generated_keys="$runtime/rust.generated.keys"
: >"$go_static_keys"
: >"$rust_static_keys"
: >"$go_generated_keys"
: >"$rust_generated_keys"
go_tokens_table_renamed=0
rust_tokens_table_renamed=0
restore_tokens_table_for() {
  local database_url=$1 renamed=$2 current
  [[ $renamed == 1 && -n $database_url ]] || return 0
  command -v psql >/dev/null 2>&1 || return 0
  current=$(psql "$database_url" -X -qAt -v ON_ERROR_STOP=1 \
    -c "SELECT to_regclass('public.tokens')" 2>/dev/null) || return 0
  [[ -n $current ]] || psql "$database_url" -X -qAt -v ON_ERROR_STOP=1 \
    -c 'ALTER TABLE tokens_unavailable RENAME TO tokens' >/dev/null 2>&1 || true
}
cleanup() {
  restore_tokens_table_for "${GO_POSTGRES_URL:-}" "$go_tokens_table_renamed" || true
  restore_tokens_table_for "${RUST_POSTGRES_URL:-}" "$rust_tokens_table_renamed" || true
  rm -rf "$runtime"
}
trap cleanup EXIT INT TERM
trap 'echo "API-token TCP differential failed at line $LINENO" >&2' ERR

executed_scenarios=()
skipped_scenarios=()
mark_executed() {
  local name=$1 existing
  for existing in "${executed_scenarios[@]}"; do
    [[ $existing == "$name" ]] && return 0
  done
  executed_scenarios+=("$name")
}
mark_skipped() {
  skipped_scenarios+=("$1$(printf '\t')$2")
}

mounted_status() {
  local base=$1
  curl --silent --output /dev/null --write-out '%{http_code}' "$base/api/token/"
}

require_mounted_dashboard_route() {
  local engine=$1 base=$2 status
  status=$(mounted_status "$base")
  case "$status" in
    401|405) ;;
    404)
      echo "$engine API-token route is not mounted behind its dashboard-auth boundary" >&2
      exit 3
      ;;
    *)
      echo "$engine API-token unauthenticated preflight returned $status; expected 401 or 405" >&2
      exit 3
      ;;
  esac
}

require_mounted_dashboard_route Go "$GO_BASE_URL"
require_mounted_dashboard_route Rust "$RUST_BASE_URL"

request() {
  local engine=$1 base=$2 bearer=$3 method=$4 path=$5 payload=${6-}
  local headers="$runtime/$engine.headers" body="$runtime/$engine.body" status
  if [[ -n $payload ]]; then
    status=$(curl -sS -D "$headers" -o "$body" -w '%{http_code}' -X "$method" \
      -H "authorization: Bearer $bearer" -H 'content-type: application/json' \
      --data-binary "$payload" "$base$path")
  else
    status=$(curl -sS -D "$headers" -o "$body" -w '%{http_code}' -X "$method" \
      -H "authorization: Bearer $bearer" "$base$path")
  fi
  [[ $status =~ ^2 ]] || {
    echo "$engine $method $path returned HTTP $status during the success-path sequence" >&2
    return 1
  }
  jq -e . "$body" >/dev/null
}

header() {
  local file=$1 wanted=$2
  awk -v wanted="$wanted" 'BEGIN{IGNORECASE=1} index($0, ":") { n=$0; sub(/:.*/, "", n); if (tolower(n)==tolower(wanted)) { sub(/^[^:]+:[[:space:]]*/, ""); sub(/\r$/, ""); print; exit } }' "$file"
}

# The expanded matrix is deliberately kept in this inner probe so it exercises
# the same real TCP seam as the nine-route smoke sequence. PostgreSQL URLs are
# required: silently skipping durable-state assertions would be non-reproducible.
: "${GO_POSTGRES_URL:?set the isolated Go PostgreSQL URL for the expanded matrix}"
: "${RUST_POSTGRES_URL:?set the isolated Rust PostgreSQL URL for the expanded matrix}"
: "${GO_VALKEY_PORT:?set the isolated Go Valkey port for auth-cache invalidation}"
: "${RUST_VALKEY_PORT:?set the isolated Rust Valkey port for auth-cache invalidation}"
command -v psql >/dev/null || { echo 'expanded API-token matrix requires psql' >&2; exit 3; }
command -v valkey-cli >/dev/null || { echo 'expanded API-token matrix requires valkey-cli' >&2; exit 3; }

sql() { psql "$1" -X -qAt -v ON_ERROR_STOP=1 -c "$2"; }
database_url_for_engine() {
  case "$1" in
    go) printf '%s\n' "$GO_POSTGRES_URL" ;;
    rust) printf '%s\n' "$RUST_POSTGRES_URL" ;;
    *) echo "unknown API-token engine: $1" >&2; return 2 ;;
  esac
}
assert_engine_sql() {
  local engine=$1 expected=$2 query=$3 actual
  actual=$(sql "$(database_url_for_engine "$engine")" "$query")
  [[ $actual == "$expected" ]] || {
    printf '%s database assertion failed: expected %s, got %s (%s)\n' \
      "$engine" "$expected" "$actual" "$query" >&2
    return 1
  }
}
static_registry_for_engine() {
  case "$1" in
    go) printf '%s\n' "$go_static_keys" ;;
    rust) printf '%s\n' "$rust_static_keys" ;;
    *) echo "unknown API-token engine: $1" >&2; return 2 ;;
  esac
}
generated_registry_for_engine() {
  case "$1" in
    go) printf '%s\n' "$go_generated_keys" ;;
    rust) printf '%s\n' "$rust_generated_keys" ;;
    *) echo "unknown API-token engine: $1" >&2; return 2 ;;
  esac
}
engine_for_database() {
  case "$1" in
    "$GO_POSTGRES_URL") printf '%s\n' go ;;
    "$RUST_POSTGRES_URL") printf '%s\n' rust ;;
    *) echo "unknown API-token database URL" >&2; return 2 ;;
  esac
}
remember_static_keys() {
  local database=$1 engine=$2 registry key
  registry=$(static_registry_for_engine "$engine")
  while IFS= read -r key; do
    [[ -n $key ]] || continue
    grep -Fqx -- "$key" "$registry" || printf '%s\n' "$key" >>"$registry"
  done < <(sql "$database" "SELECT COALESCE(key, '') FROM tokens ORDER BY id")
}
register_generated_keys() {
  local database=$1 engine=$2 static_registry generated_registry key
  static_registry=$(static_registry_for_engine "$engine")
  generated_registry=$(generated_registry_for_engine "$engine")
  while IFS= read -r key; do
    [[ $key =~ ^[A-Za-z0-9]{48}$ ]] || continue
    grep -Fqx -- "$key" "$static_registry" && continue
    grep -Fqx -- "$key" "$generated_registry" && continue
    printf '%s\n' "$key" >>"$generated_registry"
  done < <(sql "$database" "SELECT COALESCE(key, '') FROM tokens ORDER BY id")
}
generated_keys_json() {
  local engine=$1
  jq -Rsc 'split("\n") | map(select(length > 0))' "$(generated_registry_for_engine "$engine")"
}
token_snapshot() {
  local database=$1 engine=${2:-} generated
  engine=${engine:-$(engine_for_database "$database")}
  generated=$(generated_keys_json "$engine")
  sql "$database" 'SELECT COALESCE(json_agg(to_jsonb(t) ORDER BY id), '\''[]'\''::json) FROM tokens t' |
    jq -S --argjson generated "$generated" '
      def canonical_generated:
        . as $candidate
        | if ($candidate | type) == "string"
          and ($candidate | test("^[A-Za-z0-9]{48}$"))
          and (($generated | index($candidate)) != null)
          then "<KEY>" else . end;
      map(.key |= canonical_generated
        | .created_time = "<TIME>"
        | .accessed_time = "<TIME>"
        | .deleted_at = (if .deleted_at == null then null else "<DELETED>" end))'
}
canonical() {
  local engine=$1 file=$2 generated
  generated=$(generated_keys_json "$engine")
  jq -S --argjson generated "$generated" '
    def canonical_generated:
      . as $candidate
      | if ($candidate | type) == "string"
        and ($candidate | test("^[A-Za-z0-9]{48}$"))
        and (($generated | index($candidate)) != null)
        then "<KEY>" else . end;
    def canonical_response:
      . as $candidate
      | if ($candidate | type) == "string"
        and ($candidate | test("^[A-Za-z0-9]{4}\\*{10}[A-Za-z0-9]{4}$"))
        and ([ $generated[] | select(type == "string" and length == 48
             and .[0:4] == $candidate[0:4] and .[-4:] == $candidate[-4:]) ] | length > 0)
        then "<MASKED_KEY>" else canonical_generated end;
    walk(if type == "object" then
      (if has("key") then .key |= canonical_response else . end)
      | (if has("keys") and (.keys | type) == "object" then
          .keys |= with_entries(.value |= canonical_generated)
        else . end)
      | (if has("created_time") then .created_time = "<TIME>" else . end)
      | (if has("accessed_time") then .accessed_time = "<TIME>" else . end)
      | (if has("DeletedAt") and .DeletedAt != null then .DeletedAt = "<DELETED_AT>" else . end)
    else . end)' "$file"
}
reset_matrix() {
  sql "$GO_POSTGRES_URL" 'TRUNCATE tokens RESTART IDENTITY' >/dev/null
  sql "$RUST_POSTGRES_URL" 'TRUNCATE tokens RESTART IDENTITY' >/dev/null
  : >"$go_static_keys"
  : >"$rust_static_keys"
  : >"$go_generated_keys"
  : >"$rust_generated_keys"
}
seed_matrix_token() {
  local name=$1 status=${2:-1} expired_time=${3:--1}
  reset_matrix
  assert_engine_sql go 0 'SELECT COUNT(*) FROM tokens'
  assert_engine_sql rust 0 'SELECT COUNT(*) FROM tokens'
  local statement="INSERT INTO tokens (id,user_id,key,name,status,expired_time,remain_quota,unlimited_quota,model_limits_enabled,model_limits,\"group\",cross_group_retry) VALUES (1,1,'matrix-$name-key','$name',$status,$expired_time,100,false,false,'','default',false)"
  sql "$GO_POSTGRES_URL" "$statement" >/dev/null
  sql "$RUST_POSTGRES_URL" "$statement" >/dev/null
  remember_static_keys "$GO_POSTGRES_URL" go
  remember_static_keys "$RUST_POSTGRES_URL" rust
}
set_identity() {
  local role=$1 status=$2
  sql "$GO_POSTGRES_URL" "UPDATE users SET role=$role,status=$status WHERE username='root'" >/dev/null
  sql "$RUST_POSTGRES_URL" "UPDATE users SET role=$role,status=$status WHERE username='root'" >/dev/null
  flush_valkey
}
flush_valkey() {
  valkey-cli -h 127.0.0.1 -p "$GO_VALKEY_PORT" FLUSHDB >/dev/null
  valkey-cli -h 127.0.0.1 -p "$RUST_VALKEY_PORT" FLUSHDB >/dev/null
}
assert_snapshot_pair() {
  if (( go_tokens_table_renamed == 0 && rust_tokens_table_renamed == 0 )); then
    register_generated_keys "$GO_POSTGRES_URL" go
    register_generated_keys "$RUST_POSTGRES_URL" rust
  fi
  diff -u <(token_snapshot "$GO_POSTGRES_URL" go) <(token_snapshot "$RUST_POSTGRES_URL" rust)
}

exercise() {
  local engine=$1 base=$2 bearer=$3
  local create='{"name":"tcp-oracle-token","expired_time":-1,"remain_quota":100,"unlimited_quota":false,"model_limits_enabled":false,"model_limits":"","allow_ips":"","group":"default","cross_group_retry":false}'
  request "$engine" "$base" "$bearer" POST /api/token/ "$create"
  jq -e '.success == true and (.data | not)' "$runtime/$engine.body" >/dev/null
  assert_engine_sql "$engine" 1 "SELECT COUNT(*) FROM tokens WHERE name='tcp-oracle-token' AND deleted_at IS NULL"
  [[ $engine == rust ]] && mark_executed create

  # The local oracle sets max_user_tokens=2.  Create the second token, then
  # prove a third is rejected through the public HTTP seam rather than relying
  # on a Rust constructor default.  This stays harmless for the generic inner
  # probe unless LMM_API_TOKEN_EXPECT_LIMIT is explicitly supplied.  The
  # second token is also the successful batch-delete target below.
  if [[ ${LMM_API_TOKEN_EXPECT_LIMIT:-} != '' ]]; then
    [[ $LMM_API_TOKEN_EXPECT_LIMIT =~ ^[0-9]+$ ]] || {
      echo 'LMM_API_TOKEN_EXPECT_LIMIT must be a decimal integer' >&2
      return 2
    }
    request "$engine" "$base" "$bearer" POST /api/token/ "${create/tcp-oracle-token/tcp-oracle-token-batch}"
    jq -e '.success == true' "$runtime/$engine.body" >/dev/null
    assert_engine_sql "$engine" 1 "SELECT COUNT(*) FROM tokens WHERE name='tcp-oracle-token-batch' AND deleted_at IS NULL"
    request "$engine" "$base" "$bearer" POST /api/token/ "${create/tcp-oracle-token/tcp-oracle-token-over-limit}"
    jq -e --argjson limit "$LMM_API_TOKEN_EXPECT_LIMIT" '.success == false and (.message | contains(($limit | tostring)))' "$runtime/$engine.body" >/dev/null
    assert_engine_sql "$engine" 2 'SELECT COUNT(*) FROM tokens WHERE deleted_at IS NULL'
    cp "$runtime/$engine.body" "$runtime/$engine.token-limit.json"
    request "$engine" "$base" "$bearer" POST /api/token/ "${create/100/2000000001}"
    jq -e '.success == false' "$runtime/$engine.body" >/dev/null
    assert_engine_sql "$engine" 2 'SELECT COUNT(*) FROM tokens WHERE deleted_at IS NULL'
    cp "$runtime/$engine.body" "$runtime/$engine.quota-limit.json"
    [[ $engine == rust ]] && {
      mark_executed dynamic-token-limit
      mark_executed dynamic-quota-limit
    }
  elif [[ $engine == rust ]]; then
    mark_skipped "dynamic-token-limit" 'LMM_API_TOKEN_EXPECT_LIMIT is unset; no dynamic limit fixture was advertised'
    mark_skipped "dynamic-quota-limit" 'LMM_API_TOKEN_EXPECT_LIMIT is unset; no dynamic quota fixture was advertised'
  else
    :
  fi

  request "$engine" "$base" "$bearer" GET '/api/token/?p=1&size=10'
  local id
  id=$(jq -er '.data.items[] | select(.name == "tcp-oracle-token") | .id' "$runtime/$engine.body")
  jq -e '.data.items[] | select(.id == '"$id"') | (.key | test("^.{4}\\*{10}.{4}$"))' "$runtime/$engine.body" >/dev/null
  [[ $engine == rust ]] && mark_executed list-masked

  request "$engine" "$base" "$bearer" GET "/api/token/$id"
  jq -e --argjson id "$id" '.success == true and (.data.id == $id)' "$runtime/$engine.body" >/dev/null
  cp "$runtime/$engine.body" "$runtime/$engine.detail.json"
  [[ $engine == rust ]] && mark_executed detail

  if [[ ${LMM_API_TOKEN_EXPECT_LIMIT:-} == '' ]]; then
    request "$engine" "$base" "$bearer" POST /api/token/ "${create/tcp-oracle-token/tcp-oracle-token-batch}"
    jq -e '.success == true' "$runtime/$engine.body" >/dev/null
    assert_engine_sql "$engine" 1 "SELECT COUNT(*) FROM tokens WHERE name='tcp-oracle-token-batch' AND deleted_at IS NULL"
  fi
  request "$engine" "$base" "$bearer" GET '/api/token/?p=1&size=10'
  local batch_id
  batch_id=$(jq -er '.data.items[] | select(.name == "tcp-oracle-token-batch") | .id' "$runtime/$engine.body")
  request "$engine" "$base" "$bearer" POST /api/token/batch "{\"ids\":[$batch_id]}"
  jq -e '.success == true' "$runtime/$engine.body" >/dev/null
  assert_engine_sql "$engine" 0 "SELECT COUNT(*) FROM tokens WHERE name='tcp-oracle-token-batch' AND deleted_at IS NULL"
  cp "$runtime/$engine.body" "$runtime/$engine.batch-delete.json"
  [[ $engine == rust ]] && mark_executed batch-delete

  request "$engine" "$base" "$bearer" POST "/api/token/$id/key" '{}'
  jq -e '.success == true and (.data.key | strings | test("^[A-Za-z0-9]{48}$"))' "$runtime/$engine.body" >/dev/null
  [[ $(header "$runtime/$engine.headers" cache-control) == 'no-store, no-cache, must-revalidate, private, max-age=0' ]]
  [[ $engine == rust ]] && mark_executed key-no-store

  request "$engine" "$base" "$bearer" PUT /api/token/ "$(jq -cn --argjson id "$id" '$ARGS.named | {id: $id, name:"tcp-oracle-token-updated", status:1, expired_time:-1, remain_quota:200, unlimited_quota:false, model_limits_enabled:false, model_limits:"", allow_ips:"", group:"default", cross_group_retry:false}')"
  jq -e '.success == true' "$runtime/$engine.body" >/dev/null
  assert_engine_sql "$engine" 1 "SELECT COUNT(*) FROM tokens WHERE name='tcp-oracle-token-updated' AND deleted_at IS NULL"
  cp "$runtime/$engine.body" "$runtime/$engine.update.json"
  [[ $engine == rust ]] && mark_executed update

  request "$engine" "$base" "$bearer" GET '/api/token/search?keyword=tcp-oracle-token-updated&p=1&size=10'
  jq -e '.success == true and (.data.items | length) == 1' "$runtime/$engine.body" >/dev/null
  cp "$runtime/$engine.body" "$runtime/$engine.search.json"
  [[ $engine == rust ]] && mark_executed search

  request "$engine" "$base" "$bearer" POST /api/token/batch/keys "{\"ids\":[$id]}"
  jq -e '.success == true' "$runtime/$engine.body" >/dev/null
  cp "$runtime/$engine.body" "$runtime/$engine.keys.json"
  [[ $(header "$runtime/$engine.headers" cache-control) == 'no-store, no-cache, must-revalidate, private, max-age=0' ]]
  [[ $engine == rust ]] && mark_executed batch-keys-no-store

  request "$engine" "$base" "$bearer" DELETE "/api/token/$id"
  jq -e '.success == true' "$runtime/$engine.body" >/dev/null
  assert_engine_sql "$engine" 0 "SELECT COUNT(*) FROM tokens WHERE name='tcp-oracle-token-updated' AND deleted_at IS NULL"
  cp "$runtime/$engine.body" "$runtime/$engine.delete.json"
  [[ $engine == rust ]] && mark_executed delete

  request "$engine" "$base" "$bearer" DELETE "/api/token/$id"
  jq -e '.success == false and .message == "record not found"' "$runtime/$engine.body" >/dev/null
  cp "$runtime/$engine.body" "$runtime/$engine.delete-replay.json"
  [[ $engine == rust ]] && mark_executed delete-replay-not-found
  return 0
}

exercise go "$GO_BASE_URL" "$GO_AUTH_BEARER"
exercise rust "$RUST_BASE_URL" "$RUST_AUTH_BEARER"
register_generated_keys "$GO_POSTGRES_URL" go
register_generated_keys "$RUST_POSTGRES_URL" rust
for case in detail batch-delete update search keys delete delete-replay token-limit quota-limit; do
  [[ -f $runtime/go.$case.json ]] || continue
  canonical go "$runtime/go.$case.json" >"$runtime/go.$case.canonical"
  canonical rust "$runtime/rust.$case.json" >"$runtime/rust.$case.canonical"
  diff -u "$runtime/go.$case.canonical" "$runtime/rust.$case.canonical"
done

matrix_call() {
  local engine=$1 base=$2 bearer=$3 name=$4 method=$5 path=$6 payload=$7 content_type=$8 language=$9 expected=${10}
  local prefix="$runtime/matrix.$engine.$name"
  [[ $name == invalid-identity-* ]] && bearer='invalid.synthetic.identity'
  local args=(--silent --show-error --dump-header "$prefix.headers" --output "$prefix.body" --write-out '%{http_code}' --request "$method" -H "authorization: Bearer $bearer")
  [[ $language == none ]] || args+=( -H "accept-language: $language" )
  if [[ $content_type == none ]]; then
    # curl otherwise adds application/x-www-form-urlencoded for a body,
    # turning this case into a wrong-content-type request.
    [[ $payload == __NONE__ ]] || args+=( -H 'content-type:' )
  else
    args+=( -H "content-type: $content_type" )
  fi
  [[ $payload == __NONE__ ]] || args+=( --data-binary "$payload" )
  curl "${args[@]}" "$base$path" >"$prefix.status"
  [[ $(<"$prefix.status") == "$expected" ]] || { echo "$name/$engine status mismatch" >&2; return 1; }
  jq -e . "$prefix.body" >/dev/null
}
matrix_pair() {
  local name=$1 method=$2 path=$3 payload=$4 content_type=$5 language=$6 expected=$7
  matrix_call go "$GO_BASE_URL" "$GO_AUTH_BEARER" "$name" "$method" "$path" "$payload" "$content_type" "$language" "$expected"
  matrix_call rust "$RUST_BASE_URL" "$RUST_AUTH_BEARER" "$name" "$method" "$path" "$payload" "$content_type" "$language" "$expected"
  diff -u "$runtime/matrix.go.$name.status" "$runtime/matrix.rust.$name.status"
  if (( go_tokens_table_renamed == 0 && rust_tokens_table_renamed == 0 )); then
    register_generated_keys "$GO_POSTGRES_URL" go
    register_generated_keys "$RUST_POSTGRES_URL" rust
  fi
  if ! diff -u \
    <(canonical go "$runtime/matrix.go.$name.body") \
    <(canonical rust "$runtime/matrix.rust.$name.body"); then
    printf '%s response body mismatch\n' "$name" >&2
    return 1
  fi
  for stable_header in content-type cache-control pragma expires auth-version; do
    diff -u \
      <(header "$runtime/matrix.go.$name.headers" "$stable_header") \
      <(header "$runtime/matrix.rust.$name.headers" "$stable_header")
  done
  local go_request_id rust_request_id
  go_request_id=$(header "$runtime/matrix.go.$name.headers" x-oneapi-request-id)
  rust_request_id=$(header "$runtime/matrix.rust.$name.headers" x-oneapi-request-id)
  if [[ -n $go_request_id && -z $rust_request_id ]] || [[ -z $go_request_id && -n $rust_request_id ]]; then
    echo "$name request-id presence mismatch" >&2
    return 1
  fi
}
matrix_no_effect() {
  local name=$1; shift
  token_snapshot "$GO_POSTGRES_URL" >"$runtime/before.go.$name"
  token_snapshot "$RUST_POSTGRES_URL" >"$runtime/before.rust.$name"
  matrix_pair "$name" "$@"
  diff -u "$runtime/before.go.$name" <(token_snapshot "$GO_POSTGRES_URL")
  diff -u "$runtime/before.rust.$name" <(token_snapshot "$RUST_POSTGRES_URL")
  assert_snapshot_pair
  mark_executed "$name"
}
matrix_effect() {
  local name=$1 expected_query=$2 expected_value=$3
  shift 3
  matrix_pair "$name" "$@"
  assert_engine_sql go "$expected_value" "$expected_query"
  assert_engine_sql rust "$expected_value" "$expected_query"
  assert_snapshot_pair
  mark_executed "$name"
}

reset_matrix; set_identity 100 2
for locale in zh en zh-TW; do matrix_no_effect "disabled-user-$locale" GET '/api/token/?p=1&size=10' __NONE__ none "$locale" 401; done
set_identity 0 1
for locale in zh en zh-TW; do matrix_no_effect "guest-$locale" GET '/api/token/?p=1&size=10' __NONE__ none "$locale" 403; done
set_identity 100 1
for locale in zh en zh-TW; do matrix_no_effect "invalid-identity-$locale" GET '/api/token/?p=1&size=10' __NONE__ none "$locale" 401; done

matrix_no_effect malformed-json POST /api/token/ '{' application/json en 200
matrix_no_effect batch-top-level-null POST /api/token/batch 'null' application/json zh-CN 200
matrix_no_effect batch-null-ids POST /api/token/batch/keys '{"IDS":null}' application/json zh-CN 200
matrix_no_effect batch-float-element POST /api/token/batch/keys '{"ids":[1.5]}' application/json zh-CN 200
matrix_no_effect batch-wrong-element POST /api/token/batch/keys '{"ids":["1"]}' application/json zh-CN 200
matrix_no_effect batch-non-array POST /api/token/batch/keys '{"ids":{}}' application/json zh-CN 200
matrix_no_effect wrong-field-type POST /api/token/ '{"name":123}' application/json en 200
matrix_no_effect wrong-quota-type POST /api/token/ '{"remain_quota":"100"}' application/json en 200
matrix_no_effect wrong-status-type PUT /api/token/ '{"id":1,"status":"1"}' application/json en 200
matrix_no_effect wrong-batch-type POST /api/token/batch/keys '{"ids":"1"}' application/json en 200
matrix_no_effect update-raw-error PUT /api/token/ '{' application/json en 200
matrix_no_effect batch-localized-error POST /api/token/batch '{"ids":[1.5]}' application/json zh-TW 200
reset_matrix
matrix_effect missing-content-type "SELECT COUNT(*) FROM tokens WHERE name='missing-content-type' AND deleted_at IS NULL" 1 POST /api/token/ '{"name":"missing-content-type"}' none en 200
reset_matrix
matrix_effect wrong-content-type "SELECT COUNT(*) FROM tokens WHERE name='wrong-content-type' AND deleted_at IS NULL" 1 POST /api/token/ '{"name":"wrong-content-type"}' text/plain en 200
oversized_payload_file="$runtime/oversized-body.json"
{
  printf '{"name":"oversized-body","padding":"'
  head -c 2100001 /dev/zero | tr '\0' x
  printf '"}'
} >"$oversized_payload_file"
oversized_payload="@$oversized_payload_file"
reset_matrix
matrix_effect oversized-body "SELECT COUNT(*) FROM tokens WHERE name='oversized-body' AND deleted_at IS NULL" 1 POST /api/token/ "$oversized_payload" application/json en 200
matrix_no_effect bad-integer-query GET '/api/token/?p=nan&size=wat' __NONE__ none en 200

reset_matrix
sql "$GO_POSTGRES_URL" "UPDATE options SET value='100' WHERE key='token_setting.max_user_tokens'" >/dev/null
sql "$RUST_POSTGRES_URL" "UPDATE options SET value='100' WHERE key='token_setting.max_user_tokens'" >/dev/null
matrix_effect top-level-null-create 'SELECT COUNT(*) FROM tokens WHERE id=1 AND deleted_at IS NULL' 1 POST /api/token/ 'null' application/json en 200
reset_matrix
matrix_effect create-zero-expiration "SELECT expired_time FROM tokens WHERE name='create-zero-expiration'" -1 POST /api/token/ '{"name":"create-zero-expiration","expired_time":0}' application/json en 200
reset_matrix
matrix_effect create-null-expiration "SELECT expired_time FROM tokens WHERE name='create-null-expiration'" -1 POST /api/token/ '{"name":"create-null-expiration","expired_time":null}' application/json en 200
reset_matrix
matrix_effect deleted-at-null-create "SELECT COUNT(*) FROM tokens WHERE name='deleted-at-null-create' AND deleted_at IS NULL" 1 POST /api/token/ '{"name":"deleted-at-null-create","DeletedAt":null}' application/json en 200
reset_matrix
matrix_effect deleted-at-valid-create "SELECT COUNT(*) FROM tokens WHERE name='deleted-at-valid-create' AND deleted_at IS NULL" 1 POST /api/token/ '{"name":"deleted-at-valid-create","DeletedAt":"2026-08-01T12:34:56Z"}' application/json en 200
matrix_no_effect deleted-at-invalid-string POST /api/token/ '{"name":"deleted-at-invalid-string","DeletedAt":"not-a-timestamp"}' application/json en 200
matrix_no_effect deleted-at-wrong-type POST /api/token/ '{"name":"deleted-at-wrong-type","DeletedAt":123}' application/json en 200
matrix_no_effect update-negative-id PUT /api/token/ '{"id":-1,"name":"negative-id"}' application/json en 200
reset_matrix
matrix_effect case-insensitive-fields "SELECT COUNT(*) FROM tokens WHERE name='case-insensitive-fields' AND deleted_at IS NULL" 1 POST /api/token/ '{"NAME":"case-insensitive-fields"}' application/json en 200
reset_matrix
matrix_effect name-alias "SELECT COUNT(*) FROM tokens WHERE name='name-alias' AND deleted_at IS NULL" 1 POST /api/token/ '{"Name":"name-alias"}' application/json en 200
reset_matrix
matrix_effect unknown-ids-ignored "SELECT COUNT(*) FROM tokens WHERE name='unknown-ids-ignored' AND deleted_at IS NULL" 1 POST /api/token/ '{"name":"unknown-ids-ignored","ids":"not-an-array"}' application/json en 200
matrix_no_effect known-unused-field-type POST /api/token/ '{"created_time":"not-an-int","name":"unused-type"}' application/json en 200
reset_matrix
matrix_effect duplicate-fields "SELECT name FROM tokens WHERE name='duplicate-last'" duplicate-last POST /api/token/ '{"name":"duplicate-first","Name":"duplicate-last"}' application/json en 200
[[ $(sql "$GO_POSTGRES_URL" "SELECT name FROM tokens WHERE name='duplicate-last'") == duplicate-last ]]
[[ $(sql "$RUST_POSTGRES_URL" "SELECT name FROM tokens WHERE name='duplicate-last'") == duplicate-last ]]
reset_matrix
matrix_effect trailing-second-json "SELECT name FROM tokens WHERE name='trailing-first'" trailing-first POST /api/token/ '{"name":"trailing-first"}{"name":"trailing-second"}' application/json en 200
matrix_no_effect float-int POST /api/token/ '{"remain_quota":1.5}' application/json en 200
matrix_no_effect exponent-int POST /api/token/ '{"remain_quota":1e-1}' application/json en 200
matrix_no_effect overflow-int POST /api/token/ '{"remain_quota":9223372036854775808}' application/json en 200
matrix_no_effect top-level-null-update PUT /api/token/ 'null' application/json en 200
reset_matrix
seed_matrix_token encoded-query-key
matrix_effect encoded-query-key 'SELECT status FROM tokens WHERE id=1' 0 PUT '/api/token/?%73tatus_only=true' '{"id":1,"status":0}' application/json en 200
for path in /api/token/9223372036854775808 /api/token/-9223372036854775809 /api/token/not-an-integer; do
  matrix_no_effect "detail-id-${path##*/}" GET "$path" __NONE__ none en 200
  matrix_no_effect "key-id-${path##*/}" POST "$path/key" __NONE__ none en 200
  matrix_no_effect "delete-id-${path##*/}" DELETE "$path" __NONE__ none en 200
done

# Search total is the exact match count even when the configured token limit
# is lower than the number of matching rows. The fixture starts listeners with
# max_user_tokens=2, so three matching rows expose an accidental LIMIT in the
# count query without requiring any non-TCP assertion.
sql "$GO_POSTGRES_URL" "UPDATE options SET value='2' WHERE key='token_setting.max_user_tokens'" >/dev/null
sql "$RUST_POSTGRES_URL" "UPDATE options SET value='2' WHERE key='token_setting.max_user_tokens'" >/dev/null
reset_matrix
sql "$GO_POSTGRES_URL" "INSERT INTO tokens (user_id,key,name,status,expired_time,remain_quota,unlimited_quota,model_limits_enabled,\"group\",cross_group_retry) VALUES (1,'sk-total-one','exact-total',1,-1,100,false,false,'default',false),(1,'sk-total-two','exact-total',1,-1,100,false,false,'default',false),(1,'sk-total-three','exact-total',1,-1,100,false,false,'default',false)" >/dev/null
sql "$RUST_POSTGRES_URL" "INSERT INTO tokens (user_id,key,name,status,expired_time,remain_quota,unlimited_quota,model_limits_enabled,\"group\",cross_group_retry) VALUES (1,'sk-total-one','exact-total',1,-1,100,false,false,'default',false),(1,'sk-total-two','exact-total',1,-1,100,false,false,'default',false),(1,'sk-total-three','exact-total',1,-1,100,false,false,'default',false)" >/dev/null
remember_static_keys "$GO_POSTGRES_URL" go
remember_static_keys "$RUST_POSTGRES_URL" rust
matrix_no_effect search-exact-total GET '/api/token/search?keyword=exact-total&p=1&size=10' __NONE__ none en 200
[[ $(jq -r '.data.total' "$runtime/matrix.go.search-exact-total.body") == 3 ]]
[[ $(jq -r '.data.total' "$runtime/matrix.rust.search-exact-total.body") == 3 ]]

reset_matrix
matrix_effect create-missing "SELECT COUNT(*) FROM tokens WHERE name='create-missing' AND deleted_at IS NULL" 1 POST /api/token/ '{"name":"create-missing"}' application/json en 200
[[ $(sql "$GO_POSTGRES_URL" "SELECT expired_time FROM tokens WHERE name='create-missing'") == -1 ]]
[[ $(sql "$RUST_POSTGRES_URL" "SELECT expired_time FROM tokens WHERE name='create-missing'") == -1 ]]
reset_matrix
seed_matrix_token update-missing
matrix_effect update-missing 'SELECT expired_time FROM tokens WHERE id=1' 0 PUT /api/token/ '{"id":1,"name":"update-missing"}' application/json en 200
[[ $(sql "$GO_POSTGRES_URL" 'SELECT expired_time FROM tokens WHERE id=1') == 0 ]]
[[ $(sql "$RUST_POSTGRES_URL" 'SELECT expired_time FROM tokens WHERE id=1') == 0 ]]
reset_matrix
seed_matrix_token status-only-missing
matrix_effect status-only-missing 'SELECT status FROM tokens WHERE id=1' 0 PUT '/api/token/?status_only=true' '{"id":1,"status":0}' application/json en 200
[[ $(sql "$GO_POSTGRES_URL" 'SELECT status FROM tokens WHERE id=1') == 0 ]]
[[ $(sql "$RUST_POSTGRES_URL" 'SELECT status FROM tokens WHERE id=1') == 0 ]]
for query in 'p=-1&size=1' 'p=1&size=-1' 'p=1&size=0' 'p=1&size=101' 'p=wat&size=1'; do
  matrix_no_effect "page-${query//[^[:alnum:]]/_}" GET "/api/token/?$query" __NONE__ none en 200
done

reset_matrix
sql "$GO_POSTGRES_URL" "INSERT INTO tokens (user_id,key,name,status,expired_time,remain_quota,unlimited_quota,model_limits_enabled,\"group\",cross_group_retry) VALUES (1,'sk-matrix-search','a%b',1,-1,100,false,false,'default',false),(1,'sk-matrix-unicode','多',1,-1,100,false,false,'default',false),(1,'sk-matrix-escape','escape!%literal',1,-1,100,false,false,'default',false)" >/dev/null
sql "$RUST_POSTGRES_URL" "INSERT INTO tokens (user_id,key,name,status,expired_time,remain_quota,unlimited_quota,model_limits_enabled,\"group\",cross_group_retry) VALUES (1,'sk-matrix-search','a%b',1,-1,100,false,false,'default',false),(1,'sk-matrix-unicode','多',1,-1,100,false,false,'default',false),(1,'sk-matrix-escape','escape!%literal',1,-1,100,false,false,'default',false)" >/dev/null
remember_static_keys "$GO_POSTGRES_URL" go
remember_static_keys "$RUST_POSTGRES_URL" rust
for query in 'keyword=%25%25' 'keyword=a%25%25b' 'keyword=a' 'keyword=%E5%A4%9A%25' 'keyword=escape%21%25literal' 'keyword=escape%21_literal' 'token=sk-matrix-search'; do
  matrix_no_effect "search-${query//[^[:alnum:]]/_}" GET "/api/token/search?$query&p=1&size=10" __NONE__ none en 200
done

# A saved user language wins over Accept-Language for localized handler
# errors, as in Go's GetUserLanguage-backed translation path. Keep this case
# last because an already-authenticated session may cache the user setting.
sql "$GO_POSTGRES_URL" "UPDATE users SET setting='{\"language\":\"zh-TW\"}' WHERE username='root'" >/dev/null
sql "$RUST_POSTGRES_URL" "UPDATE users SET setting='{\"language\":\"zh-TW\"}' WHERE username='root'" >/dev/null
flush_valkey
matrix_no_effect user-setting-locale-batch POST /api/token/batch '{"ids":[1.5]}' application/json en 200
saved_locale_json='{"success":false,"message":"無效的參數"}'
for engine in go rust; do
  [[ $(<"$runtime/matrix.$engine.user-setting-locale-batch.status") == 200 ]]
  jq -e --argjson expected "$saved_locale_json" '. == $expected' \
    "$runtime/matrix.$engine.user-setting-locale-batch.body" >/dev/null
done
sql "$GO_POSTGRES_URL" "UPDATE users SET setting='{}' WHERE username='root'" >/dev/null
sql "$RUST_POSTGRES_URL" "UPDATE users SET setting='{}' WHERE username='root'" >/dev/null
flush_valkey

sql "$GO_POSTGRES_URL" 'ALTER TABLE tokens RENAME TO tokens_unavailable' >/dev/null
go_tokens_table_renamed=1
sql "$RUST_POSTGRES_URL" 'ALTER TABLE tokens RENAME TO tokens_unavailable' >/dev/null
rust_tokens_table_renamed=1
db_error='ERROR: relation "tokens" does not exist (SQLSTATE 42P01)'
for name_and_route in \
  'list-db-failure|GET|/api/token/?p=1&size=10|__NONE__|none' \
  'detail-db-failure|GET|/api/token/1|__NONE__|none' \
  'key-db-failure|POST|/api/token/1/key|__NONE__|none' \
  'create-db-failure|POST|/api/token/|{"name":"db-create"}|application/json' \
  'update-db-failure|PUT|/api/token/|{"id":1,"name":"db-update"}|application/json' \
  'delete-db-failure|DELETE|/api/token/1|__NONE__|none' \
  'batch-delete-db-failure|POST|/api/token/batch|{"ids":[1]}|application/json' \
  'batch-keys-db-failure|POST|/api/token/batch/keys|{"ids":[1]}|application/json' \
  'search-fuzzy-count-db-failure|GET|/api/token/search?keyword=db%25&p=1&size=10|__NONE__|none' \
  'search-exact-db-failure|GET|/api/token/search?keyword=db-fault&p=1&size=10|__NONE__|none'; do
  IFS='|' read -r name method path payload content_type <<<"$name_and_route"
  matrix_pair "$name" "$method" "$path" "$payload" "$content_type" en 200
  for engine in go rust; do
    expected_message=$db_error
    case "$name" in
      search-fuzzy-count-db-failure) expected_message='获取令牌数量失败' ;;
      search-exact-db-failure) expected_message='搜索令牌失败' ;;
    esac
    jq -e --arg expected "$expected_message" \
      '.success == false and .message == $expected' \
      "$runtime/matrix.$engine.$name.body" >/dev/null
  done
  mark_executed "$name"
done
sql "$GO_POSTGRES_URL" 'ALTER TABLE tokens_unavailable RENAME TO tokens' >/dev/null
go_tokens_table_renamed=0
sql "$RUST_POSTGRES_URL" 'ALTER TABLE tokens_unavailable RENAME TO tokens' >/dev/null
rust_tokens_table_renamed=0

scenario_names_json() {
  if (( $# == 0 )); then
    printf '[]\n'
  else
    printf '%s\n' "$@" | jq -Rsc 'split("\n")[:-1]'
  fi
}
executed_json=$(scenario_names_json "${executed_scenarios[@]}")
skipped_json=$(if (( ${#skipped_scenarios[@]} == 0 )); then
  printf '[]\n'
else
  printf '%s\n' "${skipped_scenarios[@]}" |
    jq -Rsc 'split("\n")[:-1] | map(split("\t") | {name:.[0],reason:.[1]})'
fi)
jq -cn --argjson executed_scenarios "$executed_json" --argjson skipped_scenarios "$skipped_json" \
  '{test:"api-token-tcp-differential",go_tcp_listener:true,rust_tcp_listener:true,routes:9,cases:$executed_scenarios,expanded_cases: ($executed_scenarios | length),executed_cases:($executed_scenarios | length),skipped_cases:$skipped_scenarios,skipped_count:($skipped_scenarios | length),result:"passed"}'
