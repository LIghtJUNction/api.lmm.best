#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

ARTIFACT_ENV=
REVISION=
SCHEMA=
DRY_RUN=0
RUN_AS_TRANSIENT=0
RECONCILE_ONLY=0
PREPARE_START=0

usage() {
  cat <<'EOF'
Usage: cutover-sqlite-to-pg.sh --candidate-env ABSOLUTE_PATH --revision ID --schema ID [--dry-run|--systemd-run]
       cutover-sqlite-to-pg.sh --reconcile-only [--prepare-start]

The candidate environment must be a complete lmm-api EnvironmentFile containing
SQL_DSN for the versioned PostgreSQL schema and REDIS_CONN_STRING for dedicated
Valkey 6380. --reconcile-only safely resumes or rolls back an interrupted
transaction from durable metadata; --prepare-start is reserved for the boot gate.
EOF
}
die() { printf 'lmm-api-cutover: %s\n' "$*" >&2; exit 1; }

while (($#)); do
  case $1 in
    --candidate-env) ARTIFACT_ENV=${2:?}; shift 2 ;;
    --revision) REVISION=${2:?}; shift 2 ;;
    --schema) SCHEMA=${2:?}; shift 2 ;;
    --dry-run) DRY_RUN=1; shift ;;
    --systemd-run) RUN_AS_TRANSIENT=1; shift ;;
    --reconcile-only) RECONCILE_ONLY=1; shift ;;
    --prepare-start) PREPARE_START=1; shift ;;
    --help|-h) usage; exit 0 ;;
    *) die "unknown argument: $1" ;;
  esac
done

((PREPARE_START == 0 || RECONCILE_ONLY == 1)) || die "--prepare-start requires --reconcile-only"
if ((RECONCILE_ONLY)); then
  [[ -z $ARTIFACT_ENV && -z $REVISION && -z $SCHEMA && $DRY_RUN == 0 && $RUN_AS_TRANSIENT == 0 ]] || \
    die "--reconcile-only cannot be combined with cutover arguments"
