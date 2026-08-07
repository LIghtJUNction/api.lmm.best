#!/usr/bin/env bash

# Shared, side-effect-free validation helpers for the real N/N-1 harness.

lmm_n1_die() {
  printf 'lmm-n-minus-one: %s\n' "$*" >&2
  return 1
}

lmm_n1_valid_sha256() {
  [[ $1 =~ ^[0-9a-f]{64}$ && $1 != 0000000000000000000000000000000000000000000000000000000000000000 ]]
}

lmm_n1_valid_revision() {
  [[ $1 =~ ^[0-9a-fA-F]{7,64}$ ]]
}

lmm_n1_validate_result() {
  local file=$1 expected_revision=$2 expected_operation=$3 expected_iteration=$4
  local max_bytes=$((64 * 1024)) size
  [[ -f $file && ! -L $file ]] || { lmm_n1_die 'verifier did not emit a regular result file'; return 1; }
  size=$(stat -c %s -- "$file") || return 1
  ((size > 0 && size <= max_bytes)) || { lmm_n1_die 'verifier result is empty or exceeds 64 KiB'; return 1; }
  jq -e --arg revision "$expected_revision" --arg operation "$expected_operation" \
    --argjson iteration "$expected_iteration" '
      def passed_slice:
        type == "object" and .passed == true and
        (keys == ["observations","passed"]) and
        ((.observations // []) | type == "array" and length <= 32 and
          all(.[]; type == "string" and length > 0 and length <= 256));
      (keys == ["checks","iteration","operation","passed","revision","schema_version"]) and
      .schema_version == 1 and .passed == true and .revision == $revision and
      .operation == $operation and .iteration == $iteration and
      (.checks | keys == ["auth_session","channel_provider_inventory","model_cache_ttl_invalidation","quota_billing","token_cache_ttl_invalidation"]) and
      (.checks.auth_session | passed_slice) and
      (.checks.token_cache_ttl_invalidation | passed_slice) and
      (.checks.model_cache_ttl_invalidation | passed_slice) and
      (.checks.quota_billing | passed_slice) and
      (.checks.channel_provider_inventory | passed_slice)
    ' "$file" >/dev/null || { lmm_n1_die 'verifier result does not satisfy the compatibility evidence contract'; return 1; }
  if LC_ALL=C rg -i -n \
    'postgres(ql)?://|redis(s)?://|authorization:[[:space:]]*bearer|set-cookie:|-----BEGIN [A-Z ]*PRIVATE KEY-----|access[_ -]?token[=:]|refresh[_ -]?token[=:]|client[_ -]?secret[=:]' \
    "$file" >/dev/null; then
    lmm_n1_die 'verifier result contains a prohibited credential or connection-string field'
    return 1
  fi
}

lmm_n1_monotonic_seconds() {
  local value
  if [[ -n ${LMM_N1_TEST_MONOTONIC_FILE:-} ]]; then
    [[ ${LMM_N1_CONTRACT_TEST_MODE:-0} == 1 ]] || { lmm_n1_die 'simulated clock is contract-test-only'; return 1; }
    IFS= read -r value <"$LMM_N1_TEST_MONOTONIC_FILE" || { lmm_n1_die 'simulated clock is exhausted'; return 1; }
    [[ $value =~ ^[0-9]+$ ]] || { lmm_n1_die 'simulated clock value is invalid'; return 1; }
    sed -i '1d' -- "$LMM_N1_TEST_MONOTONIC_FILE"
  else
    value=$(awk '{ printf "%d\n", $1 }' /proc/uptime)
  fi
  local previous=''
  if [[ -n ${LMM_N1_LAST_MONOTONIC_FILE:-} && -s $LMM_N1_LAST_MONOTONIC_FILE ]]; then
    IFS= read -r previous <"$LMM_N1_LAST_MONOTONIC_FILE" || return 1
  elif [[ -n ${LMM_N1_LAST_MONOTONIC:-} ]]; then
    previous=$LMM_N1_LAST_MONOTONIC
  fi
  if [[ -n $previous && $value -lt $previous ]]; then
    lmm_n1_die 'monotonic clock moved backwards'
    return 1
  fi
  if [[ -n ${LMM_N1_LAST_MONOTONIC_FILE:-} ]]; then
    printf '%s\n' "$value" >"$LMM_N1_LAST_MONOTONIC_FILE"
  else
    LMM_N1_LAST_MONOTONIC=$value
  fi
  printf '%s\n' "$value"
}
