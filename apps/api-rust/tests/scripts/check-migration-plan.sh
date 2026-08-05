#!/usr/bin/env bash
set -euo pipefail

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
repo_root=$(cd -- "$script_dir/../../../.." && pwd -P)
legacy="${MIGRATION_LEGACY_PATH:-$repo_root/apps/api-rust/tests/fixtures/routes/legacy-go-routes.tsv}"
plan="${MIGRATION_PLAN_PATH:-$repo_root/apps/api-rust/tests/fixtures/routes/migration-plan.tsv}"
gate="${MIGRATION_GATE_PATH:-$repo_root/apps/api-rust/tests/fixtures/routes/migration-gate.tsv}"
review="${MIGRATION_INTEGRATION_REVIEW_PATH:-$repo_root/apps/api-rust/tests/fixtures/routes/integration-review.tsv}"

# Normalize command input without rewriting tracked route ledgers. This keeps
# the checker stable when a checkout preserves CRLF TSV endings.
tsv_without_crlf() {
  sed 's/\r$//' -- "$1"
}
expected_header=$'method\tpath\tlegacy_handler\tdomain\tauth_scope\tdata_access\tstreaming\tpriority\tplanned_rust_module\tjob_dependency'
expected_gate_header=$'method\tpath\tsource_state\tcompile_state\tmount_state\tdifferential_state\tapproval_state\tproduction_owner\tgate_state\tevidence'
expected_review_header=$'method\tpath\trust_handler\tlistener_differential\tpostgres_evidence\tvalkey_evidence\tdecision\tnotes'

[[ -f "$plan" ]] || { echo "missing migration plan: $plan" >&2; exit 1; }
[[ -f "$legacy" ]] || { echo "missing frozen legacy route ledger: $legacy" >&2; exit 1; }
[[ $(tsv_without_crlf "$plan" | head -n 1) == "$expected_header" ]] || { echo "invalid migration-plan header" >&2; exit 1; }

awk -F '\t' '
  function frozen_auth_scope(method, path) {
    if (method == "GET" && (path == "/api/mj/self" || path == "/api/models" || path == "/api/task/self")) return "user"
    if (method == "GET" && (path == "/api/ratio_config" || path == "/api/user/groups")) return "public"
    if (method == "GET" && (path == "/api/usage/token/" || path == "/dashboard/billing/subscription" || path == "/dashboard/billing/usage")) return "token"
    if (method == "POST" && path == "/api/user/topup/complete") return "admin"
    if (method == "POST" && path == "/pg/chat/completions") return "user"
    if ((method == "GET" && path == "/api/ratio_sync/channels") || (method == "POST" && path == "/api/ratio_sync/fetch")) return "root"
    return ""
  }
  function is_api_token_route(method, path) {
    return (method == "GET" && (path == "/api/token/" || path == "/api/token/:id" || path == "/api/token/search")) ||
      (method == "POST" && (path == "/api/token/" || path == "/api/token/:id/key" || path == "/api/token/batch" || path == "/api/token/batch/keys")) ||
      (method == "PUT" && path == "/api/token/") ||
      (method == "DELETE" && path == "/api/token/:id")
  }
  NR == 1 { next }
  NF != 10 { printf "line %d: expected 10 tab-separated fields, got %d\n", NR, NF > "/dev/stderr"; failed=1; next }
  $1 !~ /^(GET|POST|PUT|DELETE|PATCH)$/ { printf "line %d: invalid method %s\n", NR, $1 > "/dev/stderr"; failed=1 }
  $4 !~ /^(relay|media-task|identity-user|identity-auth|api-token|channel|billing|deployment|usage-audit|system-config|control-plane)$/ { printf "line %d: invalid domain %s\n", NR, $4 > "/dev/stderr"; failed=1 }
  $5 !~ /^(public|webhook|token|public-or-user|admin|root|user|user-or-token)$/ { printf "line %d: invalid auth scope %s\n", NR, $5 > "/dev/stderr"; failed=1 }
  $6 !~ /^(read|write|read-write|read-write-stream)$/ { printf "line %d: invalid access mode %s\n", NR, $6 > "/dev/stderr"; failed=1 }
  $7 !~ /^(none|websocket|sse-optional)$/ { printf "line %d: invalid streaming mode %s\n", NR, $7 > "/dev/stderr"; failed=1 }
  $8 !~ /^P[0-3]$/ { printf "line %d: invalid priority %s\n", NR, $8 > "/dev/stderr"; failed=1 }
  $9 !~ /^lmm_api_rs::routes::[a-z_]+$/ { printf "line %d: invalid planned module %s\n", NR, $9 > "/dev/stderr"; failed=1 }
  $10 !~ /^(none|deployment-runner|media-worker|relay-upstream)$/ { printf "line %d: invalid job dependency %s\n", NR, $10 > "/dev/stderr"; failed=1 }
  {
    key=$1 "\t" $2
    if (seen[key]++) { printf "line %d: duplicate route %s\n", NR, key > "/dev/stderr"; failed=1 }
    if (is_api_token_route($1, $2)) {
      api_token_routes++
      if ($5 != "user") { printf "line %d: API-token route %s must use frozen UserAuth scope user, got %s\n", NR, key, $5 > "/dev/stderr"; failed=1 }
    }
    frozen_scope = frozen_auth_scope($1, $2)
    if (frozen_scope != "" && $5 != frozen_scope) {
      printf "line %d: frozen route %s must use auth scope %s, got %s\n", NR, key, frozen_scope, $5 > "/dev/stderr"
      failed=1
    }
  }
  END {
    if (NR != 357) { printf "expected 356 routes, got %d\n", NR - 1 > "/dev/stderr"; failed=1 }
    if (api_token_routes != 9) { printf "expected 9 exact API-token authorization rows, got %d\n", api_token_routes > "/dev/stderr"; failed=1 }
    exit failed
  }
