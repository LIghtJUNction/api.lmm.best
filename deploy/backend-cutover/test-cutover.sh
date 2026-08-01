#!/usr/bin/env bash
set -Eeuo pipefail
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
SCRIPT="$HERE/cutover-sqlite-to-pg.sh"
GATE_SCRIPT="$HERE/lmm-api-cutover-gate.sh"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP"/{bin,etc,state,audit,run,assets}
printf 'SHARED_SECRET=unchanged\n' >"$TMP/go.env"
cp "$TMP/go.env" "$TMP/sqlite.env"
printf 'SHARED_SECRET=unchanged\nSQL_DSN=postgresql://app@127.0.0.1/db?options=-csearch_path%%3Dlmm_prod_test\nREDIS_CONN_STRING=redis://app:x@127.0.0.1:6380/0\n' >"$TMP/candidate.env"
printf 'LMM_MIGRATE_DATABASE_URL=postgresql://app@127.0.0.1/db\n' >"$TMP/etc/migration.env"
printf 'test.fresh_admin-token_123456789\n' >"$TMP/etc/admin-canary.token"
printf 'sqlite fixture\n' >"$TMP/source.db"
chmod 0600 "$TMP/go.env" "$TMP/sqlite.env" "$TMP/candidate.env" \
  "$TMP/etc/migration.env" "$TMP/etc/admin-canary.token"
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

run_reconcile() {
  PATH="$TMP/bin:$PATH" LMM_CUTOVER_TEST_MODE=1 LMM_TEST_SERVICE_STATE="$TMP/service-state" \
    LMM_CUTOVER_ETC_ROOT="$TMP/etc" LMM_CUTOVER_STATE_ROOT="$TMP/state" \
    LMM_CUTOVER_AUDIT_ROOT="$TMP/audit" LMM_CUTOVER_LOCK_FILE="$TMP/run/lock" \
    LMM_CUTOVER_MIGRATOR="$TMP/bin/migrator" LMM_CUTOVER_MANIFEST="$TMP/assets/manifest" \
    LMM_CUTOVER_BASELINE="$TMP/assets/baseline" LMM_CUTOVER_CATALOG_SQL="$TMP/assets/catalog" \
    "$SCRIPT" --reconcile-only "$@"
}

reset_fixture() {
  rm -rf "$TMP/audit" "$TMP/state"
  mkdir -p "$TMP/audit" "$TMP/state/sqlite-backups"
  printf 'active\n' >"$TMP/service-state"
  cp "$TMP/sqlite.env" "$TMP/go.env"
}

assert_sqlite_env_exact() {
  local saved_env
  saved_env=$(find "$TMP/audit" -type f -name go-env.before -print -quit)
  [[ -n $saved_env ]]
  cmp -s "$TMP/go.env" "$saved_env"
  cmp -s "$TMP/go.env" "$TMP/sqlite.env"
}

assert_candidate_env_exact() { cmp -s "$TMP/go.env" "$TMP/candidate.env"; }

run_gate() {
  "$GATE_SCRIPT" --state-root "$TMP/gate-state" --go-env "$TMP/gate.env" \
    --expected-owner "$(id -u)"
}

assert_no_secret_metadata() {
  if grep -R -E 'postgres(ql)?://|test\.fresh_admin-token' \
      "$TMP/state/cutover-journal" "$TMP/state/pg-write-boundary" "$TMP/audit" 2>/dev/null; then
    echo 'durable metadata or audit output leaked a DSN/token' >&2
    exit 1
  fi
}

run_cutover --dry-run >/dev/null
grep -Rq '^DRY_RUN ' "$TMP/audit"
candidate_hash=$(sha256sum "$TMP/candidate.env" | awk '{print $1}')
test -f "$TMP/state/artifacts/abcdef123-${candidate_hash}.env"

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

# Dry-run does not freeze SQLite and therefore permits a live sidecar.
touch "$TMP/source.db-wal"
run_cutover --dry-run >/dev/null
rm -f "$TMP/source.db-wal"

