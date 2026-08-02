#!/usr/bin/env bash
set -euo pipefail

usage() {
  echo "usage: $0 --base-url URL --request FILE --output FILE [--sqlite FILE | --postgres-url URL] [--redis-url URL]" >&2
  exit 2
}

base_url=
request_file=
output_file=
sqlite_file=
postgres_url=
redis_url=
while (($#)); do
  case "$1" in
    --base-url) base_url=${2:?}; shift 2 ;;
    --request) request_file=${2:?}; shift 2 ;;
    --output) output_file=${2:?}; shift 2 ;;
    --sqlite) sqlite_file=${2:?}; shift 2 ;;
    --postgres-url) postgres_url=${2:?}; shift 2 ;;
    --redis-url) redis_url=${2:?}; shift 2 ;;
    *) usage ;;
  esac
done
[[ -n $base_url && -f $request_file && -n $output_file ]] || usage
for command in curl jq sha256sum; do
  command -v "$command" >/dev/null || { echo "required command is unavailable: $command" >&2; exit 1; }
done
[[ -z $sqlite_file || -z $postgres_url ]] || {
  echo "choose one database snapshot backend" >&2
  exit 2
}
case "$base_url" in
  http://localhost:* | http://127.0.0.1:* | http://\[::1\]:*) ;;
  *) echo "refusing non-loopback oracle URL: $base_url" >&2; exit 2 ;;
esac
if [[ -n $sqlite_file ]]; then
  command -v sqlite3 >/dev/null || { echo "required command is unavailable: sqlite3" >&2; exit 1; }
  case "$sqlite_file" in
    /tmp/lmm-*/?*) ;;
    *) echo "refusing SQLite outside an isolated oracle directory: $sqlite_file" >&2; exit 2 ;;
  esac
  [[ -f $sqlite_file ]] || { echo "isolated SQLite snapshot target is missing: $sqlite_file" >&2; exit 1; }
fi
if [[ -n $postgres_url ]]; then
  command -v psql >/dev/null || { echo "required command is unavailable: psql" >&2; exit 1; }
  case "$postgres_url" in
    postgresql://localhost:*/* | postgresql://127.0.0.1:*/* | postgresql://\[::1\]:*/* | postgresql://*@localhost:*/* | postgresql://*@127.0.0.1:*/* | postgresql://*@\[::1\]:*/*) ;;
    *) echo "refusing non-loopback PostgreSQL URL" >&2; exit 2 ;;
  esac
fi
if [[ -n $redis_url ]]; then
  command -v redis-cli >/dev/null || { echo "required command is unavailable: redis-cli" >&2; exit 1; }
  case "$redis_url" in
    redis://localhost:* | redis://127.0.0.1:* | redis://\[::1\]:*) ;;
    *) echo "refusing non-loopback Valkey URL: $redis_url" >&2; exit 2 ;;
  esac
fi

workspace=$(mktemp -d /tmp/lmm-route-capture.XXXXXX)
cleanup() {
  case "$workspace" in
    /tmp/lmm-route-capture.*) rm -rf "$workspace" ;;
    *) echo "refusing to remove unexpected capture directory: $workspace" >&2 ;;
  esac
}
trap cleanup EXIT

snapshot_database() {
  if [[ -z $sqlite_file && -z $postgres_url ]]; then
    printf '{}\n'
    return
  fi
  local snapshot='{}' table rows
  while IFS= read -r table; do
    [[ $table =~ ^[a-z_]+$ ]] || { echo "unsafe SQLite table in request spec: $table" >&2; exit 1; }
    if [[ -n $sqlite_file ]]; then
      rows=$(sqlite3 -json "$sqlite_file" "SELECT * FROM \"$table\" ORDER BY rowid")
    else
      rows=$(psql "$postgres_url" -qAt -v ON_ERROR_STOP=1 -c "SELECT COALESCE(json_agg(to_jsonb(snapshot) ORDER BY to_jsonb(snapshot)::text), '[]'::json) FROM (SELECT * FROM \"$table\") AS snapshot")
    fi
    [[ -n $rows ]] || rows='[]'
    snapshot=$(jq -c --arg table "$table" --argjson rows "$rows" '. + {($table): $rows}' <<<"$snapshot")
  done < <(jq -r '.observe.db_tables[]?' "$request_file")
  printf '%s\n' "$snapshot"
}

snapshot_valkey() {
  if [[ -z $redis_url ]]; then
    printf '[]\n'
    return
  fi
  redis-cli -u "$redis_url" ping >/dev/null
  local key digest snapshot='[]'
  while IFS= read -r key; do
    [[ -n $key ]] || continue
    digest=$(redis-cli -u "$redis_url" --raw DUMP "$key" | sha256sum | cut -d' ' -f1)
    snapshot=$(jq -c --arg key "$key" --arg digest "$digest" '. + [{key: $key, digest: $digest}]' <<<"$snapshot")
  done < <(
    while IFS= read -r pattern; do
      redis-cli -u "$redis_url" --scan --pattern "$pattern"
    done < <(jq -r '.observe.valkey_patterns[]?' "$request_file") | sort -u
  )
  printf '%s\n' "$snapshot"
}

database_before=$(snapshot_database)
valkey_before=$(snapshot_valkey)

http_method=$(jq -r '.request.method' "$request_file")
route_path=$(jq -r '.request.path' "$request_file")
curl_args=(--silent --show-error --dump-header "$workspace/headers" --output "$workspace/body" --request "$http_method")
while IFS= read -r encoded; do
  header=$(base64 --decode <<<"$encoded")
  header_name=$(jq -r '.key' <<<"$header")
  header_value=$(jq -r '.value' <<<"$header")
  curl_args+=(--header "$header_name: $header_value")
