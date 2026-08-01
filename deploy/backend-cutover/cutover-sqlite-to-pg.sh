#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

ARTIFACT_ENV=
REVISION=
SCHEMA=
DRY_RUN=0
RUN_AS_TRANSIENT=0

usage() {
  cat <<'EOF'
Usage: cutover-sqlite-to-pg.sh --candidate-env ABSOLUTE_PATH --revision ID --schema ID [--dry-run|--systemd-run]

The candidate environment must be a complete lmm-api EnvironmentFile containing
SQL_DSN for the versioned PostgreSQL schema and REDIS_CONN_STRING for dedicated
Valkey 6380. Production writes remain frozen while SQLite is copied and verified.
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
    --help|-h) usage; exit 0 ;;
    *) die "unknown argument: $1" ;;
  esac
done

[[ $REVISION =~ ^[A-Za-z0-9._-]{7,128}$ ]] || die "revision contains unsafe characters"
[[ $SCHEMA =~ ^[a-z_][a-z0-9_]{0,62}$ ]] || die "schema contains unsafe characters"
SELF=$(readlink -f -- "$0")
[[ $SELF == /* && -f $SELF && ! -L $SELF ]] || die "entrypoint must resolve to an absolute regular file"
readonly SELF

if ((RUN_AS_TRANSIENT)); then
  ((DRY_RUN == 0)) || die "--systemd-run cannot be combined with --dry-run"
  [[ $EUID -eq 0 ]] || die "systemd staging requires root"
  [[ $ARTIFACT_ENV == /* && -f $ARTIFACT_ENV && ! -L $ARTIFACT_ENV ]] || die "candidate env must be an absolute regular file"
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
    --property=Type=oneshot --property=TimeoutStartSec=2h -- \
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
transaction="$(date -u +%Y%m%dT%H%M%SZ)-${REVISION}-$$"
readonly transaction
readonly AUDIT_DIR="$AUDIT_ROOT/$transaction"
readonly JOURNAL="$STATE_ROOT/cutover-journal"
readonly BOUNDARY="$STATE_ROOT/pg-write-boundary"
readonly OLD_ENV="$AUDIT_DIR/go-env.before"
readonly SQLITE_BACKUP="$STATE_ROOT/sqlite-backups/${transaction}.db"

mkdir -p "$AUDIT_DIR" "$STATE_ROOT/sqlite-backups" "${LOCK_FILE%/*}"
chmod 0700 "$AUDIT_DIR"
exec > >(tee -a "$AUDIT_DIR/transaction.log") 2>&1

atomic_copy() {
  source=$1 target=$2 mode=$3
  dir=${target%/*}; base=${target##*/}; mkdir -p "$dir" || return
  temp="$dir/.${base}.${transaction}.tmp"
  cp -- "$source" "$temp" || return
  chmod "$mode" "$temp" || return
  sync -f "$temp" || return
  mv -Tf "$temp" "$target" || return
  sync -f "$dir" || return
}
atomic_text() {
  target=$1 mode=$2 content=$3
  dir=${target%/*}; base=${target##*/}; mkdir -p "$dir" || return
  temp="$dir/.${base}.${transaction}.tmp"
  printf '%s\n' "$content" >"$temp" || return
  chmod "$mode" "$temp" || return
  sync -f "$temp" || return
  mv -Tf "$temp" "$target" || return
  sync -f "$dir" || return
}
write_journal() { atomic_text "$JOURNAL" 0600 "transaction=$transaction phase=$1 revision=$REVISION schema=$SCHEMA"; }
write_result() { atomic_text "$AUDIT_DIR/result" 0600 "$1"; }

exec 9>"$LOCK_FILE"
flock -n 9 || die "another backend cutover is running"
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
systemctl is-active --quiet "$GO_UNIT" || die "Go API must be active before cutover"
systemctl is-active --quiet postgresql.service valkey-lmm-api.service || die "PostgreSQL and dedicated Valkey must be active"
curl --fail --silent --show-error --max-time 10 "$CANARY_ORIGIN/api/status" | grep -Fq '"success":true' || die "pre-cutover Go health failed"
atomic_copy "$GO_ENV" "$OLD_ENV" 0600
atomic_text "$AUDIT_DIR/manifest" 0600 "revision=$REVISION schema=$SCHEMA candidate_env_sha256=$(sha256sum "$ARTIFACT_ENV" | awk '{print $1}')"
write_journal PREFLIGHT
if ((DRY_RUN)); then
  write_result "DRY_RUN revision=$REVISION schema=$SCHEMA"
  exit 0
fi

