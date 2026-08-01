#!/usr/bin/env bash
set -Eeuo pipefail
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
SCRIPT="$HERE/cutover-sqlite-to-pg.sh"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP"/{bin,etc,state,audit,run,assets}
printf 'SHARED_SECRET=unchanged\n' >"$TMP/go.env"
printf 'SHARED_SECRET=unchanged\nSQL_DSN=postgresql://app@127.0.0.1/db?options=-csearch_path%%3Dlmm_prod_test\nREDIS_CONN_STRING=redis://app:x@127.0.0.1:6380/0\n' >"$TMP/candidate.env"
printf 'LMM_MIGRATE_DATABASE_URL=postgresql://app@127.0.0.1/db\n' >"$TMP/etc/migration.env"
printf 'test.fresh_admin-token_123456789\n' >"$TMP/etc/admin-canary.token"
printf 'sqlite fixture\n' >"$TMP/source.db"
chmod 0600 "$TMP/candidate.env" "$TMP/etc/migration.env" "$TMP/etc/admin-canary.token"
for asset in manifest baseline catalog; do printf '%s\n' "$asset" >"$TMP/assets/$asset"; done
cat >"$TMP/etc/cutover.conf" <<EOF
GO_UNIT=lmm-api.service
GO_ENV=$TMP/go.env
SQLITE_SOURCE=$TMP/source.db
CANARY_ORIGIN=http://127.0.0.1:3000
CANARY_TOKEN_FILE=$TMP/etc/admin-canary.token
MIGRATION_ENV=$TMP/etc/migration.env
EOF
chmod 0600 "$TMP/etc/cutover.conf"
cat >"$TMP/bin/systemctl" <<'EOF'
#!/usr/bin/env bash
state=${LMM_TEST_SERVICE_STATE:?}
case $1 in
  is-active) [[ $(cat "$state") == active ]] ;;
  stop) printf 'inactive\n' >"$state" ;;
  start) printf 'active\n' >"$state" ;;
  *) exit 0 ;;
esac
EOF
cat >"$TMP/bin/curl" <<'EOF'
#!/usr/bin/env bash
printf '{"success":true}\n'
EOF
cat >"$TMP/bin/sqlite3" <<'EOF'
#!/usr/bin/env bash
printf 'ok\n'
EOF
cat >"$TMP/bin/migrator" <<'EOF'
#!/usr/bin/env bash
report=
while (($#)); do [[ $1 == --report ]] && { report=$2; shift 2; continue; }; shift; done
printf '{"status":"ok"}\n' >"$report"
EOF
chmod +x "$TMP/bin/"*
printf 'active\n' >"$TMP/service-state"

run_cutover() {
  PATH="$TMP/bin:$PATH" LMM_CUTOVER_TEST_MODE=1 LMM_TEST_SERVICE_STATE="$TMP/service-state" \
    LMM_CUTOVER_ETC_ROOT="$TMP/etc" LMM_CUTOVER_STATE_ROOT="$TMP/state" \
    LMM_CUTOVER_AUDIT_ROOT="$TMP/audit" LMM_CUTOVER_LOCK_FILE="$TMP/run/lock" \
    LMM_CUTOVER_MIGRATOR="$TMP/bin/migrator" LMM_CUTOVER_MANIFEST="$TMP/assets/manifest" \
    LMM_CUTOVER_BASELINE="$TMP/assets/baseline" LMM_CUTOVER_CATALOG_SQL="$TMP/assets/catalog" \
    "$SCRIPT" --candidate-env "$TMP/candidate.env" --revision abcdef123 --schema lmm_prod_test "$@"
}

run_cutover --dry-run >/dev/null
grep -Rq '^DRY_RUN ' "$TMP/audit"

cp "$TMP/candidate.env" "$TMP/bad-candidate.env"
sed -i 's/SHARED_SECRET=unchanged/SHARED_SECRET=changed/' "$TMP/bad-candidate.env"
chmod 0600 "$TMP/bad-candidate.env"
if PATH="$TMP/bin:$PATH" LMM_CUTOVER_TEST_MODE=1 LMM_TEST_SERVICE_STATE="$TMP/service-state" \
  LMM_CUTOVER_ETC_ROOT="$TMP/etc" LMM_CUTOVER_STATE_ROOT="$TMP/state" \
  LMM_CUTOVER_AUDIT_ROOT="$TMP/audit" LMM_CUTOVER_LOCK_FILE="$TMP/run/lock" \
  LMM_CUTOVER_MIGRATOR="$TMP/bin/migrator" LMM_CUTOVER_MANIFEST="$TMP/assets/manifest" \
  LMM_CUTOVER_BASELINE="$TMP/assets/baseline" LMM_CUTOVER_CATALOG_SQL="$TMP/assets/catalog" \
  "$SCRIPT" --candidate-env "$TMP/bad-candidate.env" --revision abcdef124 \
  --schema lmm_prod_test --dry-run >/dev/null 2>&1; then
  echo 'candidate unrelated env drift was accepted' >&2; exit 1
fi

# A live SQLite sidecar is permitted during dry-run; the autonomous transaction
# must stop the writer and require sidecars to disappear before COPY.
touch "$TMP/source.db-wal"
run_cutover --dry-run >/dev/null
rm -f "$TMP/source.db-wal"

rm -rf "$TMP/audit" "$TMP/state"; mkdir -p "$TMP/audit" "$TMP/state/sqlite-backups"
printf 'active\n' >"$TMP/service-state"; printf 'SHARED_SECRET=unchanged\n' >"$TMP/go.env"
export LMM_CUTOVER_FAIL_AT='env'
if run_cutover >/dev/null 2>&1; then echo 'pre-boundary fault succeeded' >&2; exit 1; fi
unset LMM_CUTOVER_FAIL_AT
grep -Fxq 'SHARED_SECRET=unchanged' "$TMP/go.env"
grep -Rq '^FAILED_ROLLED_BACK_SQLITE ' "$TMP/audit"
[[ $(cat "$TMP/service-state") == active ]]
[[ ! -e $TMP/state/pg-write-boundary ]]

rm -rf "$TMP/audit" "$TMP/state"; mkdir -p "$TMP/audit" "$TMP/state/sqlite-backups"
printf 'active\n' >"$TMP/service-state"; printf 'SHARED_SECRET=unchanged\n' >"$TMP/go.env"
export LMM_CUTOVER_FAIL_AT='start'
if run_cutover >/dev/null 2>&1; then echo 'post-boundary fault succeeded' >&2; exit 1; fi
unset LMM_CUTOVER_FAIL_AT
grep -Eq '^SQL_DSN=postgresql://' "$TMP/go.env"
grep -Rq '^FAILED_FORWARD_ONLY ' "$TMP/audit"
test -f "$TMP/state/pg-write-boundary"
[[ $(cat "$TMP/service-state") == active ]]

if run_cutover --dry-run >/dev/null 2>&1; then echo 'boundary did not permanently block SQLite retry' >&2; exit 1; fi

rm -rf "$TMP/audit" "$TMP/state"; mkdir -p "$TMP/audit" "$TMP/state/sqlite-backups"
printf 'active\n' >"$TMP/service-state"; printf 'SHARED_SECRET=unchanged\n' >"$TMP/go.env"
run_cutover >/dev/null
grep -Rq '^SUCCESS_POSTGRES ' "$TMP/audit"
test -f "$TMP/state/pg-write-boundary"
grep -Eq '^SQL_DSN=postgresql://' "$TMP/go.env"
echo 'backend cutover safety tests passed'