done < <(jq -r '.request.headers | to_entries[] | @base64' "$request_file")
if ! jq -e '.request.body == null' "$request_file" >/dev/null; then
  curl_args+=(--data-binary "$(jq -c '.request.body' "$request_file")")
fi
curl "${curl_args[@]}" "${base_url%/}$route_path"

database_after=$(snapshot_database)
valkey_after=$(snapshot_valkey)
status=$(awk '/^HTTP\// { value=$2 } END { print value }' "$workspace/headers")
[[ $status =~ ^[1-5][0-9][0-9]$ ]] || { echo "no valid HTTP status captured from $base_url$route_path" >&2; exit 1; }

selected_headers='{}'
while IFS= read -r selected; do
  value=$(awk -v wanted="$selected" '
    BEGIN { IGNORECASE=1 }
    index($0, ":") > 0 {
      name=$0; sub(/:.*/, "", name)
      if (tolower(name) == tolower(wanted)) {
        value=$0; sub(/^[^:]+:[[:space:]]*/, "", value); sub(/\r$/, "", value)
      }
    }
    END { print value }
  ' "$workspace/headers")
  [[ -n $value ]] || continue
  selected_headers=$(jq -c --arg key "${selected,,}" --arg value "$value" '. + {($key): $value}' <<<"$selected_headers")
done < <(jq -r '.capture_headers[]' "$request_file")

content_type=$(jq -r '.["content-type"] // ""' <<<"$selected_headers")
if [[ $content_type == *text/event-stream* ]]; then
  response_body=null
  sse_frames=$(jq -Rs 'gsub("\\r"; "") | split("\n\n") | map(select(length > 0))' "$workspace/body")
elif jq -e . "$workspace/body" >/dev/null 2>&1; then
  response_body=$(jq -c . "$workspace/body")
  sse_frames='[]'
else
  response_body=$(jq -Rs . "$workspace/body")
  sse_frames='[]'
fi

database_diff=$(jq -cn --argjson before "$database_before" --argjson after "$database_after" '
  def entries($snapshot): [$snapshot | to_entries[] as $table | $table.value[] | {table: $table.key, row: .}];
  def row_key($entry):
    if $entry.row.id? != null then $entry.table + "\\u0000id=" + ($entry.row.id | tostring)
    elif $entry.row.sid? != null then $entry.table + "\\u0000sid=" + ($entry.row.sid | tostring)
    elif $entry.row.key? != null then $entry.table + "\\u0000key=" + ($entry.row.key | tostring)
    else $entry.table + "\\u0000row=" + ($entry.row | tojson)
    end;
  (entries($before)) as $before_entries |
  (entries($after)) as $after_entries |
  (INDEX($before_entries[]; row_key(.))) as $before_by_key |
  (INDEX($after_entries[]; row_key(.))) as $after_by_key |
  {
    inserted: [$after_entries[] | select($before_by_key[row_key(.)] == null)],
    updated: [$after_entries[] | . as $entry | $before_by_key[row_key($entry)] as $previous | select($previous != null and $previous.row != $entry.row) | {table: $entry.table, before: $previous.row, after: $entry.row}],
    deleted: [$before_entries[] | select($after_by_key[row_key(.)] == null)]
  }
')
valkey_diff=$(jq -cn --argjson before "$valkey_before" --argjson after "$valkey_after" '
  def by_key($items): reduce $items[] as $item ({}; .[$item.key]=$item.digest);
  (by_key($before)) as $b | (by_key($after)) as $a |
  {
    added: [$a | to_entries[] | select($b[.key] == null) | {key, digest: .value}],
    changed: [$a | to_entries[] | select($b[.key] != null and $b[.key] != .value) | {key, before_digest: $b[.key], after_digest: .value}],
    removed: [$b | to_entries[] | select($a[.key] == null) | {key, digest: .value}]
  }
')

document=$(jq -cn \
  --argjson request_spec "$(jq -c . "$request_file")" \
  --argjson status "$status" \
  --argjson headers "$selected_headers" \
  --argjson body "$response_body" \
  --argjson frames "$sse_frames" \
  --argjson database "$database_diff" \
  --argjson valkey "$valkey_diff" '
  {
    schema_version: 1,
    source: {revision: "5418ce6b6d45ed69167b0aad53f2f595e5bc8de9", synthetic: true},
    route: $request_spec.route,
    request: $request_spec.request,
    response: {status: $status, selected_headers: $headers, body: $body, sse_frames: $frames},
    effects: {database: $database, valkey: $valkey},
    normalization: $request_spec.normalization
  }
')

normalized=$(jq -c '
  def path_array($rule): $rule.path | ltrimstr("$.") | split(".");
  def getpath_or_null($path): try getpath($path) catch null;
  reduce .normalization.rules[] as $rule (.;
    (path_array($rule)) as $path |
    (getpath_or_null($path)) as $value |
    if $value == null then .
    elif $rule.operation == "replace" then setpath($path; $rule.replacement)
    elif $rule.operation == "regex_replace" then setpath($path; ($value | gsub($rule.pattern; $rule.replacement)))
    else error("unsupported normalization operation")
    end
  )
' <<<"$document")

mkdir -p "$(dirname "$output_file")"
jq . <<<"$normalized" >"$workspace/output.json"
mv "$workspace/output.json" "$output_file"
echo "captured $http_method $route_path -> $output_file"