for point in after_gate after_stop after_backup before_marker; do
  reset_fixture
  if LMM_CUTOVER_KILL_AT=$point run_cutover >/dev/null 2>&1; then
    echo "SIGKILL injection at $point did not terminate cutover" >&2; exit 1
  fi
  # A PostgreSQL-capable environment must never be visible without its marker.
  if grep -Eq '^SQL_DSN=postgresql://' "$TMP/go.env"; then
    test -f "$TMP/state/pg-write-boundary"
  fi
  run_reconcile >/dev/null
  assert_sqlite_env_exact
  grep -Fq 'phase=ROLLED_BACK_SQLITE' "$TMP/state/cutover-journal"
  [[ $(cat "$TMP/service-state") == active ]]
  [[ ! -e $TMP/state/pg-write-boundary && ! -e $TMP/state/cutover-in-progress ]]
  run_reconcile >/dev/null
  assert_no_secret_metadata
done

for point in after_marker after_env after_start before_canary after_public_canary after_canary; do
  reset_fixture
  if LMM_CUTOVER_KILL_AT=$point run_cutover >/dev/null 2>&1; then
    echo "SIGKILL injection at $point did not terminate cutover" >&2; exit 1
  fi
  if grep -Eq '^SQL_DSN=postgresql://' "$TMP/go.env"; then
    test -f "$TMP/state/pg-write-boundary"
  fi
  run_reconcile >/dev/null
  assert_candidate_env_exact
  grep -Fq 'phase=COMPLETE' "$TMP/state/cutover-journal"
  test -f "$TMP/state/pg-write-boundary"
  [[ ! -e $TMP/state/cutover-in-progress && $(cat "$TMP/service-state") == active ]]
  run_reconcile >/dev/null
  assert_no_secret_metadata
done

# A candidate hash match is forward-only evidence even if an older coordinator
# died before writing its marker. Reconcile must recreate the marker, never
# restore SQLite.
reset_fixture
if LMM_CUTOVER_KILL_AT=after_env run_cutover >/dev/null 2>&1; then exit 1; fi
rm -f "$TMP/state/pg-write-boundary"
run_reconcile >/dev/null
test -f "$TMP/state/pg-write-boundary"
assert_candidate_env_exact

# Direction is inferred before snapshot validation: corruption of the
# irrelevant snapshot must not block the only legal recovery direction.
reset_fixture
if LMM_CUTOVER_KILL_AT=before_marker run_cutover >/dev/null 2>&1; then exit 1; fi
printf 'corrupt irrelevant candidate\n' >"$TMP/state/artifacts/abcdef123-${candidate_hash}.env"
run_reconcile >/dev/null
assert_sqlite_env_exact
[[ ! -e $TMP/state/pg-write-boundary ]]

reset_fixture
if LMM_CUTOVER_KILL_AT=after_marker run_cutover >/dev/null 2>&1; then exit 1; fi
saved_env=$(find "$TMP/audit" -type f -name go-env.before -print -quit)
printf 'corrupt irrelevant SQLite snapshot\n' >"$saved_env"
run_reconcile >/dev/null
assert_candidate_env_exact
test -f "$TMP/state/pg-write-boundary"

# Boot preparation resolves direction and clears the gate before systemd is
# allowed to start lmm-api; the post-start reconciler then runs both canaries.
reset_fixture
if LMM_CUTOVER_KILL_AT=after_marker run_cutover >/dev/null 2>&1; then exit 1; fi
run_reconcile --prepare-start >/dev/null
grep -Fq 'phase=FORWARD_READY' "$TMP/state/cutover-journal"
assert_candidate_env_exact
[[ $(cat "$TMP/service-state") == inactive && ! -e $TMP/state/cutover-in-progress ]]
"$GATE_SCRIPT" --state-root "$TMP/state" --go-env "$TMP/go.env" \
  --expected-owner "$(id -u)"
PATH="$TMP/bin:$PATH" LMM_TEST_SERVICE_STATE="$TMP/service-state" systemctl start lmm-api.service
run_reconcile >/dev/null
grep -Fq 'phase=COMPLETE' "$TMP/state/cutover-journal"

