#!/usr/bin/env bash
set -euo pipefail

repo_root=$(git rev-parse --show-toplevel)
fixture_dir=${1:-"$repo_root/apps/api-rust/tests/behavior-oracle/fixtures"}
request_dir=${ROUTE_REQUEST_DIR:?set ROUTE_REQUEST_DIR to the isolated request observations}
require_effects=${ROUTE_REQUIRE_EFFECTS:-auto}
: "${GO_BASE_URL:?set GO_BASE_URL to the isolated legacy oracle}"
: "${RUST_BASE_URL:?set RUST_BASE_URL to the Rust service}"

for command in curl jq; do
  command -v "$command" >/dev/null || { echo "required command is unavailable: $command" >&2; exit 1; }
done
[[ -d $fixture_dir ]] || { echo "fixture directory does not exist: $fixture_dir" >&2; exit 1; }
[[ -d $request_dir ]] || { echo "request observation directory does not exist: $request_dir" >&2; exit 1; }
case "$require_effects" in auto|strict) ;; *) echo "ROUTE_REQUIRE_EFFECTS must be auto or strict" >&2; exit 2 ;; esac
for base in "$GO_BASE_URL" "$RUST_BASE_URL"; do
  [[ $base =~ ^http://(localhost|127\.0\.0\.1|\[::1\]):[0-9]+$ ]] || {
    echo "differential listeners must be explicit loopback HTTP endpoints: $base" >&2
    exit 2
  }
done
[[ $GO_BASE_URL != "$RUST_BASE_URL" ]] || {
  echo "legacy and Rust differential listeners must use distinct TCP endpoints" >&2
  exit 1
}

capture="$repo_root/apps/api-rust/tests/scripts/capture-legacy-route-contract.sh"
workspace=$(mktemp -d /tmp/lmm-route-diff.XXXXXX)
# shellcheck disable=SC2329
cleanup() {
  case "$workspace" in
    /tmp/lmm-route-diff.*) rm -rf "$workspace" ;;
    *) echo "refusing to remove unexpected diff directory: $workspace" >&2 ;;
  esac
}
trap cleanup EXIT

