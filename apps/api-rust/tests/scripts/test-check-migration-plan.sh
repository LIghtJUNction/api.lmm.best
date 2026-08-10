#!/usr/bin/env bash
set -euo pipefail

repo_root=$(git rev-parse --show-toplevel)
checker="$repo_root/apps/api-rust/tests/scripts/check-migration-plan.sh"
# shellcheck source=route-gate-fixture-lib.sh
# shellcheck disable=SC1091 # Repository root is resolved at runtime.
source "$repo_root/apps/api-rust/tests/scripts/route-gate-fixture-lib.sh"
gate="$repo_root/apps/api-rust/tests/fixtures/routes/migration-gate.tsv"
plan="$repo_root/apps/api-rust/tests/fixtures/routes/migration-plan.tsv"
runtime=$(mktemp -d /tmp/lmm-migration-gate.XXXXXX)

cleanup() {
  rm -rf "$runtime"
}
trap cleanup EXIT

checker_output=$(bash "$checker")
printf '%s\n' "$checker_output"

# The deployed Rust archive intentionally has no .git directory.  The checker
# must resolve its repository root from the script location instead of Git.
no_git_output=$(cd "$runtime" && bash "$checker")
[[ $no_git_output == *"migration plan valid: 356 frozen legacy routes covered exactly; route ownership policy satisfied"* ]] || {
  echo "migration plan checker requires Git metadata when launched outside the checkout" >&2
  exit 1
}

crlf_legacy="$runtime/legacy-go-routes.tsv"
crlf_plan="$runtime/migration-plan.tsv"
crlf_gate="$runtime/migration-gate.tsv"
crlf_review="$runtime/integration-review.tsv"
sed 's/$/\r/' "$repo_root/apps/api-rust/tests/fixtures/routes/legacy-go-routes.tsv" >"$crlf_legacy"
sed 's/$/\r/' "$plan" >"$crlf_plan"
sed 's/$/\r/' "$gate" >"$crlf_gate"
sed 's/$/\r/' "$repo_root/apps/api-rust/tests/fixtures/routes/integration-review.tsv" >"$crlf_review"
crlf_output=$(cd "$runtime" && \
  MIGRATION_LEGACY_PATH="$crlf_legacy" \
  MIGRATION_PLAN_PATH="$crlf_plan" \
  MIGRATION_GATE_PATH="$crlf_gate" \
  MIGRATION_INTEGRATION_REVIEW_PATH="$crlf_review" \
  bash "$checker")
[[ $crlf_output == *"migration plan valid: 356 frozen legacy routes covered exactly; route ownership policy satisfied"* ]] || {
  echo "migration plan checker did not normalize CRLF across all ledgers" >&2
  exit 1
}

expected_evidence='migration gate evidence: source-present=71 compiled=0 mounted=71 unmounted=285 differential-verified=0 approved=0 production-owned-rust=0 migration-credit=0'
expected_states='migration gate states: legacy-go=285 mounted-unverified=71 candidate-pending-independent-approval=0 blocked-sol-stop=0 verified-approved=0'
[[ $checker_output == *"$expected_evidence"* ]] || {
  echo "migration gate checker did not report the expected evidence counters" >&2
  exit 1
}
[[ $checker_output == *"$expected_states"* ]] || {
  echo "migration gate checker did not report the expected gate-state counters" >&2
  exit 1
}

mkdir -p "$runtime/evidence"
revision=$(git -C "$repo_root" rev-parse HEAD)
export ROUTE_GATE_FIXTURE_REVISION=$revision
export ROUTE_GATE_FIXTURE_ROUTER_PATH='apps/api-rust/src/migration_routes/api_token.rs'
route_gate_fixture_write_route "$runtime" 1 GET /api/token/
fully_verified_evidence=$ROUTE_GATE_FIXTURE_EVIDENCE
api_token_sha=$(sha256sum -- "$repo_root/apps/api-rust/src/migration_routes/api_token.rs")
api_token_sha=${api_token_sha%% *}
export MIGRATION_EVIDENCE_ROOT="$runtime"
export MIGRATION_RELEASE_REVISION="$revision"

