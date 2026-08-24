#!/usr/bin/env bash
set -Eeuo pipefail

ROOT=$(git rev-parse --show-toplevel)
SCRIPT="$ROOT/scripts/verify-release-commit-checks.sh"
REQUIRED="$ROOT/.github/required-release-checks.txt"
REVISION=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa

tmp=$(mktemp -d)
cleanup() { rm -rf -- "$tmp"; }
trap cleanup EXIT

write_fixture() {
  local conclusion=$1 failed_name=${2:-}
  {
    printf '{"check_runs":['
    separator=
    id=100
    while IFS= read -r name; do
      [[ -n $name ]] || continue
      current=$conclusion
      [[ $name == "$failed_name" ]] && current=failure
      printf '%s' "$separator"
      jq -cn --arg name "$name" --arg conclusion "$current" --argjson id "$id" \
        '{id:$id,name:$name,status:"completed",conclusion:$conclusion,app:{slug:"github-actions"}}'
      separator=,
      ((id += 1))
    done <"$REQUIRED"
    printf ']}\n'
  } >"$tmp/checks.json"
}

write_fixture success
LMM_CHECK_RUNS_FILE="$tmp/checks.json" LMM_CHECK_MAX_ATTEMPTS=1 \
  bash "$SCRIPT" "$REVISION" >/dev/null

failed_name='Release artifact contract'
write_fixture success "$failed_name"
if LMM_CHECK_RUNS_FILE="$tmp/checks.json" LMM_CHECK_MAX_ATTEMPTS=1 \
  bash "$SCRIPT" "$REVISION" >"$tmp/failure.out" 2>&1; then
  printf 'negative governance fixture unexpectedly accepted a failed release check\n' >&2
  exit 1
fi
grep -Fq "$failed_name (failure)" "$tmp/failure.out"

write_fixture success
jq 'del(.check_runs[-1])' "$tmp/checks.json" >"$tmp/missing.json"
if LMM_CHECK_RUNS_FILE="$tmp/missing.json" LMM_CHECK_MAX_ATTEMPTS=1 \
  bash "$SCRIPT" "$REVISION" >"$tmp/missing.out" 2>&1; then
  printf 'negative governance fixture unexpectedly accepted a missing check\n' >&2
  exit 1
fi
grep -Fq '(missing)' "$tmp/missing.out"

printf 'release governance negative fixtures verified\n'
