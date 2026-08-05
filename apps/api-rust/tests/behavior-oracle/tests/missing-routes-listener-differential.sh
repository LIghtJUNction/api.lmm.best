#!/usr/bin/env bash
# Frozen listener-boundary differential for the 56 routes completed in the
# missing-* migration batch.  This file deliberately does not start a server:
# callers must provide two distinct, isolated loopback listeners.  In
# particular, it cannot accidentally exercise a production test deployment.
set -euo pipefail

repo_root=$(git rev-parse --show-toplevel)
matrix=${MISSING_ROUTES_MATRIX:-"$repo_root/apps/api-rust/tests/behavior-oracle/tests/missing-routes-matrix.tsv"}
mode=${MISSING_ROUTES_MODE:-preflight}
include_classes=${MISSING_ROUTES_INCLUDE_CLASSES:-"no-side-effect,database-transaction,external-gateway"}

for command in awk curl jq sort; do
  command -v "$command" >/dev/null || {
    echo "required command is unavailable: $command" >&2
    exit 1
  }
done
[[ -f $matrix ]] || { echo "missing route matrix: $matrix" >&2; exit 1; }
case "$mode" in preflight|transport) ;; *) echo "MISSING_ROUTES_MODE must be preflight or transport" >&2; exit 2 ;; esac
case ",$include_classes," in
  *",no-side-effect,"*|*",database-transaction,"*|*",external-gateway,"*) ;;
  *) echo "MISSING_ROUTES_INCLUDE_CLASSES selects no known class" >&2; exit 2 ;;
esac
for class in ${include_classes//,/ }; do
  [[ $class =~ ^(no-side-effect|database-transaction|external-gateway)$ ]] || {
    echo "unknown selected class: $class" >&2
    exit 2
  }
done

class_is_selected() { [[ ",$include_classes," == *",$1,"* ]]; }

# Matrix integrity is intentionally checked against the immutable Go route
# inventory.  The final three paths are the still-deferred wildcard/explicit
# 501 relay boundary; they stay visible rather than being silently omitted.
legacy="$repo_root/apps/api-rust/tests/fixtures/routes/legacy-go-routes.tsv"
[[ -f $legacy ]] || { echo "missing frozen legacy manifest: $legacy" >&2; exit 1; }
awk -F '\t' '
  /^#/ || NF == 0 { next }
  NF != 6 { printf "malformed matrix line %d\n", FNR > "/dev/stderr"; exit 1 }
  $1 !~ /^(no-side-effect|database-transaction|external-gateway)$/ { printf "unknown matrix class at line %d\n", FNR > "/dev/stderr"; exit 1 }
  $2 !~ /^(GET|POST|DELETE)$/ { printf "unknown method at line %d\n", FNR > "/dev/stderr"; exit 1 }
  $5 !~ /^(transport-anonymous|invalid-webhook)$/ { printf "unknown auth fixture at line %d\n", FNR > "/dev/stderr"; exit 1 }
  {
    route_key=$2 "\t" $3
    if (seen[route_key]++) { printf "duplicate matrix route: %s\n", route_key > "/dev/stderr"; exit 1 }
    count[$1]++
    total++
    print route_key
  }
  END {
    if (total != 56 || count["no-side-effect"] != 22 || count["database-transaction"] != 7 || count["external-gateway"] != 27) {
      printf "unexpected matrix counts: total=%d no-side-effect=%d database-transaction=%d external-gateway=%d\n", total, count["no-side-effect"], count["database-transaction"], count["external-gateway"] > "/dev/stderr"
      exit 1
    }
  }
' "$matrix" > /tmp/lmm-missing-routes-matrix.$$.keys
trap 'rm -f /tmp/lmm-missing-routes-matrix.$$.keys' EXIT
while IFS=$'\t' read -r method path; do
  if ! awk -F '\t' -v method="$method" -v path="$path" '$1 == method && $2 == path { found=1 } END { exit !found }' "$legacy"; then
    echo "matrix route is absent from frozen legacy manifest: $method $path" >&2
    exit 1
  fi
done < /tmp/lmm-missing-routes-matrix.$$.keys

if [[ $mode == preflight ]]; then
  jq -cn --arg selected "$include_classes" '{test:"missing-routes-matrix",routes:56,selected_classes:$selected,classes:{no_side_effect:22,database_transaction:7,external_gateway:27},transport_ready:true,approval_credit:false,reason:"positive transaction fixtures and injected gateway fixtures are required before any route may be approved"}'
  exit 0
fi

: "${GO_BASE_URL:?set GO_BASE_URL to the isolated legacy listener}"
: "${RUST_BASE_URL:?set RUST_BASE_URL to the isolated Rust test-instance listener}"
for base in "$GO_BASE_URL" "$RUST_BASE_URL"; do
  [[ $base =~ ^http://(localhost|127\.0\.0\.1|\[::1\]):[0-9]+$ ]] || {
    echo "missing-route differential listeners must be loopback HTTP endpoints: $base" >&2
    exit 2
  }
done
[[ $GO_BASE_URL != "$RUST_BASE_URL" ]] || { echo "legacy and Rust listeners must differ" >&2; exit 1; }

runtime=$(mktemp -d /tmp/lmm-missing-routes-diff.XXXXXX)
cleanup() {
  case "$runtime" in /tmp/lmm-missing-routes-diff.*) rm -rf "$runtime" ;; *) echo "refusing unexpected runtime: $runtime" >&2 ;; esac
}
trap cleanup EXIT
mkdir -p "$runtime/fixtures" "$runtime/requests"