failed=0
for fixture in "$fixture_dir"/*.json; do
  [[ -f $fixture ]] || { echo "no JSON fixtures found in $fixture_dir" >&2; exit 1; }
  name=$(basename "$fixture" .json)
  spec="$workspace/$name-request.json"
  request_spec="$request_dir/$name.json"
  [[ -f $request_spec ]] || { echo "missing observation specification for fixture: $request_spec" >&2; exit 1; }
  jq -e -s '
    .[0] as $fixture | .[1] as $request |
    ($fixture.route.id == $request.route.id) and
    ($fixture.normalization == $request.normalization) and
    ($request.observe.db_tables | type == "array") and
    ($request.observe.valkey_patterns | type == "array")
  ' "$fixture" "$request_spec" >/dev/null || {
    echo "fixture and observation specification disagree: $name" >&2
    exit 1
  }
  jq -s '
    .[0] as $fixture | .[1] as $request |
    {
      route: $fixture.route,
      request: $fixture.request,
      observe: $request.observe,
      capture_headers: ($fixture.response.selected_headers | keys),
      normalization: $fixture.normalization
    }
  ' "$fixture" "$request_spec" >"$spec"

  observe_db=$(jq -e '.observe.db_tables | length > 0' "$spec" >/dev/null && echo true || echo false)
  observe_valkey=$(jq -e '.observe.valkey_patterns | length > 0' "$spec" >/dev/null && echo true || echo false)
  expected_db_effect=$(jq -e '[.effects.database[] | length] | add > 0' "$fixture" >/dev/null && echo true || echo false)
  expected_valkey_effect=$(jq -e '[.effects.valkey[] | length] | add > 0' "$fixture" >/dev/null && echo true || echo false)
  if [[ $require_effects == strict ]]; then
    require_db=$observe_db
    require_valkey=$observe_valkey
  else
    require_db=$expected_db_effect
    require_valkey=$expected_valkey_effect
  fi

  go_has_db=$([[ -n ${GO_SQLITE_PATH:-}${GO_POSTGRES_URL:-} ]] && echo true || echo false)
  rust_has_db=$([[ -n ${RUST_SQLITE_PATH:-}${RUST_POSTGRES_URL:-} ]] && echo true || echo false)
  go_has_valkey=$([[ -n ${GO_REDIS_URL:-} ]] && echo true || echo false)
  rust_has_valkey=$([[ -n ${RUST_REDIS_URL:-} ]] && echo true || echo false)
  if [[ $require_db == true && ($go_has_db != true || $rust_has_db != true) ]]; then
    echo "$name requires isolated database snapshots for both listeners; set GO_SQLITE_PATH/GO_POSTGRES_URL and RUST_SQLITE_PATH/RUST_POSTGRES_URL, or use the PostgreSQL 18 dual-Valkey listener harness" >&2
    exit 1
  fi
  if [[ $require_valkey == true && ($go_has_valkey != true || $rust_has_valkey != true) ]]; then
    echo "$name requires isolated Valkey snapshots for both listeners; set GO_REDIS_URL and RUST_REDIS_URL, or use the PostgreSQL 18 dual-Valkey listener harness" >&2
    exit 1
  fi

  go_capture=(--base-url "$GO_BASE_URL" --request "$spec" --output "$workspace/$name-go.json")
  rust_capture=(--base-url "$RUST_BASE_URL" --request "$spec" --output "$workspace/$name-rust.json")
  if [[ -n ${GO_SQLITE_PATH:-} ]]; then go_capture+=(--sqlite "$GO_SQLITE_PATH"); fi
  if [[ -n ${GO_POSTGRES_URL:-} ]]; then go_capture+=(--postgres-url "$GO_POSTGRES_URL"); fi
  if [[ -n ${GO_REDIS_URL:-} ]]; then go_capture+=(--redis-url "$GO_REDIS_URL"); fi
  if [[ -n ${RUST_SQLITE_PATH:-} ]]; then rust_capture+=(--sqlite "$RUST_SQLITE_PATH"); fi
  if [[ -n ${RUST_POSTGRES_URL:-} ]]; then rust_capture+=(--postgres-url "$RUST_POSTGRES_URL"); fi
  if [[ -n ${RUST_REDIS_URL:-} ]]; then rust_capture+=(--redis-url "$RUST_REDIS_URL"); fi
  "$capture" "${go_capture[@]}" >/dev/null
  "$capture" "${rust_capture[@]}" >/dev/null

  result=$(jq -cn \
    --arg fixture "$name" \
    --argjson expected "$(jq -c . "$fixture")" \
    --argjson go "$(jq -c . "$workspace/$name-go.json")" \
    --argjson rust "$(jq -c . "$workspace/$name-rust.json")" \
    --argjson go_db_observed "$([[ $observe_db == true && $go_has_db == true ]] && echo true || echo false)" \
    --argjson rust_db_observed "$([[ $observe_db == true && $rust_has_db == true ]] && echo true || echo false)" \
    --argjson go_valkey_observed "$([[ $observe_valkey == true && $go_has_valkey == true ]] && echo true || echo false)" \
    --argjson rust_valkey_observed "$([[ $observe_valkey == true && $rust_has_valkey == true ]] && echo true || echo false)" \
    --argjson observe_db "$observe_db" \
    --argjson observe_valkey "$observe_valkey" \
    --argjson require_db "$require_db" \
    --argjson require_valkey "$require_valkey" '
    ($go.response == $expected.response) as $go_response_matches |
    ($rust.response == $expected.response) as $rust_response_matches |
    ($go_db_observed and $go_valkey_observed) as $go_effects_observed |
    ($rust_db_observed and $rust_valkey_observed) as $rust_effects_observed |
    ($go.effects == $expected.effects) as $go_effects_match |
    ($rust.effects == $expected.effects) as $rust_effects_match |
    (($require_db | not) or ($go_db_observed and $rust_db_observed)) as $required_db_observed |
    (($require_valkey | not) or ($go_valkey_observed and $rust_valkey_observed)) as $required_valkey_observed |
    (($observe_db | not) or ($go_db_observed and $rust_db_observed)) as $declared_db_observed |
    (($observe_valkey | not) or ($go_valkey_observed and $rust_valkey_observed)) as $declared_valkey_observed |
    {
      fixture: $fixture,
      transport_matches_fixture: {legacy: $go_response_matches, rust: $rust_response_matches},
      differential_verified: ($go_response_matches and $rust_response_matches and $declared_db_observed and $declared_valkey_observed and $go_effects_match and $rust_effects_match),
      observation: {
        required: {database: $require_db, valkey: $require_valkey},
        legacy: {database: $go_db_observed, valkey: $go_valkey_observed, complete: $go_effects_observed},
        rust: {database: $rust_db_observed, valkey: $rust_valkey_observed, complete: $rust_effects_observed}
      },
      differences: {
        legacy_response: (if $go_response_matches then null else {expected: $expected.response, actual: $go.response} end),
        rust_response: (if $rust_response_matches then null else {expected: $expected.response, actual: $rust.response} end),
        legacy_effects: (if $go_effects_match then null else {expected: $expected.effects, actual: $go.effects} end),
        rust_effects: (if $rust_effects_match then null else {expected: $expected.effects, actual: $rust.effects} end)
      }
    }
  ')
  jq -c . <<<"$result"
  jq -e '.differential_verified or ((.observation.required.database | not) and (.observation.required.valkey | not) and .transport_matches_fixture.legacy and .transport_matches_fixture.rust)' <<<"$result" >/dev/null || failed=1
done

exit "$failed"