' <(tsv_without_crlf "$plan")

cut -f1-3 <(tsv_without_crlf "$plan") | tail -n +2 | diff -u <(tsv_without_crlf "$legacy") -

[[ -f "$gate" ]] || { echo "missing migration evidence gate: $gate" >&2; exit 1; }
[[ $(tsv_without_crlf "$gate" | head -n 1) == "$expected_gate_header" ]] || {
  echo "invalid migration-gate header" >&2
  exit 1
}
[[ -f "$review" ]] || { echo "missing integration review: $review" >&2; exit 1; }
[[ $(tsv_without_crlf "$review" | head -n 1) == "$expected_review_header" ]] || {
  echo "invalid integration-review header" >&2
  exit 1
}
if rg -Fq $'/api/user/logout' <(tsv_without_crlf "$gate") <(tsv_without_crlf "$review"); then
  echo "obsolete /api/user/logout must not appear in migration evidence" >&2
  exit 1
fi

awk -F '\t' '
  NR == 1 { next }
  NF != 10 { printf "gate line %d: expected 10 tab-separated fields, got %d\\n", NR, NF > "/dev/stderr"; failed=1; next }
  $3 !~ /^(absent|present)$/ { printf "gate line %d: invalid source state %s\\n", NR, $3 > "/dev/stderr"; failed=1 }
  $4 !~ /^(not-applicable|unverified|verified)$/ { printf "gate line %d: invalid compile state %s\\n", NR, $4 > "/dev/stderr"; failed=1 }
  $5 !~ /^(unmounted|mounted)$/ { printf "gate line %d: invalid mount state %s\\n", NR, $5 > "/dev/stderr"; failed=1 }
  $6 !~ /^(not-applicable|unverified|verified|blocked-sol-stop)$/ { printf "gate line %d: invalid differential state %s\\n", NR, $6 > "/dev/stderr"; failed=1 }
  $7 !~ /^(not-applicable|pending-independent-approval|approved)$/ { printf "gate line %d: invalid approval state %s\\n", NR, $7 > "/dev/stderr"; failed=1 }
  $8 != "go" { printf "gate line %d: production ownership must remain Go, got %s\\n", NR, $8 > "/dev/stderr"; failed=1 }
  $9 !~ /^(legacy-go|mounted-unverified|candidate-pending-independent-approval|blocked-sol-stop|verified-approved)$/ { printf "gate line %d: invalid gate state %s\\n", NR, $9 > "/dev/stderr"; failed=1 }
  { key=$1 "\\t" $2; if (seen[key]++) { printf "gate line %d: duplicate route key %s\\n", NR, key > "/dev/stderr"; failed=1 } }
  $5 == "mounted" && ($3 != "present" || $4 == "not-applicable") { printf "gate line %d: mounted route requires source and compile evidence\\n", NR > "/dev/stderr"; failed=1 }
  $6 == "verified" && ($4 != "verified" || $5 != "mounted") { printf "gate line %d: differential verification requires compiled and mounted evidence\\n", NR > "/dev/stderr"; failed=1 }
  $9 == "legacy-go" && ($3 != "absent" || $5 != "unmounted") { printf "gate line %d: legacy-go route cannot claim Rust source or mount\\n", NR > "/dev/stderr"; failed=1 }
  $9 == "mounted-unverified" && !($3 == "present" && $4 == "unverified" && $5 == "mounted" && $6 == "unverified" && $7 == "not-applicable") { printf "gate line %d: mounted-unverified requires no compile or differential credit\\n", NR > "/dev/stderr"; failed=1 }
  $9 == "candidate-pending-independent-approval" && !($3 == "present" && $4 == "unverified" && $5 == "mounted" && $6 == "unverified" && $7 == "pending-independent-approval") { printf "gate line %d: pending candidate requires independent approval\\n", NR > "/dev/stderr"; failed=1 }
  $9 == "blocked-sol-stop" && !($3 == "present" && $4 == "unverified" && $5 == "mounted" && $6 == "blocked-sol-stop" && $7 == "not-applicable") { printf "gate line %d: blocked route stays out of every migration credit\\n", NR > "/dev/stderr"; failed=1 }
  $9 == "verified-approved" && !($3 == "present" && $4 == "verified" && $5 == "mounted" && $6 == "verified" && $7 == "approved") { printf "gate line %d: verified-approved requires source, compile, mount, differential, and approval evidence\\n", NR > "/dev/stderr"; failed=1 }
  $9 == "verified-approved" && !($10 ~ /(^|;)source=[^;]+(;|$)/ && $10 ~ /(^|;)compile=[^;]+(;|$)/ && $10 ~ /(^|;)mount=[^;]+(;|$)/ && $10 ~ /(^|;)differential=[^;]+(;|$)/ && $10 ~ /(^|;)approval=[^;]+(;|$)/) { printf "gate line %d: verified-approved requires named source, compile, mount, differential, and approval references\\n", NR > "/dev/stderr"; failed=1 }
  END { if (NR != 357) { printf "expected 356 gate rows, got %d\\n", NR - 1 > "/dev/stderr"; failed=1 }; exit failed }
