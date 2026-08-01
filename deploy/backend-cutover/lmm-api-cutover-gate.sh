#!/usr/bin/env bash
set -Eeuo pipefail

STATE_ROOT=/var/lib/lmm-api-cutover
GO_ENV=/etc/lmm-api/lmm-api.env
EXPECTED_OWNER=0

block_start() {
  echo 'lmm-api startup blocked: database cutover state is not safe' >&2
  exit 1
}

# The production ExecCondition supplies no arguments. Explicit absolute-path
# arguments exist only so repository tests can exercise the exact gate logic
# without writing host /etc or /var state; service EnvironmentFile values cannot
# redirect these checks.
while (($#)); do
  case $1 in
    --state-root) STATE_ROOT=${2:?}; shift 2 ;;
    --go-env) GO_ENV=${2:?}; shift 2 ;;
    --expected-owner) EXPECTED_OWNER=${2:?}; shift 2 ;;
    *) block_start ;;
  esac
done
[[ $STATE_ROOT == /* && $GO_ENV == /* && $EXPECTED_OWNER =~ ^[0-9]+$ ]] || block_start
readonly STATE_ROOT GO_ENV EXPECTED_OWNER
readonly GATE="$STATE_ROOT/cutover-in-progress"
readonly BOUNDARY="$STATE_ROOT/pg-write-boundary"

[[ ! -e $GATE && ! -L $GATE ]] || block_start
[[ -f $GO_ENV && ! -L $GO_ENV ]] || block_start
[[ $(stat -c %u "$GO_ENV") == "$EXPECTED_OWNER" && $(stat -c %a "$GO_ENV") =~ ^(600|400)$ ]] || block_start

if [[ ! -e $BOUNDARY && ! -L $BOUNDARY ]]; then
  # SQLite is the only legal no-boundary state in this deployment and its
  # environment has no SQL_DSN. Treat every non-comment SQL_DSN assignment-like
  # line as ambiguous instead of attempting to interpret EnvironmentFile
  # quoting or distinguish database schemes. The environment is never sourced.
  grep -Eq '^[[:space:]]*(export[[:space:]]+)?SQL_DSN([[:space:]]|=)' "$GO_ENV" && block_start
  exit 0
fi

[[ -f $BOUNDARY && ! -L $BOUNDARY ]] || block_start
[[ $(stat -c %u "$BOUNDARY") == "$EXPECTED_OWNER" && $(stat -c %a "$BOUNDARY") =~ ^(600|400)$ ]] || block_start
[[ $(wc -l <"$BOUNDARY") == 1 ]] || block_start

line=
IFS= read -r line <"$BOUNDARY" || block_start
read -r transaction_f revision_f schema_f candidate_f crossed_f extra <<<"$line"
[[ -z ${extra:-} ]] || block_start
transaction=${transaction_f#transaction=}
revision=${revision_f#revision=}
schema=${schema_f#schema=}
candidate_hash=${candidate_f#candidate_sha256=}
[[ $transaction_f == transaction="$transaction" && $transaction =~ ^[0-9]{8}T[0-9]{6}Z-[A-Za-z0-9._-]{7,128}-[0-9]+$ ]] || block_start
[[ $revision_f == revision="$revision" && $revision =~ ^[A-Za-z0-9._-]{7,128}$ ]] || block_start
[[ $schema_f == schema="$schema" && $schema =~ ^[a-z_][a-z0-9_]{0,62}$ ]] || block_start
[[ $candidate_f == candidate_sha256="$candidate_hash" && $candidate_hash =~ ^[a-f0-9]{64}$ ]] || block_start
[[ $crossed_f =~ ^crossed_at=[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]] || block_start
[[ $(sha256sum "$GO_ENV" | awk '{print $1}') == "$candidate_hash" ]] || block_start
