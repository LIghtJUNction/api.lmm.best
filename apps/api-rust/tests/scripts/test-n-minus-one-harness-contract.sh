#!/usr/bin/env bash
set -Eeuo pipefail

repo=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../../../.." && pwd -P)
# shellcheck source=n-minus-one-harness-lib.sh
# shellcheck disable=SC1091 # Repository root is resolved at runtime.
source "$repo/apps/api-rust/tests/scripts/n-minus-one-harness-lib.sh"

for command_name in jq stat rg sha256sum; do
  command -v "$command_name" >/dev/null || { echo "missing required command: $command_name" >&2; exit 1; }
done
bash -n "$repo/apps/api-rust/tests/scripts/run-isolated-real-integration-gates.sh" \
  "$repo/apps/api-rust/tests/scripts/n-minus-one-harness-lib.sh"

runtime=$(mktemp -d "$repo/.n-minus-one-contract.XXXXXXXX")
trap 'rm -rf -- "$runtime"' EXIT
result="$runtime/result.json"
jq -cn '{schema_version:1,revision:"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",operation:"read",iteration:1,passed:true,checks:{auth_session:{passed:true,observations:["session row and cache agree"]},token_cache_ttl_invalidation:{passed:true,observations:["token cache expires and invalidates"]},model_cache_ttl_invalidation:{passed:true,observations:["model cache expires and invalidates"]},quota_billing:{passed:true,observations:["quota and billing remain durable"]},channel_provider_inventory:{passed:true,observations:["channel and provider inventory remains stable"]}}}' >"$result"
lmm_n1_validate_result "$result" bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb read 1
jq '.checks.auth_session.passed = false' "$result" >"$result.bad"
if lmm_n1_validate_result "$result.bad" bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb read 1 >/dev/null 2>&1; then
  echo 'failed verifier slice was accepted' >&2; exit 1
fi
jq '.checks.auth_session.observations = ["postgresql://user:secret@127.0.0.1/db"]' "$result" >"$result.secret"
if lmm_n1_validate_result "$result.secret" bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb read 1 >/dev/null 2>&1; then
  echo 'credential-bearing verifier evidence was accepted' >&2; exit 1
fi
clock="$runtime/clock"
printf '%s\n' 100 100 701 >"$clock"
export LMM_N1_TEST_MONOTONIC_FILE="$clock" LMM_N1_LAST_MONOTONIC_FILE="$runtime/monotonic.last" \
  LMM_N1_CONTRACT_TEST_MODE=1
[[ $(lmm_n1_monotonic_seconds) == 100 ]]
[[ $(lmm_n1_monotonic_seconds) == 100 ]]
[[ $(lmm_n1_monotonic_seconds) == 701 ]]
printf '9\n' >"$clock"
if lmm_n1_monotonic_seconds >/dev/null 2>&1; then
  echo 'backwards simulated clock was accepted' >&2; exit 1
fi
echo 'N/N-1 harness contract tests passed'