' <(tsv_without_crlf "$gate")

cut -f1-2 <(tsv_without_crlf "$gate") | tail -n +2 | diff -u <(tsv_without_crlf "$legacy" | cut -f1-2) -

evidence_value() {
  local key=$1
  local evidence=$2
  local entry
  local -a entries
  local matches=0
  local value=

  IFS=';' read -r -a entries <<<"$evidence"
  for entry in "${entries[@]}"; do
    if [[ $entry == "$key="* ]]; then
      ((matches += 1))
      value=${entry#"$key="}
    fi
  done
  [[ $matches -eq 1 ]] || return 1
  printf '%s\n' "$value"
}

validate_evidence() {
  local method=$1 path=$2 evidence=$3
  local entry evidence_key evidence_path expected_sha actual_sha
  local resolved_path
  local -a entries
  declare -A evidence_keys=()

  [[ -n $evidence ]] || {
    echo "gate $method $path requires pinned evidence" >&2
    return 1
  }
  IFS=';' read -r -a entries <<<"$evidence"
  for entry in "${entries[@]}"; do
    if [[ ! $entry =~ ^([a-z][a-z0-9_-]*)=([^@]+)@sha256:([0-9a-f]{64})$ ]]; then
      echo "gate $method $path has malformed evidence entry: $entry" >&2
      return 1
    fi
    evidence_key=${BASH_REMATCH[1]}
    evidence_path=${BASH_REMATCH[2]}
    expected_sha=${BASH_REMATCH[3]}
    if [[ ${evidence_keys[$evidence_key]+x} ]]; then
      echo "gate $method $path has duplicate evidence key: $evidence_key" >&2
      return 1
    fi
    evidence_keys[$evidence_key]=1
    if [[ $evidence_path == /* || $evidence_path == *'..'* || $evidence_path == ./* || $evidence_path == *'//' ]]; then
      echo "gate $method $path has unsafe evidence path: $evidence_path" >&2
      return 1
    fi
    evidence_file="$repo_root/$evidence_path"
    [[ -f $evidence_file ]] || {
      echo "gate $method $path names missing evidence: $evidence_path" >&2
      return 1
    }
    resolved_path=$(realpath -e --relative-to="$repo_root" -- "$evidence_file") || {
      echo "gate $method $path cannot resolve evidence path: $evidence_path" >&2
      return 1
    }
    [[ $resolved_path == "$evidence_path" ]] || {
      echo "gate $method $path evidence must stay inside the repository: $evidence_path" >&2
      return 1
    }
    actual_sha=$(sha256sum -- "$evidence_file")
    actual_sha=${actual_sha%% *}
    [[ $actual_sha == "$expected_sha" ]] || {
      echo "gate $method $path has stale evidence SHA-256: $evidence_path" >&2
      return 1
    }
  done
}

validate_evidence_keys() {
  local method=$1 path=$2 evidence=$3 entry evidence_key
  local -a entries
  declare -A evidence_keys=()

  [[ -n $evidence ]] || return 0
  IFS=';' read -r -a entries <<<"$evidence"
  for entry in "${entries[@]}"; do
    [[ $entry == *=* ]] || {
      [[ ${#entries[@]} -eq 1 ]] && return 0
      echo "gate $method $path has malformed legacy evidence entry: $entry" >&2
      return 1
    }
    evidence_key=${entry%%=*}
    [[ $evidence_key =~ ^[a-z][a-z0-9_-]*$ ]] || {
      echo "gate $method $path has malformed evidence key: $evidence_key" >&2
      return 1
    }
    if [[ ${evidence_keys[$evidence_key]+x} ]]; then
      echo "gate $method $path has duplicate evidence key: $evidence_key" >&2
      return 1
    fi
    evidence_keys[$evidence_key]=1
  done
}

normalize_ledger_path() {
  case $1 in
    /api/token/:id) printf '%s\n' '/api/token/{id}' ;;
    /api/token/:id/key) printf '%s\n' '/api/token/{id}/key' ;;
    # GET, POST, and the one permitted explicit-501 DELETE share the same
    # collision-free Axum MethodRouter at this exact single-segment path.
    /v1/models/:model) printf '%s\n' '/v1/models/{model}' ;;
    *:*) return 1 ;;
    *) printf '%s\n' "$1" ;;
  esac
}

is_frozen_model_delete_501() {
  [[ $1 == DELETE && $2 == /v1/models/:model ]]
}

require_frozen_model_delete_501_evidence() {
  local method=$1 path=$2 source_state=$3 compile_state=$4 mount_state=$5
  local differential_state=$6 approval_state=$7 owner=$8 gate_state=$9 evidence=${10}
  local expected_handler='github.com/QuantumNous/new-api/controller.RelayNotImplemented'
  local handler_count differential_reference differential_path validator

  is_frozen_model_delete_501 "$method" "$path" || return 1
  [[ $source_state == present && $compile_state == verified && $mount_state == mounted \
    && $differential_state == verified && $approval_state == approved && $owner == go \
    && $gate_state == verified-approved ]] || {
    echo "frozen DELETE /v1/models/:model 501 requires fully verified-approved gate state" >&2
    return 1
  }
  handler_count=$(awk -F '\t' -v method="$method" -v path="$path" -v handler="$expected_handler" '
    $1 == method && $2 == path && $3 == handler { count++ }
    END { print count + 0 }
  ' <(tsv_without_crlf "$legacy"))
  [[ $handler_count == 1 ]] || {
    echo "frozen DELETE /v1/models/:model 501 must match exactly one RelayNotImplemented Go owner" >&2
    return 1
  }
  differential_reference=$(evidence_value differential "$evidence") || {
    echo "frozen DELETE /v1/models/:model 501 has no differential evidence" >&2
    return 1
  }
  [[ $differential_reference == *@sha256:* ]] || {
    echo "frozen DELETE /v1/models/:model 501 differential evidence requires SHA-256 pinning" >&2
    return 1
  }
  differential_path=${differential_reference%@sha256:*}
  validator="$repo_root/apps/api-rust/tests/behavior-oracle/tests/validate-frozen-model-delete-501-evidence.sh"
  [[ -x $validator ]] || { echo "missing frozen DELETE 501 evidence validator" >&2; return 1; }
  "$validator" "$repo_root/$differential_path"
}

while IFS=$'\t' read -r method path source_state compile_state mount_state differential_state approval_state owner gate_state evidence; do
  validate_evidence_keys "$method" "$path" "$evidence" || exit 1
  if [[ $compile_state == verified || $differential_state == verified || $approval_state == approved ]]; then
    validate_evidence "$method" "$path" "$evidence" || exit 1
  fi
done < <(awk -F '\t' 'NR > 1 { print }' <(tsv_without_crlf "$gate"))

awk -F '\t' '
  NR == 1 { next }
  NF != 8 { printf "review line %d: expected 8 tab-separated fields, got %d\\n", NR, NF > "/dev/stderr"; failed=1; next }
  $1 !~ /^(GET|POST|PUT|DELETE|PATCH)$/ { printf "review line %d: invalid method %s\\n", NR, $1 > "/dev/stderr"; failed=1 }
  $2 == "" { printf "review line %d: empty path\\n", NR > "/dev/stderr"; failed=1 }
  {
    key=$1 "\\t" $2
    if (seen[key]++) { printf "review line %d: duplicate method/path %s\\n", NR, key > "/dev/stderr"; failed=1 }
  }
  END { exit failed }
' <(tsv_without_crlf "$review")

while IFS=$'\t' read -r method path approval_state evidence; do
  [[ $approval_state == approved ]] || continue
  evidence_value approval "$evidence" >/dev/null || {
    echo "approved $method $path has no unique approval evidence reference" >&2
    exit 1
  }
  review_approval_count=$(awk -F '\t' -v method="$method" -v path="$path" '
    NR > 1 && $1 == method && $2 == path && $7 == "approved" { count++ }
    END { print count + 0 }
  ' <(tsv_without_crlf "$review"))
  [[ $review_approval_count -eq 1 ]] || {
    echo "approved $method $path lacks one exact approved integration-review record" >&2
    exit 1
  }
done < <(awk -F '\t' 'NR > 1 { print $1 "\t" $2 "\t" $7 "\t" $10 }' <(tsv_without_crlf "$gate"))

while IFS=$'\t' read -r method path source_state compile_state mount_state differential_state approval_state owner gate_state evidence; do
  router_evidence=$evidence
  if [[ $evidence == *"mount="* ]]; then
    router_evidence=$(evidence_value mount "$evidence") || {
      echo "mounted $method $path has no unique mount reference in evidence" >&2
      exit 1
    }
    router_evidence=${router_evidence%@sha256:*}
  fi
  source_file="$repo_root/$router_evidence"
  [[ -f $source_file ]] || { echo "mounted $method $path names missing router source: $router_evidence" >&2; exit 1; }
  router_path=$(normalize_ledger_path "$path") || {
    echo "mounted $method $path uses an unsupported ledger/router parameter syntax" >&2
    exit 1
  }
  grep -Fq -- ".route(\"$router_path\"" "$source_file" || {
    echo "mounted $method $path lacks exact router mount $router_path in $router_evidence" >&2
    exit 1
  }
  if rg -q -i 'StatusCode::NOT_IMPLEMENTED|not[_ -]?implemented|(^|[^0-9])501([^0-9]|$)' "$source_file"; then
    if is_frozen_model_delete_501 "$method" "$path"; then
      require_frozen_model_delete_501_evidence "$method" "$path" "$source_state" "$compile_state" "$mount_state" "$differential_state" "$approval_state" "$owner" "$gate_state" "$evidence" || exit 1
    else
      echo "mounted $method $path has a stub/501 marker in $router_evidence" >&2
      exit 1
    fi
  fi
done < <(awk -F '\t' 'NR > 1 && $5 == "mounted" { print }' <(tsv_without_crlf "$gate"))

expected_root_mounts=$'GET\t/api/about\nGET\t/api/home_page_content\nGET\t/api/notice\nGET\t/api/status\nGET\t/api/token/\nPOST\t/api/token/\nPUT\t/api/token/\nDELETE\t/api/token/:id\nGET\t/api/token/:id\nPOST\t/api/token/:id/key\nPOST\t/api/token/batch\nPOST\t/api/token/batch/keys\nGET\t/api/token/search\nGET\t/api/user/self\nPOST\t/api/user/auth/logout\nPOST\t/api/user/auth/refresh\nPOST\t/api/user/login\nGET\t/v1/models\nGET\t/v1beta/models\nGET\t/v1beta/openai/models'
actual_root_mounts=$(awk -F '\t' 'NR > 1 && $5 == "mounted" { print $1 "\t" $2 }' <(tsv_without_crlf "$gate") | LC_ALL=C sort)
diff -u <(printf '%s\n' "$expected_root_mounts" | LC_ALL=C sort) <(printf '%s\n' "$actual_root_mounts") || {
  echo "migration gate root mount inventory must contain exactly 20 authorized local Rust routes" >&2
  exit 1
}

expected_blocked_routes=$'GET\t/api/status\nPOST\t/api/user/auth/logout\nPOST\t/api/user/auth/refresh\nPOST\t/api/user/login\nGET\t/api/user/self\nGET\t/v1/models\nGET\t/v1beta/models\nGET\t/v1beta/openai/models'
actual_blocked_routes=$(awk -F '\t' 'NR > 1 && $9 == "blocked-sol-stop" { print $1 "\t" $2 }' <(tsv_without_crlf "$gate") | LC_ALL=C sort)
diff -u <(printf '%s\n' "$expected_blocked_routes" | LC_ALL=C sort) <(printf '%s\n' "$actual_blocked_routes") || {
  echo "migration gate must block exactly the eight routes stopped by the latest independent Sol review" >&2
  exit 1
}
actual_review_blocks=$(awk -F '\t' 'NR > 1 && $7 == "blocked-sol-stop" { print $1 "\t" $2 }' <(tsv_without_crlf "$review") | LC_ALL=C sort)
diff -u <(printf '%s\n' "$expected_blocked_routes" | LC_ALL=C sort) <(printf '%s\n' "$actual_review_blocks") || {
  echo "integration review must record exactly the eight current Sol STOP routes" >&2
  exit 1
}

candidate_dir="$repo_root/apps/api-rust/src/migration_routes"
mapfile -t candidate_files < <(rg --files "$candidate_dir")
candidate_count=${#candidate_files[@]}
candidate_mod="$repo_root/apps/api-rust/src/migration_routes.rs"
mapfile -t declared_candidates < <(
  awk '/^pub mod [a-z0-9_]+;$/ { name=$3; sub(/;$/, "", name); print name }' "$candidate_mod" |
    LC_ALL=C sort
)
declared_candidate_count=${#declared_candidates[@]}
mapfile -t candidate_names < <(
  printf '%s\n' "${candidate_files[@]}" |
    tr '\\\\' '/' |
    sed -E 's#^.*/##; s#\.rs$##' |
    LC_ALL=C sort
)
diff -u <(printf '%s\n' "${declared_candidates[@]}") <(printf '%s\n' "${candidate_names[@]}") || {
  echo "candidate module declarations and source files differ" >&2
  exit 1
}
candidate_router_count=$(rg -l 'pub fn [a-z_]+\([^)]*\) -> Router' "${candidate_files[@]}" | wc -l)
[[ $candidate_count -eq $declared_candidate_count && $candidate_router_count -eq $candidate_count ]] || {
  echo "expected every declared candidate module to expose one router, found $candidate_router_count/$declared_candidate_count" >&2
  exit 1
}
root_router="${MIGRATION_ROOT_ROUTER_PATH:-$repo_root/apps/api-rust/src/http.rs}"
[[ -f $root_router ]] || { echo "missing production root router: $root_router" >&2; exit 1; }
production_root=$(awk '
  /^[[:space:]]*mod[[:space:]]+tests[[:space:]]*\{/ { boundary=1; exit }
  { print }
  END { if (!boundary) exit 1 }
' "$root_router") || {
  echo "production root router is missing its mod tests boundary" >&2
  exit 1
}
api_import_block=$(printf '%s\n' "$production_root" | awk '
  /^use lmm_api_rs::\{/ {
    if (found++) exit 1
    capture=1
  }
  capture { print }
  capture && /^};$/ { capture=0; closed=1 }
  END { if (found != 1 || !closed || capture) exit 1 }
') || {
  echo "production root router must contain one closed lmm_api_rs grouped import" >&2
  exit 1
}
api_import_compact=$(printf '%s\n' "$api_import_block" | tr -d '[:space:]')
production_root_compact=$(printf '%s\n' "$production_root" | tr -d '[:space:]')
allowed_candidate_import='migration_routes::api_token::{ApiTokenHttpState,ApiTokenPrincipal,api_token_router},'
[[ $api_import_compact == *"$allowed_candidate_import"* ]] || {
  echo "production root router must import exactly the audited api-token symbols" >&2
  exit 1
}
production_without_allowed_import=${production_root_compact/"$allowed_candidate_import"/}
if [[ $production_without_allowed_import == *"migration_routes::"* ]]; then
  echo "only the audited api-token candidate may be imported or referenced before mod tests" >&2
  exit 1
fi
api_token_match_count=$(printf '%s\n' "$production_root_compact" | rg -o 'matchapi_token\{' | wc -l)
[[ $api_token_match_count -eq 1 ]] || {
  echo "production root router must contain exactly one api-token match" >&2
  exit 1
}
api_token_match_suffix=${production_root_compact#*matchapi_token\{}
api_token_match_body="matchapi_token{${api_token_match_suffix%%\}*}}"
expected_api_token_match='matchapi_token{Some(api_token)=>router.merge(mounted_api_token_router(api_token,api_token_legacy_headers,api_token_global_rate_limiter,)),None=>router,}'
[[ $api_token_match_body == "$expected_api_token_match" ]] || {
  echo "production root router must contain the exact audited api-token conditional merge" >&2
  exit 1
}
mounted_api_token_references=$(printf '%s\n' "$production_root" | rg -o 'mounted_api_token_router' | wc -l)
[[ $mounted_api_token_references -eq 2 ]] || {
  echo "mounted_api_token_router must have exactly one production definition and one conditional merge" >&2
  exit 1
}
api_token_router_mounts=$(printf '%s\n' "$production_root" | rg -o 'api_token_router\(mount\.state\.clone\(\)\)' | wc -l)
[[ $api_token_router_mounts -eq 1 ]] || {
  echo "production root router must contain exactly one audited api_token_router mount" >&2
  exit 1
}
root_merge_count=$(printf '%s\n' "$production_root" | rg -n '^[[:space:]]*\.merge\(' | wc -l)
[[ $root_merge_count -eq 2 ]] ||
  { echo "production root router must have exactly auth and models merges, found $root_merge_count" >&2; exit 1; }
if ! grep -Fq '.merge(auth)' <<<"$production_root" ||
  ! grep -Fq '.merge(models_router(models))' <<<"$production_root"; then
  echo "production root router merge topology is not the audited auth-plus-models shape" >&2
  exit 1
fi
echo "production root topology: 20 authorized local Rust mounts; api-token is the sole mounted candidate; $((candidate_count - 1)) candidates remain unmounted"

awk -F '\t' '
  NR == 1 { next }
  {
    state[$9]++
    source += $3 == "present"
    compiled += $4 == "verified"
    mounted += $5 == "mounted"
    unmounted += $5 == "unmounted"
    differential += $6 == "verified"
    approved += $7 == "approved"
    production += $8 == "rust"
  }
  END {
    if (production != 0) {
      printf "unexpected migration credit counters: source-present=%d compiled=%d mounted=%d unmounted=%d differential-verified=%d approved=%d production-owned-rust=%d\n", source, compiled, mounted, unmounted, differential, approved, production > "/dev/stderr"
      exit 1
    }
    printf "migration gate evidence: source-present=%d compiled=%d mounted=%d unmounted=%d differential-verified=%d approved=%d production-owned-rust=%d migration-credit=%d\n", source, compiled, mounted, unmounted, differential, approved, production, production
    printf "migration gate states: legacy-go=%d mounted-unverified=%d candidate-pending-independent-approval=%d blocked-sol-stop=%d verified-approved=%d\n", state["legacy-go"], state["mounted-unverified"], state["candidate-pending-independent-approval"], state["blocked-sol-stop"], state["verified-approved"]
  }
' <(tsv_without_crlf "$gate")

echo "migration plan valid: 356 frozen legacy routes covered exactly; production ownership remains Go"