# Capture the Go fixture immediately before replay.  This is a synthetic
# boundary fixture, not a golden approval artifact: the selected headers and
# normalized body are still independently compared against the Rust listener.
# All requests are unauthenticated or intentionally invalid, so this runner
# neither performs a transaction nor reaches an upstream gateway.
index=0
while IFS=$'\t' read -r class method frozen_path request_path auth_case body; do
  [[ -n ${class:-} && $class != \#* ]] || continue
  class_is_selected "$class" || continue
  ((index += 1))
  name=$(printf '%03d' "$index")
  headers='{"accept":"application/json"}'
  if [[ $body != null ]]; then headers='{"accept":"application/json","content-type":"application/json"}'; fi
  if [[ $auth_case == invalid-webhook ]]; then headers=$(jq -c '. + {"x-signature":"invalid-oracle-signature"}' <<<"$headers"); fi
  jq -cn --arg id "$method $frozen_path" --arg method "$method" --arg path "$request_path" --argjson headers "$headers" --argjson body "$body" '
    {
      route:{id:$id,middleware:["frozen-listener-boundary"],side_effects:[]},
      request:{method:$method,path:$path,headers:$headers,body:$body},
      observe:{db_tables:[],valkey_patterns:[]},
      capture_headers:["content-type","x-new-api-version","x-oneapi-request-id"],
      normalization:{rules:[
        {path:"$.response.selected_headers.x-oneapi-request-id",operation:"replace",replacement:"<REQUEST_ID>",reason:"request id is generated independently by each listener"},
        {path:"$.response.body.error.message",operation:"regex_replace",pattern:"\\(request id: [^)]+\\)",replacement:"(request id: <REQUEST_ID>)",reason:"legacy relay errors embed the generated request id in the body"}
      ]}
    }
  ' > "$runtime/requests/$name.json"
  "$repo_root/apps/api-rust/tests/scripts/capture-legacy-route-contract.sh" \
    --base-url "$GO_BASE_URL" --request "$runtime/requests/$name.json" \
    --output "$runtime/fixtures/$name.json" >/dev/null
done < "$matrix"

# Strict mode here means every declared observation is captured.  The
# transport fixtures intentionally declare no DB/Valkey observations; they
# are therefore not evidence for the seven transaction routes' successful
# commit/rollback behavior.
ROUTE_REQUEST_DIR="$runtime/requests" ROUTE_REQUIRE_EFFECTS=strict \
  "$repo_root/apps/api-rust/tests/scripts/run-route-differential.sh" "$runtime/fixtures" | tee "$runtime/results.jsonl"
verified=$(jq -s '[.[] | select(.differential_verified)] | length' "$runtime/results.jsonl")
jq -cn --argjson routes "$index" --argjson verified "$verified" --arg selected "$include_classes" '{test:"missing-routes-listener-boundary",routes:$routes,selected_classes:$selected,transport_matches: $verified,approval_credit:false,reason:"all captures use anonymous or invalid-webhook fail-closed fixtures; transaction success and provider fixtures remain required"}'