# Every Go start independently verifies the durable activation law.
rm -rf "$TMP/gate-state"; mkdir -p "$TMP/gate-state"
cp "$TMP/sqlite.env" "$TMP/gate.env"
run_gate
touch "$TMP/gate-state/cutover-in-progress"
if run_gate >/dev/null 2>&1; then
  echo 'startup gate allowed an ambiguous cutover' >&2; exit 1
fi
rm -f "$TMP/gate-state/cutover-in-progress"
ln -s missing "$TMP/gate-state/cutover-in-progress"
if run_gate >/dev/null 2>&1; then echo 'startup gate symlink was accepted' >&2; exit 1; fi
rm -f "$TMP/gate-state/cutover-in-progress"

# In the no-boundary SQLite state comments are harmless, but every actual or
# ambiguous SQL_DSN assignment is rejected without parsing/sourcing its value.
printf '# SQL_DSN="postgresql://comment-secret"\n  ; SQL_DSN = ignored\nSHARED_SECRET=unchanged\n' >"$TMP/gate.env"
chmod 0600 "$TMP/gate.env"
run_gate
quoted_secret='quoted-pg-secret-must-not-be-printed'
printf 'SQL_DSN="postgresql://%s@127.0.0.1/db"\n' "$quoted_secret" >"$TMP/gate.env"
if gate_error=$(run_gate 2>&1); then echo 'quoted PostgreSQL env without boundary was accepted' >&2; exit 1; fi
[[ $gate_error != *"$quoted_secret"* ]]
printf '  SQL_DSN = "postgresql://whitespace@127.0.0.1/db"\n' >"$TMP/gate.env"
if run_gate >/dev/null 2>&1; then echo 'whitespace SQL_DSN assignment was accepted' >&2; exit 1; fi
printf 'SQL_DSN=sqlite-safe-looking\nSQL_DSN="postgresql://duplicate@127.0.0.1/db"\n' >"$TMP/gate.env"
if run_gate >/dev/null 2>&1; then echo 'duplicate SQL_DSN assignments were accepted' >&2; exit 1; fi
printf 'SQL_DSN "postgresql://ambiguous@127.0.0.1/db"\n' >"$TMP/gate.env"
if run_gate >/dev/null 2>&1; then echo 'ambiguous SQL_DSN-like line was accepted' >&2; exit 1; fi

cp "$TMP/candidate.env" "$TMP/gate.env"
if run_gate >/dev/null 2>&1; then echo 'PostgreSQL env without boundary was accepted' >&2; exit 1; fi

gate_candidate_hash=$(sha256sum "$TMP/gate.env" | awk '{print $1}')
printf 'transaction=20260801T000000Z-abcdef123-123 revision=abcdef123 schema=lmm_prod_test candidate_sha256=%s crossed_at=2026-08-01T00:00:00Z\n' \
  "$gate_candidate_hash" >"$TMP/gate-state/pg-write-boundary"
chmod 0600 "$TMP/gate-state/pg-write-boundary"
run_gate
chmod 0644 "$TMP/gate-state/pg-write-boundary"
if run_gate >/dev/null 2>&1; then echo 'unsafe boundary permissions were accepted' >&2; exit 1; fi
chmod 0600 "$TMP/gate-state/pg-write-boundary"
cp "$TMP/sqlite.env" "$TMP/gate.env"
if run_gate >/dev/null 2>&1; then echo 'boundary with SQLite env was accepted' >&2; exit 1; fi
printf 'different environment\n' >"$TMP/gate.env"
if run_gate >/dev/null 2>&1; then echo 'boundary hash mismatch was accepted' >&2; exit 1; fi
marker_secret='marker-secret-must-not-be-printed'
printf 'malformed marker %s\n' "$marker_secret" >"$TMP/gate-state/pg-write-boundary"
if gate_error=$(run_gate 2>&1); then echo 'malformed boundary was accepted' >&2; exit 1; fi
[[ $gate_error != *"$marker_secret"* ]]
rm -f "$TMP/gate-state/pg-write-boundary"
printf 'transaction=20260801T000000Z-abcdef123-123 revision=abcdef123 schema=lmm_prod_test candidate_sha256=%s crossed_at=2026-08-01T00:00:00Z\n' \
  "$gate_candidate_hash" >"$TMP/gate-state/marker-target"