approved_gate="$runtime/approved-api-token.tsv"
awk -F '\t' -v evidence="$fully_verified_evidence" 'BEGIN { OFS=FS }
  NR == 1 { print; next }
  !changed && $1 == "GET" && $2 == "/api/token/" {
    $3="present"; $4="verified"; $5="mounted"; $6="verified"; $7="approved"; $8="rs"; $9="verified-approved"; $10=evidence
    changed=1
  }
  { print }
  END { if (!changed) exit 1 }
' "$gate" >"$approved_gate"

approved_review="$runtime/approved-api-token-review.tsv"
{
  cat "$repo_root/apps/api-rust/tests/fixtures/routes/integration-review.tsv"
  printf 'GET\t/api/token/\tlmm_api_rs::migration_routes::api_token\taccepted listener differential\taccepted PostgreSQL evidence\taccepted Valkey evidence\tapproved\tfixture only; does not change the checked-in ledger\n'
} >"$approved_review"
if ! MIGRATION_GATE_PATH="$approved_gate" MIGRATION_INTEGRATION_REVIEW_PATH="$approved_review" bash "$checker" >/dev/null; then
  echo "migration gate checker rejected a fully evidenced independently approved Rust-owned route" >&2
  exit 1
fi

owner_mismatch_gate="$runtime/owner-mismatch.tsv"
awk -F '\t' 'BEGIN { OFS=FS }
  NR == 1 { print; next }
  !changed && $8 == "rs" { $4="unverified"; changed=1 }
  { print }
  END { if (!changed) exit 1 }
' "$approved_gate" >"$owner_mismatch_gate"
if MIGRATION_GATE_PATH="$owner_mismatch_gate" MIGRATION_INTEGRATION_REVIEW_PATH="$approved_review" \
    bash "$checker" >/dev/null 2>&1; then
  echo "migration gate checker accepted Rust ownership without independent eligibility" >&2
  exit 1
fi

missing_approval_evidence_gate="$runtime/missing-approval-evidence.tsv"
sed 's/;approval=[^;]*$//' "$approved_gate" >"$missing_approval_evidence_gate"
if MIGRATION_GATE_PATH="$missing_approval_evidence_gate" \
    MIGRATION_INTEGRATION_REVIEW_PATH="$approved_review" bash "$checker" >/dev/null 2>&1; then
  echo "migration gate checker accepted Rust ownership with missing approval evidence" >&2
  exit 1
fi

method_mismatch_review="$runtime/approval-method-mismatch.tsv"
{
  cat "$repo_root/apps/api-rust/tests/fixtures/routes/integration-review.tsv"
  printf 'POST\t/api/token/\tlmm_api_rs::migration_routes::api_token\taccepted listener differential\taccepted PostgreSQL evidence\taccepted Valkey evidence\tapproved\tfixture only\n'
} >"$method_mismatch_review"
if MIGRATION_GATE_PATH="$approved_gate" MIGRATION_INTEGRATION_REVIEW_PATH="$method_mismatch_review" bash "$checker" >/dev/null 2>&1; then
  echo "migration gate checker accepted an approval with a mismatched method" >&2
  exit 1
fi