boundary_crossed=0
service_stopped=0
candidate_installed=0
recover() {
  status=$?
  trap - ERR EXIT
  ((status != 0)) || exit 0
  if ((boundary_crossed == 0)); then
    recovery_failed=0
    if ((candidate_installed)) && ! atomic_copy "$OLD_ENV" "$GO_ENV" 0600; then recovery_failed=1; fi
    if ((service_stopped)) && ! systemctl start "$GO_UNIT"; then recovery_failed=1; fi
    if ((recovery_failed == 0)) && systemctl is-active --quiet "$GO_UNIT" && curl --fail --silent --max-time 10 "$CANARY_ORIGIN/api/status" >/dev/null; then
      write_journal ROLLED_BACK_SQLITE
      write_result "FAILED_ROLLED_BACK_SQLITE status=$status"
    else
      atomic_text "$AUDIT_DIR/NEEDS_ATTENTION" 0600 "pre-boundary SQLite recovery failed"
      write_result "NEEDS_ATTENTION_PRE_BOUNDARY status=$status"
    fi
  else
    systemctl start "$GO_UNIT" || true
    atomic_text "$AUDIT_DIR/NEEDS_ATTENTION" 0600 "PostgreSQL write boundary crossed; SQLite rollback forbidden"
    write_journal FORWARD_RECOVERY_REQUIRED
    write_result "FAILED_FORWARD_ONLY status=$status"
  fi
  exit "$status"
}
trap recover ERR EXIT

write_journal FREEZING_WRITES
systemctl stop "$GO_UNIT"
service_stopped=1
! systemctl is-active --quiet "$GO_UNIT" || die "Go API did not stop"
sqlite3 "$SQLITE_SOURCE" 'PRAGMA wal_checkpoint(TRUNCATE);' >/dev/null
[[ ! -e ${SQLITE_SOURCE}-wal && ! -e ${SQLITE_SOURCE}-journal && ! -e ${SQLITE_SOURCE}-shm ]] || die "SQLite sidecars remained after freeze"
sqlite3 "$SQLITE_SOURCE" 'PRAGMA quick_check;' | grep -Fxq ok || die "offline SQLite quick_check failed"
atomic_copy "$SQLITE_SOURCE" "$SQLITE_BACKUP" 0600
[[ $(sha256sum "$SQLITE_BACKUP" | awk '{print $1}') == $(sha256sum "$SQLITE_SOURCE" | awk '{print $1}') ]] || die "offline SQLite backup hash mismatch"
write_journal COPYING_TO_POSTGRES
"$MIGRATOR" rehearse --sqlite "$SQLITE_SOURCE" --manifest "$MANIFEST" --baseline "$BASELINE" \
  --catalog-sql "$CATALOG_SQL" --schema "$SCHEMA" --report "$AUDIT_DIR/migration.json"
[[ ${LMM_CUTOVER_FAIL_AT:-} != migrate ]] || die "injected failure after migration"
atomic_copy "$ARTIFACT_ENV" "$GO_ENV" 0600
candidate_installed=1
write_journal PG_ENV_INSTALLED
[[ ${LMM_CUTOVER_FAIL_AT:-} != env ]] || die "injected failure after candidate env"

# Starting the application may run GORM migrations and background writers. From
# this durable marker onward, automatic SQLite rollback is permanently forbidden.
atomic_text "$BOUNDARY" 0600 "transaction=$transaction revision=$REVISION schema=$SCHEMA crossed_at=$(date -u +%FT%TZ)"
boundary_crossed=1
write_journal PG_WRITE_BOUNDARY
systemctl start "$GO_UNIT"
service_stopped=0
[[ ${LMM_CUTOVER_FAIL_AT:-} != start ]] || die "injected failure after PostgreSQL start"
for _ in {1..60}; do
  systemctl is-active --quiet "$GO_UNIT" && curl --fail --silent --max-time 5 "$CANARY_ORIGIN/api/status" >/dev/null && break
  sleep 1
done
systemctl is-active --quiet "$GO_UNIT" || die "PostgreSQL-backed Go API is not active"
curl --fail --silent --show-error --max-time 10 "$CANARY_ORIGIN/api/status" | grep -Fq '"success":true' || die "public PostgreSQL canary failed"
token=$(<"$CANARY_TOKEN_FILE")
printf 'header = "Authorization: Bearer %s"\n' "$token" | \
  curl --config - --fail --silent --show-error --max-time 10 "$CANARY_ORIGIN/api/user/self" | grep -Fq '"success":true' || die "authenticated PostgreSQL canary failed"
unset token
[[ ${LMM_CUTOVER_FAIL_AT:-} != canary ]] || die "injected failure after canary"
write_journal COMPLETE
write_result "SUCCESS_POSTGRES revision=$REVISION schema=$SCHEMA"
trap - ERR EXIT
echo "PostgreSQL cutover complete; SQLite rollback is permanently forbidden"