chmod 0600 "$TMP/gate-state/marker-target"
ln -s marker-target "$TMP/gate-state/pg-write-boundary"
cp "$TMP/candidate.env" "$TMP/gate.env"
if run_gate >/dev/null 2>&1; then echo 'boundary symlink was accepted' >&2; exit 1; fi

# Journal parsing never evaluates writable text.
owned="$TMP/journal-was-sourced"
dollar='$'
unsafe_transaction="${dollar}(touch ${owned})"
printf 'version=1 transaction=%s phase=GATED revision=abcdef123 schema=lmm_prod_test candidate_sha256=%s old_env_sha256=%s\n' \
  "$unsafe_transaction" \
  aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa \
  bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb \
  >"$TMP/state/cutover-journal"
if run_reconcile >/dev/null 2>&1; then echo 'unsafe journal was accepted' >&2; exit 1; fi
[[ ! -e $owned ]]

# Checked-in systemd assets establish the boot ordering and gate semantics that
# the installer publishes without replacing application secrets/configuration.
grep -Fxq 'Before=lmm-api.service' "$HERE/lmm-api-cutover-reconcile.service"
grep -Fxq 'After=lmm-api-cutover-reconcile.service' "$HERE/lmm-api-cutover.conf"
grep -Fxq 'ExecCondition=/usr/lib/lmm-api-cutover/lmm-api-cutover-gate.sh' "$HERE/lmm-api-cutover.conf"
grep -Fq 'ConditionPathExists=/var/lib/lmm-api-cutover/cutover-journal' "$HERE/lmm-api-cutover-canary.service"
grep -Fxq 'ExecStart=/usr/lib/lmm-api-cutover/cutover-sqlite-to-pg.sh --reconcile-only' "$HERE/lmm-api-cutover-recover.service"
grep -Fq 'OnFailure=lmm-api-cutover-recover.service' "$SCRIPT"
grep -Fq 'enabled_units=(lmm-api-cutover-reconcile.service lmm-api-cutover-canary.service)' "$HERE/install-lmm-api-cutover.sh"
grep -Fq 'systemctl enable ' "$HERE/install-lmm-api-cutover.sh"

# A new transaction must never overwrite an existing fail-closed gate. Only
# the independent reconciler may resolve that state.
reset_fixture
printf 'transaction=orphaned\n' >"$TMP/state/cutover-in-progress"
if run_cutover >/dev/null 2>&1; then echo 'new cutover overwrote an existing gate' >&2; exit 1; fi
grep -Fxq 'transaction=orphaned' "$TMP/state/cutover-in-progress"
[[ ! -e $TMP/state/cutover-journal ]]

reset_fixture
export LMM_CUTOVER_FAIL_AT=migrate
if run_cutover >/dev/null 2>&1; then echo 'pre-marker fault succeeded' >&2; exit 1; fi
unset LMM_CUTOVER_FAIL_AT
assert_sqlite_env_exact
grep -Rq '^FAILED_ROLLED_BACK_SQLITE ' "$TMP/audit"
[[ ! -e $TMP/state/pg-write-boundary ]]

reset_fixture
export LMM_CUTOVER_FAIL_AT=env
if run_cutover >/dev/null 2>&1; then echo 'post-marker fault succeeded' >&2; exit 1; fi
unset LMM_CUTOVER_FAIL_AT
assert_candidate_env_exact
grep -Rq '^SUCCESS_POSTGRES .*reconciled=1' "$TMP/audit"
test -f "$TMP/state/pg-write-boundary"
[[ $(cat "$TMP/service-state") == active ]]

if run_cutover --dry-run >/dev/null 2>&1; then echo 'boundary did not permanently block SQLite retry' >&2; exit 1; fi

reset_fixture
run_cutover >/dev/null
grep -Rq '^SUCCESS_POSTGRES ' "$TMP/audit"
test -f "$TMP/state/pg-write-boundary"
assert_candidate_env_exact
assert_no_secret_metadata
echo 'backend cutover crash-reconciliation safety tests passed'