for invalid_kind in unpinned stale-sha path-escape duplicate-key missing-file; do
  invalid_evidence_gate="$runtime/invalid-evidence-$invalid_kind.tsv"
  awk -F '\t' -v kind="$invalid_kind" -v sha="$api_token_sha" 'BEGIN { OFS=FS }
    NR == 1 { print; next }
    !changed && $1 == "GET" && $2 == "/api/token/" {
      if (kind == "unpinned") $10="mount=apps/api-rust/src/migration_routes/api_token.rs"
      if (kind == "stale-sha") $10="mount=apps/api-rust/src/migration_routes/api_token.rs@sha256:0000000000000000000000000000000000000000000000000000000000000000"
      if (kind == "path-escape") $10="mount=../apps/api-rust/src/migration_routes/api_token.rs@sha256:" sha
      if (kind == "duplicate-key") $10="mount=apps/api-rust/src/migration_routes/api_token.rs@sha256:" sha ";mount=apps/api-rust/src/migration_routes/api_token.rs@sha256:" sha
      if (kind == "missing-file") $10="mount=apps/api-rust/src/migration_routes/missing.rs@sha256:" sha
      changed=1
    }
    { print }
    END { if (!changed) exit 1 }
  ' "$approved_gate" >"$invalid_evidence_gate"
  if MIGRATION_GATE_PATH="$invalid_evidence_gate" MIGRATION_INTEGRATION_REVIEW_PATH="$approved_review" bash "$checker" >/dev/null 2>&1; then
    echo "migration gate checker accepted $invalid_kind evidence" >&2
    exit 1
  fi
done

duplicate_gate="$runtime/duplicate-method-path.tsv"
awk 'NR == 2 { first=$0 } { print } END { print first }' "$gate" >"$duplicate_gate"
if MIGRATION_GATE_PATH="$duplicate_gate" bash "$checker" >/dev/null 2>&1; then
  echo "migration gate checker accepted a duplicate method/path" >&2
  exit 1
fi

duplicate_review="$runtime/duplicate-review-method-path.tsv"
{
  cat "$repo_root/apps/api-rust/tests/fixtures/routes/integration-review.tsv"
  sed -n '2p' "$repo_root/apps/api-rust/tests/fixtures/routes/integration-review.tsv"
} >"$duplicate_review"
if MIGRATION_INTEGRATION_REVIEW_PATH="$duplicate_review" bash "$checker" >/dev/null 2>&1; then
  echo "migration gate checker accepted a duplicate integration-review method/path" >&2
  exit 1
fi

if rg -n 'auth route is not allowed|mounted models aliases must stay blocked' "$checker"; then
  echo "migration gate checker must not hard-code auth or models decisions" >&2
  exit 1
fi

if rg -q 'blocked-sol-stop' "$gate"; then
  invalid_gate="$runtime/blocked-route-claims-compile-credit.tsv"
  awk -F '\t' 'BEGIN { OFS=FS }
    NR == 1 { print; next }
    !changed && $9 == "blocked-sol-stop" {
      $4="verified"
      changed=1
    }
    { print }
    END { if (!changed) exit 1 }
  ' "$gate" >"$invalid_gate"

  if MIGRATION_GATE_PATH="$invalid_gate" bash "$checker" >/dev/null 2>&1; then
    echo "migration gate checker accepted compile credit on a blocked route" >&2
    exit 1
  fi

  invalid_blocked_set_gate="$runtime/incomplete-blocked-route-set.tsv"
  awk -F '\t' 'BEGIN { OFS=FS }
    NR == 1 { print; next }
    !changed && $9 == "blocked-sol-stop" {
      $6="unverified"
      $9="mounted-unverified"
      changed=1
    }
    { print }
    END { if (!changed) exit 1 }
  ' "$gate" >"$invalid_blocked_set_gate"

  if MIGRATION_GATE_PATH="$invalid_blocked_set_gate" bash "$checker" >/dev/null 2>&1; then
    echo "migration gate checker accepted an incomplete blocked route set" >&2
    exit 1
  fi
fi

invalid_review="$runtime/obsolete-logout-review.tsv"
sed 's#/api/user/auth/logout#/api/user/logout#' "$repo_root/apps/api-rust/tests/fixtures/routes/integration-review.tsv" >"$invalid_review"
if MIGRATION_INTEGRATION_REVIEW_PATH="$invalid_review" bash "$checker" >/dev/null 2>&1; then
  echo "migration gate checker accepted obsolete /api/user/logout evidence" >&2
  exit 1