else
  [[ $REVISION =~ ^[A-Za-z0-9._-]{7,128}$ ]] || die "revision contains unsafe characters"
  [[ $SCHEMA =~ ^[a-z_][a-z0-9_]{0,62}$ ]] || die "schema contains unsafe characters"
  [[ $ARTIFACT_ENV == /* ]] || die "candidate env must use an absolute path"
fi

SELF=$(readlink -f -- "$0")
[[ $SELF == /* && -f $SELF && ! -L $SELF ]] || die "entrypoint must resolve to an absolute regular file"
readonly SELF

if ((RUN_AS_TRANSIENT)); then
  ((DRY_RUN == 0)) || die "--systemd-run cannot be combined with --dry-run"
  [[ $EUID -eq 0 ]] || die "systemd staging requires root"
  [[ -f $ARTIFACT_ENV && ! -L $ARTIFACT_ENV ]] || die "candidate env must be an absolute regular file"
  incoming=/var/lib/lmm-api-cutover/artifacts
  install -d -m 0700 "$incoming"
  hash=$(sha256sum "$ARTIFACT_ENV" | awk '{print $1}')
  durable="$incoming/${REVISION}-${hash}.env"
  if [[ ! -e $durable ]]; then
    temp="$incoming/.${REVISION}-${hash}.$$.tmp"
    install -m 0600 -o root -g root "$ARTIFACT_ENV" "$temp"
    [[ $(sha256sum "$temp" | awk '{print $1}') == "$hash" ]] || die "candidate env changed while staging"
    sync -f "$temp"; mv -T "$temp" "$durable"; sync -f "$incoming"
  fi
  [[ -f $durable && ! -L $durable && $(stat -c %u "$durable") == 0 && $(stat -c %a "$durable") == 600 ]] || die "durable candidate env is unsafe"
  [[ $(sha256sum "$durable" | awk '{print $1}') == "$hash" ]] || die "durable candidate env checksum mismatch"
  exec systemd-run --unit="lmm-api-cutover-${REVISION}" --collect \
    --property=Type=oneshot --property=TimeoutStartSec=2h \
    --property=OnFailure=lmm-api-cutover-reconcile.service -- \
    "$SELF" --candidate-env "$durable" --revision "$REVISION" --schema "$SCHEMA"
fi

[[ ${LMM_CUTOVER_TEST_MODE:-0} == 1 || $EUID -eq 0 ]] || die "must run as root"
readonly ETC_ROOT=${LMM_CUTOVER_ETC_ROOT:-/etc/lmm-api-cutover}
readonly STATE_ROOT=${LMM_CUTOVER_STATE_ROOT:-/var/lib/lmm-api-cutover}
readonly AUDIT_ROOT=${LMM_CUTOVER_AUDIT_ROOT:-/var/log/lmm-api-cutover}
readonly LOCK_FILE=${LMM_CUTOVER_LOCK_FILE:-/run/lock/lmm-api-backend-cutover.lock}
readonly MIGRATOR=${LMM_CUTOVER_MIGRATOR:-/usr/lib/lmm-api-cutover/lmm-db-migrate}
readonly MANIFEST=${LMM_CUTOVER_MANIFEST:-/usr/lib/lmm-api-cutover/schema/table-map.json}
readonly BASELINE=${LMM_CUTOVER_BASELINE:-/usr/lib/lmm-api-cutover/schema/postgresql-baseline.sql}
readonly CATALOG_SQL=${LMM_CUTOVER_CATALOG_SQL:-/usr/lib/lmm-api-cutover/schema/export-postgres-catalog.sql}
GO_UNIT=lmm-api.service
GO_ENV=/etc/lmm-api/lmm-api.env
SQLITE_SOURCE=/var/lib/private/lmm-api/one-api.db
CANARY_ORIGIN=http://127.0.0.1:3000
CANARY_TOKEN_FILE="$ETC_ROOT/admin-canary.token"
MIGRATION_ENV="$ETC_ROOT/migration.env"
config_owner=0
[[ ${LMM_CUTOVER_TEST_MODE:-0} != 1 ]] || config_owner=$(id -u)
if [[ -r $ETC_ROOT/cutover.conf ]]; then
  [[ -f $ETC_ROOT/cutover.conf && ! -L $ETC_ROOT/cutover.conf && $(stat -c %u "$ETC_ROOT/cutover.conf") == "$config_owner" && $(stat -c %a "$ETC_ROOT/cutover.conf") =~ ^(600|400)$ ]] || die "cutover config is unsafe"
  # shellcheck disable=SC1090,SC1091
  source "$ETC_ROOT/cutover.conf"
fi
readonly GO_UNIT GO_ENV SQLITE_SOURCE CANARY_ORIGIN CANARY_TOKEN_FILE MIGRATION_ENV
readonly JOURNAL="$STATE_ROOT/cutover-journal"
readonly BOUNDARY="$STATE_ROOT/pg-write-boundary"
readonly GATE="$STATE_ROOT/cutover-in-progress"

transaction=
phase=
candidate_hash=
old_env_hash=
AUDIT_DIR=
OLD_ENV=
SQLITE_BACKUP=
durable_candidate=

atomic_copy() {
  local source=$1 target=$2 mode=$3 dir base temp
  dir=${target%/*}; base=${target##*/}; mkdir -p "$dir" || return
  temp="$dir/.${base}.${transaction:-reconcile-$$}.tmp"
  cp -- "$source" "$temp" || return
  chmod "$mode" "$temp" || return
  if [[ ${LMM_CUTOVER_TEST_MODE:-0} != 1 ]]; then chown root:root "$temp" || return; fi
  sync -f "$temp" || return
  mv -Tf "$temp" "$target" || return
  sync -f "$dir" || return
}
atomic_text() {
  local target=$1 mode=$2 content=$3 dir base temp
  dir=${target%/*}; base=${target##*/}; mkdir -p "$dir" || return
  temp="$dir/.${base}.${transaction:-reconcile-$$}.tmp"
  printf '%s\n' "$content" >"$temp" || return
  chmod "$mode" "$temp" || return
  if [[ ${LMM_CUTOVER_TEST_MODE:-0} != 1 ]]; then chown root:root "$temp" || return; fi
  sync -f "$temp" || return
  mv -Tf "$temp" "$target" || return
  sync -f "$dir" || return
}
clear_gate() {
  [[ -e $GATE ]] || return 0
  rm -f -- "$GATE"
  sync -f "$STATE_ROOT"
}
write_journal() {
  phase=$1
  atomic_text "$JOURNAL" 0600 \
    "version=1 transaction=$transaction phase=$phase revision=$REVISION schema=$SCHEMA candidate_sha256=$candidate_hash old_env_sha256=$old_env_hash"
}
write_result() { atomic_text "$AUDIT_DIR/result" 0600 "$1"; }
kill_at() {
  [[ ${LMM_CUTOVER_KILL_AT:-} != "$1" ]] || kill -KILL "$BASHPID"
}
file_hash() {
  [[ -f $1 && ! -L $1 ]] || return 1
  sha256sum "$1" | awk '{print $1}'
}
service_active() { systemctl is-active --quiet "$GO_UNIT"; }
start_and_health() {
  systemctl start "$GO_UNIT"
  for _ in {1..60}; do
    service_active && curl --fail --silent --max-time 5 "$CANARY_ORIGIN/api/status" >/dev/null && return 0
    sleep 1
  done
  return 1
}
run_pg_canaries() {
  curl --fail --silent --show-error --max-time 10 "$CANARY_ORIGIN/api/status" | grep -Fq '"success":true' || return
  local token
  token=$(<"$CANARY_TOKEN_FILE")
  printf 'header = "Authorization: Bearer %s"\n' "$token" | \
    curl --config - --fail --silent --show-error --max-time 10 "$CANARY_ORIGIN/api/user/self" | grep -Fq '"success":true'
  unset token
}
parse_journal() {
  local line version_f transaction_f phase_f revision_f schema_f candidate_f old_f extra
  [[ -f $JOURNAL && ! -L $JOURNAL ]] || die "durable cutover journal is absent or unsafe"
  IFS= read -r line <"$JOURNAL" || die "durable cutover journal is unreadable"
  read -r version_f transaction_f phase_f revision_f schema_f candidate_f old_f extra <<<"$line"
  [[ -z ${extra:-} && $version_f == version=1 ]] || die "durable cutover journal has an invalid format"
  transaction=${transaction_f#transaction=}
  phase=${phase_f#phase=}
  REVISION=${revision_f#revision=}
  SCHEMA=${schema_f#schema=}
  candidate_hash=${candidate_f#candidate_sha256=}
  old_env_hash=${old_f#old_env_sha256=}
  [[ $transaction_f == transaction="$transaction" && $transaction =~ ^[0-9]{8}T[0-9]{6}Z-[A-Za-z0-9._-]{7,128}-[0-9]+$ ]] || die "journal transaction is unsafe"
  [[ $phase_f == phase="$phase" && $phase =~ ^(PREFLIGHT|GATED|FREEZING_WRITES|SQLITE_BACKED_UP|COPYING_TO_POSTGRES|ACTIVATING_POSTGRES|PG_WRITE_BOUNDARY|PG_ENV_INSTALLED|FORWARD_READY|FORWARD_RECOVERY_REQUIRED|ROLLED_BACK_SQLITE|COMPLETE)$ ]] || die "journal phase is unsafe"
  [[ $revision_f == revision="$REVISION" && $REVISION =~ ^[A-Za-z0-9._-]{7,128}$ ]] || die "journal revision is unsafe"
  [[ $schema_f == schema="$SCHEMA" && $SCHEMA =~ ^[a-z_][a-z0-9_]{0,62}$ ]] || die "journal schema is unsafe"
  [[ $candidate_f == candidate_sha256="$candidate_hash" && $candidate_hash =~ ^[a-f0-9]{64}$ ]] || die "journal candidate hash is unsafe"
  [[ $old_f == old_env_sha256="$old_env_hash" && $old_env_hash =~ ^[a-f0-9]{64}$ ]] || die "journal old-env hash is unsafe"
  AUDIT_DIR="$AUDIT_ROOT/$transaction"
  OLD_ENV="$AUDIT_DIR/go-env.before"
  SQLITE_BACKUP="$STATE_ROOT/sqlite-backups/${transaction}.db"
  durable_candidate="$STATE_ROOT/artifacts/${REVISION}-${candidate_hash}.env"
  [[ $AUDIT_DIR == "$AUDIT_ROOT/"* && $OLD_ENV == "$AUDIT_ROOT/"* && $durable_candidate == "$STATE_ROOT/artifacts/"* ]] || die "derived journal paths are unsafe"
}
validate_boundary() {
  local line transaction_f revision_f schema_f candidate_f crossed_f extra marker_transaction marker_revision marker_schema marker_hash
  [[ -f $BOUNDARY && ! -L $BOUNDARY ]] || return 1
  IFS= read -r line <"$BOUNDARY" || die "PostgreSQL boundary is unreadable"
  read -r transaction_f revision_f schema_f candidate_f crossed_f extra <<<"$line"
  [[ -z ${extra:-} ]] || die "PostgreSQL boundary has an invalid format"
  marker_transaction=${transaction_f#transaction=}; marker_revision=${revision_f#revision=}
  marker_schema=${schema_f#schema=}; marker_hash=${candidate_f#candidate_sha256=}
  [[ $transaction_f == transaction="$marker_transaction" && $marker_transaction == "$transaction" ]] || die "PostgreSQL boundary transaction mismatch"
  [[ $revision_f == revision="$marker_revision" && $marker_revision == "$REVISION" ]] || die "PostgreSQL boundary revision mismatch"
  [[ $schema_f == schema="$marker_schema" && $marker_schema == "$SCHEMA" ]] || die "PostgreSQL boundary schema mismatch"
  [[ $candidate_f == candidate_sha256="$marker_hash" && $marker_hash == "$candidate_hash" ]] || die "PostgreSQL boundary candidate mismatch"
  [[ $crossed_f =~ ^crossed_at=[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]] || die "PostgreSQL boundary timestamp is unsafe"
}
validate_reconcile_assets() {
  [[ -d $AUDIT_DIR && ! -L $AUDIT_DIR ]] || die "journal audit directory is absent or unsafe"
  [[ -f $OLD_ENV && ! -L $OLD_ENV && $(file_hash "$OLD_ENV") == "$old_env_hash" ]] || die "saved SQLite environment checksum mismatch"
  [[ -f $durable_candidate && ! -L $durable_candidate && $(file_hash "$durable_candidate") == "$candidate_hash" ]] || die "durable candidate environment checksum mismatch"
  [[ $(stat -c %u "$OLD_ENV") == "$config_owner" && $(stat -c %a "$OLD_ENV") =~ ^(600|400)$ ]] || die "saved SQLite environment is unsafe"
  [[ $(stat -c %u "$durable_candidate") == "$config_owner" && $(stat -c %a "$durable_candidate") =~ ^(600|400)$ ]] || die "durable candidate environment is unsafe"
}
write_boundary() {
  atomic_text "$BOUNDARY" 0600 \
    "transaction=$transaction revision=$REVISION schema=$SCHEMA candidate_sha256=$candidate_hash crossed_at=$(date -u +%FT%TZ)"
}
reconcile_transaction() {
  local current_hash= service_was_active=0 forward=0
  parse_journal
  validate_reconcile_assets
  current_hash=$(file_hash "$GO_ENV") || die "active Go environment is absent or unsafe"
  validate_boundary && forward=1
  [[ $current_hash != "$candidate_hash" ]] || forward=1

  if ((forward)); then
    if [[ ! -e $BOUNDARY ]]; then
      write_boundary
    else
      validate_boundary
    fi
    if [[ $current_hash != "$candidate_hash" ]]; then
      service_active && { systemctl stop "$GO_UNIT"; service_was_active=1; }
      atomic_copy "$durable_candidate" "$GO_ENV" 0600
    fi
    [[ $(file_hash "$GO_ENV") == "$candidate_hash" ]] || die "candidate environment publication failed"
    write_journal FORWARD_READY
    clear_gate
    if ((PREPARE_START)); then
      return 0
    fi
    if ! service_active; then start_and_health || die "PostgreSQL-backed Go API did not become healthy"; fi
    run_pg_canaries || die "PostgreSQL canary failed during reconciliation"
    write_journal COMPLETE
    write_result "SUCCESS_POSTGRES revision=$REVISION schema=$SCHEMA reconciled=1"
    return 0
  fi

  if [[ $current_hash != "$old_env_hash" ]]; then
    service_active && { systemctl stop "$GO_UNIT"; service_was_active=1; }
    atomic_copy "$OLD_ENV" "$GO_ENV" 0600
  fi
  [[ $(file_hash "$GO_ENV") == "$old_env_hash" ]] || die "saved SQLite environment restoration failed"
  write_journal ROLLED_BACK_SQLITE
  clear_gate
  if ((PREPARE_START)); then
    return 0
  fi
  if ! service_active; then start_and_health || die "SQLite-backed Go API did not become healthy"; fi
  write_result "FAILED_ROLLED_BACK_SQLITE reconciled=1"
  : "$service_was_active"
}

mkdir -p "$STATE_ROOT" "${LOCK_FILE%/*}"
exec 9>"$LOCK_FILE"
flock -n 9 || die "another backend cutover is running"

if ((RECONCILE_ONLY)); then
  if [[ ! -e $JOURNAL ]]; then
    [[ ! -e $GATE ]] || die "cutover gate exists without a journal; manual inspection is required"
    echo "No interrupted backend cutover requires reconciliation"
    exit 0
  fi
  reconcile_transaction
  echo "Backend cutover reconciliation complete"
  exit 0
fi

[[ ! -e $BOUNDARY ]] || die "a previous PostgreSQL write boundary exists; automatic SQLite cutover is permanently disabled"
for file in "$ARTIFACT_ENV" "$GO_ENV" "$SQLITE_SOURCE" "$MIGRATION_ENV" "$CANARY_TOKEN_FILE" "$MIGRATOR" "$MANIFEST" "$BASELINE" "$CATALOG_SQL"; do
  [[ -f $file && ! -L $file ]] || die "required regular file is absent or unsafe: $file"
done
[[ $CANARY_ORIGIN == http://127.0.0.1:3000 ]] || die "authenticated canary origin must be the fixed loopback Go listener"
for managed in "$MIGRATOR" "$MANIFEST" "$BASELINE" "$CATALOG_SQL"; do
  [[ $(stat -c %u "$managed") == "$config_owner" ]] || die "managed cutover asset has an unexpected owner"
done
required_owner=$config_owner
[[ $(stat -c %u "$ARTIFACT_ENV") == "$required_owner" && $(stat -c %a "$ARTIFACT_ENV") =~ ^(600|400)$ ]] || die "candidate env must be privately owned"
[[ $(grep -c '^SQL_DSN=' "$ARTIFACT_ENV") == 1 && $(grep -c '^REDIS_CONN_STRING=' "$ARTIFACT_ENV") == 1 ]] || die "candidate env must contain exactly one SQL_DSN and REDIS_CONN_STRING"
grep -Eq '^SQL_DSN=postgres(ql)?://' "$ARTIFACT_ENV" || die "candidate env does not select PostgreSQL"
grep -Eq '^REDIS_CONN_STRING=rediss?://.*@(127\.0\.0\.1|localhost):6380/' "$ARTIFACT_ENV" || die "candidate env does not select dedicated Valkey 6380"
grep -Eq "^SQL_DSN=.*options=-csearch_path%3D${SCHEMA}([&[:space:]]|$)" "$ARTIFACT_ENV" || die "candidate SQL_DSN does not bind the requested schema"
cmp -s <(grep -Ev '^(SQL_DSN|REDIS_CONN_STRING)=' "$GO_ENV") <(grep -Ev '^(SQL_DSN|REDIS_CONN_STRING)=' "$ARTIFACT_ENV") || die "candidate env changes fields outside SQL_DSN and REDIS_CONN_STRING"
[[ $(stat -c %u "$MIGRATION_ENV") == "$required_owner" && $(stat -c %a "$MIGRATION_ENV") =~ ^(600|400)$ ]] || die "migration env must be privately owned"
migration_line=$(grep -E '^LMM_MIGRATE_DATABASE_URL=postgres(ql)?://' "$MIGRATION_ENV" | head -n1)
[[ -n $migration_line ]] || die "migration DSN is missing"
export LMM_MIGRATE_DATABASE_URL=${migration_line#*=}
unset migration_line
candidate_line=$(grep -E '^SQL_DSN=postgres(ql)?://' "$ARTIFACT_ENV" | head -n1)
candidate_dsn=${candidate_line#*=}
if [[ $LMM_MIGRATE_DATABASE_URL == *\?* ]]; then
  expected_candidate_dsn="${LMM_MIGRATE_DATABASE_URL}&options=-csearch_path%3D${SCHEMA}"
else
  expected_candidate_dsn="${LMM_MIGRATE_DATABASE_URL}?options=-csearch_path%3D${SCHEMA}"
fi
[[ $candidate_dsn == "$expected_candidate_dsn" ]] || die "candidate and migration DSNs do not identify the same database role"
unset candidate_line candidate_dsn expected_candidate_dsn
[[ $(stat -c %s "$CANARY_TOKEN_FILE") -gt 20 ]] || die "fresh authenticated canary token is missing"
[[ $(stat -c %u "$CANARY_TOKEN_FILE") == "$required_owner" && $(stat -c %a "$CANARY_TOKEN_FILE") =~ ^(600|400)$ ]] || die "authenticated canary token must be privately owned"
token=$(<"$CANARY_TOKEN_FILE")
[[ $token =~ ^[A-Za-z0-9._-]{20,4096}$ ]] || die "authenticated canary token contains unsafe characters"
unset token
service_active || die "Go API must be active before cutover"
systemctl is-active --quiet postgresql.service valkey-lmm-api.service || die "PostgreSQL and dedicated Valkey must be active"
curl --fail --silent --show-error --max-time 10 "$CANARY_ORIGIN/api/status" | grep -Fq '"success":true' || die "pre-cutover Go health failed"

candidate_hash=$(file_hash "$ARTIFACT_ENV")
durable_candidate="$STATE_ROOT/artifacts/${REVISION}-${candidate_hash}.env"
if [[ ! -e $durable_candidate ]]; then atomic_copy "$ARTIFACT_ENV" "$durable_candidate" 0600; fi
[[ -f $durable_candidate && ! -L $durable_candidate && $(file_hash "$durable_candidate") == "$candidate_hash" ]] || die "durable candidate environment checksum mismatch"
[[ $(stat -c %u "$durable_candidate") == "$config_owner" && $(stat -c %a "$durable_candidate") == 600 ]] || die "durable candidate environment is unsafe"
ARTIFACT_ENV=$durable_candidate

transaction="$(date -u +%Y%m%dT%H%M%SZ)-${REVISION}-$$"
AUDIT_DIR="$AUDIT_ROOT/$transaction"
OLD_ENV="$AUDIT_DIR/go-env.before"
SQLITE_BACKUP="$STATE_ROOT/sqlite-backups/${transaction}.db"
mkdir -p "$AUDIT_DIR" "$STATE_ROOT/sqlite-backups"
chmod 0700 "$AUDIT_DIR"
exec > >(tee -a "$AUDIT_DIR/transaction.log") 2>&1
atomic_copy "$GO_ENV" "$OLD_ENV" 0600
old_env_hash=$(file_hash "$OLD_ENV")
atomic_text "$AUDIT_DIR/manifest" 0600 "revision=$REVISION schema=$SCHEMA candidate_env_sha256=$candidate_hash old_env_sha256=$old_env_hash"
write_journal PREFLIGHT
if ((DRY_RUN)); then
  write_result "DRY_RUN revision=$REVISION schema=$SCHEMA"
  exit 0
fi

recover() {
  local failure_status=$?
  trap - ERR EXIT
  ((failure_status != 0)) || exit 0
  if reconcile_transaction; then
    exit "$failure_status"
  fi
  atomic_text "$AUDIT_DIR/NEEDS_ATTENTION" 0600 "durable cutover reconciliation failed"
  write_result "NEEDS_ATTENTION status=$failure_status"
  exit "$failure_status"
}
trap recover ERR EXIT

atomic_text "$GATE" 0600 "transaction=$transaction"
write_journal GATED
kill_at after_gate
write_journal FREEZING_WRITES
systemctl stop "$GO_UNIT"
! service_active || die "Go API did not stop"
kill_at after_stop
sqlite3 "$SQLITE_SOURCE" 'PRAGMA wal_checkpoint(TRUNCATE);' >/dev/null
[[ ! -e ${SQLITE_SOURCE}-wal && ! -e ${SQLITE_SOURCE}-journal && ! -e ${SQLITE_SOURCE}-shm ]] || die "SQLite sidecars remained after freeze"
sqlite3 "$SQLITE_SOURCE" 'PRAGMA quick_check;' | grep -Fxq ok || die "offline SQLite quick_check failed"
atomic_copy "$SQLITE_SOURCE" "$SQLITE_BACKUP" 0600
[[ $(file_hash "$SQLITE_BACKUP") == $(file_hash "$SQLITE_SOURCE") ]] || die "offline SQLite backup hash mismatch"
write_journal SQLITE_BACKED_UP
kill_at after_backup
write_journal COPYING_TO_POSTGRES
"$MIGRATOR" rehearse --sqlite "$SQLITE_SOURCE" --manifest "$MANIFEST" --baseline "$BASELINE" \
  --catalog-sql "$CATALOG_SQL" --schema "$SCHEMA" --report "$AUDIT_DIR/migration.json"
[[ ${LMM_CUTOVER_FAIL_AT:-} != migrate ]] || die "injected failure after migration"
kill_at before_marker

# The forward-only marker must be durable before a PostgreSQL-capable Go
# environment becomes visible. Recovery also treats a candidate hash match as
# forward-only evidence, closing the window left by older coordinators.
write_journal ACTIVATING_POSTGRES
write_boundary
write_journal PG_WRITE_BOUNDARY
kill_at after_marker
atomic_copy "$ARTIFACT_ENV" "$GO_ENV" 0600
write_journal PG_ENV_INSTALLED
[[ ${LMM_CUTOVER_FAIL_AT:-} != env ]] || die "injected failure after candidate env"
kill_at after_env
clear_gate
write_journal FORWARD_READY
systemctl start "$GO_UNIT"
[[ ${LMM_CUTOVER_FAIL_AT:-} != start ]] || die "injected failure after PostgreSQL start"
kill_at after_start
start_and_health
kill_at before_canary
curl --fail --silent --show-error --max-time 10 "$CANARY_ORIGIN/api/status" | grep -Fq '"success":true' || die "public PostgreSQL canary failed"
kill_at after_public_canary
token=$(<"$CANARY_TOKEN_FILE")
printf 'header = "Authorization: Bearer %s"\n' "$token" | \
  curl --config - --fail --silent --show-error --max-time 10 "$CANARY_ORIGIN/api/user/self" | grep -Fq '"success":true' || die "authenticated PostgreSQL canary failed"
unset token
[[ ${LMM_CUTOVER_FAIL_AT:-} != canary ]] || die "injected failure after canary"
kill_at after_canary
write_journal COMPLETE
write_result "SUCCESS_POSTGRES revision=$REVISION schema=$SCHEMA"
trap - ERR EXIT
echo "PostgreSQL cutover complete; SQLite rollback is permanently forbidden"
