#!/usr/bin/env bash
set -Eeuo pipefail

ROOT=$(git rev-parse --show-toplevel)
readonly ROOT
readonly REPOSITORY=${GITHUB_REPOSITORY:-LIghtJUNction/api.lmm.best}
readonly API_ROOT=${GITHUB_API_URL:-https://api.github.com}
readonly REQUIRED_FILE="$ROOT/.github/required-release-checks.txt"
readonly MAX_ATTEMPTS=${LMM_CHECK_MAX_ATTEMPTS:-30}
readonly WAIT_SECONDS=${LMM_CHECK_WAIT_SECONDS:-20}

fail() {
  printf 'verify-release-commit-checks: %s\n' "$*" >&2
  exit 1
}

[[ $# -eq 1 && $1 =~ ^[0-9a-f]{40}$ ]] || fail 'usage: verify-release-commit-checks.sh COMMIT_SHA'
readonly REVISION=$1
[[ -f $REQUIRED_FILE ]] || fail 'required check inventory is missing'
mapfile -t required < <(grep -v '^[[:space:]]*$' "$REQUIRED_FILE")
[[ ${#required[@]} -gt 0 ]] || fail 'required check inventory is empty'
for command in curl jq; do command -v "$command" >/dev/null 2>&1 || fail "required command is unavailable: $command"; done

fetch_checks() {
  if [[ -n ${LMM_CHECK_RUNS_FILE:-} ]]; then
    cat -- "$LMM_CHECK_RUNS_FILE"
    return
  fi
  [[ -n ${GITHUB_TOKEN:-} ]] || fail 'GITHUB_TOKEN is required for live check verification'
  curl --fail --location --silent --show-error \
    --retry 4 --retry-all-errors --retry-delay 2 --connect-timeout 15 --max-time 60 \
    --header "Authorization: Bearer $GITHUB_TOKEN" \
    --header 'Accept: application/vnd.github+json' \
    "$API_ROOT/repos/$REPOSITORY/commits/$REVISION/check-runs?per_page=100"
}

for ((attempt = 1; attempt <= MAX_ATTEMPTS; attempt++)); do
  checks=$(fetch_checks) || fail 'could not read commit check runs'
  invalid=()
  pending=()
  for name in "${required[@]}"; do
    record=$(jq -c --arg name "$name" '
      [.check_runs[] | select(.name == $name and .app.slug == "github-actions")]
      | if length == 0 then null else max_by(.id) end
    ' <<<"$checks")
    if [[ $record == null ]]; then
      pending+=("$name (missing)")
      continue
    fi
    status=$(jq -r '.status' <<<"$record")
    conclusion=$(jq -r '.conclusion // ""' <<<"$record")
    if [[ $status != completed ]]; then
      pending+=("$name ($status)")
    elif [[ $conclusion != success ]]; then
      invalid+=("$name ($conclusion)")
    fi
  done
  if [[ ${#invalid[@]} -gt 0 ]]; then
    printf 'verify-release-commit-checks: failed required checks for %s:\n' "$REVISION" >&2
    printf '  - %s\n' "${invalid[@]}" >&2
    exit 1
  fi
  if [[ ${#pending[@]} -eq 0 ]]; then
    printf 'all required CI, CodeQL, and release artifact checks passed for %s\n' "$REVISION"
    exit 0
  fi
  if (( attempt == MAX_ATTEMPTS )); then
    printf 'verify-release-commit-checks: required checks did not complete for %s:\n' "$REVISION" >&2
    printf '  - %s\n' "${pending[@]}" >&2
    exit 1
  fi
  sleep "$WAIT_SECONDS"
done