fi

invalid_mount_gate="$runtime/missing-normalized-router-mount.tsv"
awk -F '\t' 'BEGIN { OFS=FS }
  NR == 1 { print; next }
  !changed && $1 == "GET" && $2 == "/api/token/:id" {
    $10="apps/api-rust/src/http.rs"
    changed=1
  }
  { print }
  END { if (!changed) exit 1 }
' "$gate" >"$invalid_mount_gate"

if MIGRATION_GATE_PATH="$invalid_mount_gate" bash "$checker" >/dev/null 2>&1; then
  echo "migration gate checker masked a missing Axum {id} router mount" >&2
  exit 1
fi

invalid_plan="$runtime/api-token-admin-scope.tsv"
awk -F '\t' 'BEGIN { OFS=FS }
  NR == 1 { print; next }
  !changed && $1 == "GET" && $2 == "/api/token/" {
    $5="admin"
    changed=1
  }
  { print }
  END { if (!changed) exit 1 }
' "$plan" >"$invalid_plan"

if MIGRATION_PLAN_PATH="$invalid_plan" bash "$checker" >/dev/null 2>&1; then
  echo "migration plan checker accepted admin scope for a frozen UserAuth API-token route" >&2
  exit 1
fi

root_router_fixture="$runtime/root-router.rs"
cp "$repo_root/apps/api-rust/src/http.rs" "$root_router_fixture"

invalid_unconditional_root="$runtime/root-router-unconditional.rs"
sed 's/match api_token {/let router = router.merge(mounted_api_token_router(api_token.unwrap(), api_token_legacy_headers, api_token_global_rate_limiter));\/\//; /Some(api_token) => router.merge(mounted_api_token_router(/,/None => router,/d' "$root_router_fixture" >"$invalid_unconditional_root"
if MIGRATION_ROOT_ROUTER_PATH="$invalid_unconditional_root" bash "$checker" >/dev/null 2>&1; then
  echo "migration gate checker accepted an unconditional API-token merge" >&2
  exit 1
fi

invalid_none_merge_root="$runtime/root-router-none-merge.rs"
sed 's/None => router,/None => router.merge(Router::new()),/' "$root_router_fixture" >"$invalid_none_merge_root"
if MIGRATION_ROOT_ROUTER_PATH="$invalid_none_merge_root" bash "$checker" >/dev/null 2>&1; then
  echo "migration gate checker accepted an API-token merge in the None branch" >&2
  exit 1
fi

while IFS=$'\t' read -r method path expected wrong; do
  invalid_plan="$runtime/frozen-auth-${path//\//_}.tsv"
  awk -F '\t' -v method="$method" -v path="$path" -v wrong="$wrong" 'BEGIN { OFS=FS }
    NR == 1 { print; next }
    !changed && $1 == method && $2 == path {
      $5=wrong
      changed=1
    }
    { print }
    END { if (!changed) exit 1 }
  ' "$plan" >"$invalid_plan"
  if MIGRATION_PLAN_PATH="$invalid_plan" bash "$checker" >/dev/null 2>&1; then
    echo "migration plan checker accepted wrong frozen auth scope for $method $path (expected $expected)" >&2
    exit 1
  fi
done <<'EOF'
GET	/api/mj/self	user	admin
GET	/api/models	user	admin
GET	/api/ratio_config	public	admin
GET	/api/ratio_sync/channels	root	admin
POST	/api/ratio_sync/fetch	root	admin
GET	/api/task/self	user	admin
GET	/api/usage/token/	token	admin
GET	/api/user/groups	public	user
POST	/api/user/topup/complete	admin	user
GET	/dashboard/billing/subscription	token	admin
GET	/dashboard/billing/usage	token	admin
POST	/pg/chat/completions	user	token
EOF

echo "migration gate checker tests passed"
