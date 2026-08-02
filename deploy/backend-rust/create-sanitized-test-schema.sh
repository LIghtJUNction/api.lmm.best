#!/usr/bin/env bash
# Creates an empty, contract-bound schema for the isolated fallback test host.
# It deliberately never reads a SQLite backup or another PostgreSQL schema.
set -Eeuo pipefail
umask 077

die() { printf 'create-sanitized-test-schema: %s\n' "$*" >&2; exit 1; }
usage() {
  cat <<'EOF'
Usage: LMM_RS_TEST_INSTANCE=1 DATABASE_URL=... create-sanitized-test-schema.sh \
  --schema lmm_test_<name> --expected-database lmm_test_<name> \
  --expected-role lmm_test_<name> --manifest ABS --baseline ABS \
  --catalog-sql ABS --contract-migration ABS --provenance ABS \
  --legacy-route-oracle ABS --api-server-binary ABS --db-migrator-binary ABS \
  --api-server-revision SAFE_ID --release-metadata ABS [--dry-run]

DATABASE_URL is consumed only by psql and is never printed.  The caller must
pre-create the dedicated database and non-superuser role.  This command creates
one NEW non-public test schema; an existing schema is always rejected.

release-metadata is JSON with contract_id, contract_sha256, reader/writer
ranges, release_id, release_sha256, and exactly the nine component SHA-256
entries required by lmm-db-migrate's release ledger.
EOF
}

[[ -n ${DATABASE_URL:-} ]] || die 'DATABASE_URL must be supplied through the environment'

SCHEMA='' EXPECTED_DATABASE='' EXPECTED_ROLE='' MANIFEST='' BASELINE='' CATALOG_SQL=''
CONTRACT_MIGRATION='' PROVENANCE='' LEGACY_ROUTE_ORACLE='' API_SERVER_BINARY=''
DB_MIGRATOR_BINARY='' API_SERVER_REVISION='' RELEASE_METADATA='' DRY_RUN=0
while (($#)); do
  case $1 in
    --schema) SCHEMA=${2:?}; shift 2 ;;
    --expected-database) EXPECTED_DATABASE=${2:?}; shift 2 ;;
    --expected-role) EXPECTED_ROLE=${2:?}; shift 2 ;;
    --manifest) MANIFEST=${2:?}; shift 2 ;;
    --baseline) BASELINE=${2:?}; shift 2 ;;
    --catalog-sql) CATALOG_SQL=${2:?}; shift 2 ;;
    --contract-migration) CONTRACT_MIGRATION=${2:?}; shift 2 ;;
    --provenance) PROVENANCE=${2:?}; shift 2 ;;
    --legacy-route-oracle) LEGACY_ROUTE_ORACLE=${2:?}; shift 2 ;;
    --api-server-binary) API_SERVER_BINARY=${2:?}; shift 2 ;;
    --db-migrator-binary) DB_MIGRATOR_BINARY=${2:?}; shift 2 ;;
    --api-server-revision) API_SERVER_REVISION=${2:?}; shift 2 ;;
    --release-metadata) RELEASE_METADATA=${2:?}; shift 2 ;;
    --dry-run) DRY_RUN=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown argument: $1" ;;
  esac
done

[[ ${LMM_RS_TEST_INSTANCE:-} == 1 ]] || die 'refusing without LMM_RS_TEST_INSTANCE=1'
if [[ $EUID -ne 0 ]]; then
  [[ $DRY_RUN == 1 && ${LMM_SANITIZER_TEST_ALLOW_NONROOT:-} == 1 ]] || die 'must run as root'
fi

safe_test_identifier() {
  [[ $1 =~ ^lmm_test_[a-z][a-z0-9_]{0,48}$ ]] && [[ $1 != public ]] &&
    [[ $1 != lmm_prod_snapshot_verified_* ]]
}
for value in "$SCHEMA" "$EXPECTED_DATABASE" "$EXPECTED_ROLE"; do
  safe_test_identifier "$value" || die 'schema, database, and role must be distinct lmm_test_* identifiers'
done
[[ $API_SERVER_REVISION =~ ^[A-Za-z0-9._-]{7,128}$ ]] || die 'api server revision is unsafe'

for command in psql jq sha256sum sed mktemp; do command -v "$command" >/dev/null || die "required command unavailable: $command"; done
for file in "$MANIFEST" "$BASELINE" "$CATALOG_SQL" "$CONTRACT_MIGRATION" "$PROVENANCE" "$LEGACY_ROUTE_ORACLE" "$API_SERVER_BINARY" "$DB_MIGRATOR_BINARY" "$RELEASE_METADATA"; do
  [[ $file == /* && -f $file && ! -L $file ]] || die 'every input must be an absolute regular non-symlink file'
done

readonly REQUIRED_COMPONENTS=(
  api-server-binary api-server-revision db-migrator-binary postgresql-baseline
  table-manifest postgres-catalog-exporter platform-contract-sql
  migration-provenance legacy-route-oracle
)
jq -e '
  (.contract_id | type == "number" and floor == . and . > 0) and
  (.contract_sha256|test("^[0-9a-f]{64}$")) and
  (.min_reader_version|type == "number" and floor == . and . > 0) and
  (.max_reader_version|type == "number" and floor == . and . > 0) and
  (.min_writer_version|type == "number" and floor == . and . > 0) and
  (.max_writer_version|type == "number" and floor == . and . > 0) and
  (.release_id|test("^[A-Za-z0-9._+-]{1,128}$")) and
  (.release_sha256|test("^[0-9a-f]{64}$")) and
  (.components|type == "object")
' "$RELEASE_METADATA" >/dev/null || die 'release metadata is malformed'

for component in "${REQUIRED_COMPONENTS[@]}"; do
  value=$(jq -er --arg component "$component" '.components[$component]' "$RELEASE_METADATA") || die "missing ledger component: $component"
  [[ $value =~ ^[0-9a-f]{64}$ ]] || die "invalid ledger component: $component"
done
component_count=$(jq -r '.components | length' "$RELEASE_METADATA")
[[ $component_count == "${#REQUIRED_COMPONENTS[@]}" ]] || die 'release metadata has unknown ledger components'

assert_component_file() {
  local component=$1 file=$2 expected actual
  expected=$(jq -er --arg component "$component" '.components[$component]' "$RELEASE_METADATA")
  actual=$(sha256sum "$file" | awk '{print $1}')
  [[ $actual == "$expected" ]] || die "release metadata hash mismatch: $component"
}
assert_component_file postgresql-baseline "$BASELINE"
assert_component_file table-manifest "$MANIFEST"
assert_component_file postgres-catalog-exporter "$CATALOG_SQL"
assert_component_file platform-contract-sql "$CONTRACT_MIGRATION"
assert_component_file migration-provenance "$PROVENANCE"
assert_component_file legacy-route-oracle "$LEGACY_ROUTE_ORACLE"
assert_component_file api-server-binary "$API_SERVER_BINARY"
assert_component_file db-migrator-binary "$DB_MIGRATOR_BINARY"
actual_contract_sha=$(sha256sum "$CONTRACT_MIGRATION" | awk '{print $1}')
[[ $actual_contract_sha == $(jq -er '.contract_sha256' "$RELEASE_METADATA") ]] || \
  die 'release metadata contract_sha256 does not match contract migration'
revision_hash=$(printf %s "$API_SERVER_REVISION" | sha256sum | awk '{print $1}')
[[ $revision_hash == $(jq -er '.components["api-server-revision"]' "$RELEASE_METADATA") ]] || die 'release metadata hash mismatch: api-server-revision'

preflight=$(psql "$DATABASE_URL" -X -v ON_ERROR_STOP=1 -Atq \
  -c "SELECT current_database(), current_user, COALESCE(to_regnamespace('$SCHEMA') IS NOT NULL, FALSE), (SELECT rolsuper OR rolcreaterole OR rolcreatedb FROM pg_roles WHERE rolname = current_user), (SELECT pg_get_userbyid(datdba) = current_user FROM pg_database WHERE datname = current_database())" 2>/dev/null) || die 'database preflight failed'
IFS='|' read -r actual_database actual_role schema_exists role_is_privileged role_owns_database <<<"$preflight"
[[ $actual_database == "$EXPECTED_DATABASE" ]] || die 'DATABASE_URL does not select the expected lmm_test_* database'
[[ $actual_role == "$EXPECTED_ROLE" ]] || die 'DATABASE_URL does not authenticate as the expected lmm_test_* role'
[[ $schema_exists == f ]] || die 'target schema already exists; refusing to alter it'
[[ $role_is_privileged == f && $role_owns_database == t ]] || die 'test role must be non-privileged owner of its dedicated test database'

work=$(mktemp -d "${TMPDIR:-/tmp}/lmm-sanitized-schema.XXXXXXXX")
trap 'rm -rf -- "$work"' EXIT
chmod 0700 "$work"
sql="$work/create.sql"
baseline_sql="$work/baseline.sql"
contract_sql="$work/contract.sql"
sed "s/public\./\"$SCHEMA\"\./g" "$BASELINE" >"$baseline_sql"
sed "s/__LMM_APP_SCHEMA__/\"$SCHEMA\"/g" "$CONTRACT_MIGRATION" >"$contract_sql"

contract_id=$(jq -r '.contract_id' "$RELEASE_METADATA")
contract_sha=$(jq -r '.contract_sha256' "$RELEASE_METADATA")
min_reader=$(jq -r '.min_reader_version' "$RELEASE_METADATA")
max_reader=$(jq -r '.max_reader_version' "$RELEASE_METADATA")
min_writer=$(jq -r '.min_writer_version' "$RELEASE_METADATA")
max_writer=$(jq -r '.max_writer_version' "$RELEASE_METADATA")
release_id=$(jq -r '.release_id' "$RELEASE_METADATA")
release_sha=$(jq -r '.release_sha256' "$RELEASE_METADATA")
components=$(jq -c '.components' "$RELEASE_METADATA")

{
cat <<'SQL'
\set ON_ERROR_STOP on
BEGIN;
SET LOCAL lock_timeout = '5s';
CREATE SCHEMA :"schema";
SET LOCAL search_path TO :"schema", pg_catalog;
SQL
cat "$baseline_sql"
cat "$contract_sql"
cat <<'SQL'
INSERT INTO :"schema".lmm_schema_contract
  (singleton, contract_id, contract_sha256, min_reader_version, max_reader_version, min_writer_version, max_writer_version)
VALUES (TRUE, :'contract_id'::bigint, :'contract_sha', :'min_reader'::bigint, :'max_reader'::bigint, :'min_writer'::bigint, :'max_writer'::bigint);
INSERT INTO :"schema".lmm_schema_release_ledger
  (release_id, release_sha256, contract_id, contract_sha256, min_reader_version, max_reader_version, min_writer_version, max_writer_version, component_hashes)
VALUES (:'release_id', :'release_sha', :'contract_id'::bigint, :'contract_sha', :'min_reader'::bigint, :'max_reader'::bigint, :'min_writer'::bigint, :'max_writer'::bigint, :'components'::jsonb);
INSERT INTO :"schema".options(key,value) VALUES
  ('SystemName','LMM API Test'),
  ('ServerAddress','https://fallback.lmm.best'),
  ('SelfUseModeEnabled','false'),
  ('DemoSiteEnabled','false'),
  ('RegisterEnabled','false'),
  ('PasswordLoginEnabled','true');
SELECT set_config('lmm.sanitized_schema', :'schema', true);
DO $$
DECLARE
  target_schema text := current_setting('lmm.sanitized_schema', true); table_name text; sequence_name text; row_count bigint;
  tables text[] := ARRAY['abilities','auth_flows','authz_roles','casbin_rule','channels','checkins','custom_oauth_providers','external_identity_claims','logs','midjourneys','models','options','passkey_credentials','perf_metrics','prefill_groups','quota_data','redemptions','setups','subscription_orders','subscription_plans','subscription_pre_consume_records','system_instances','system_task_locks','system_tasks','tasks','tokens','top_ups','two_fa_backup_codes','two_fas','user_oauth_bindings','user_sessions','user_subscriptions','users','vendors'];
  sequences text[] := ARRAY['auth_flows_id_seq','authz_roles_id_seq','casbin_rule_id_seq','channels_id_seq','checkins_id_seq','custom_oauth_providers_id_seq','external_identity_claims_id_seq','logs_id_seq','midjourneys_id_seq','models_id_seq','passkey_credentials_id_seq','perf_metrics_id_seq','prefill_groups_id_seq','quota_data_id_seq','redemptions_id_seq','setups_id_seq','subscription_orders_id_seq','subscription_plans_id_seq','subscription_pre_consume_records_id_seq','system_tasks_id_seq','tasks_id_seq','tokens_id_seq','top_ups_id_seq','two_fa_backup_codes_id_seq','two_fas_id_seq','user_oauth_bindings_id_seq','user_subscriptions_id_seq','users_id_seq','vendors_id_seq'];
BEGIN
  FOREACH table_name IN ARRAY tables LOOP
    EXECUTE format('SELECT count(*) FROM %I.%I', target_schema, table_name) INTO row_count;
    IF table_name <> 'options' AND row_count <> 0 THEN RAISE EXCEPTION 'sanitization failed: % must be empty', table_name; END IF;
  END LOOP;
  IF EXISTS (SELECT 1 FROM options WHERE key NOT IN ('SystemName','ServerAddress','SelfUseModeEnabled','DemoSiteEnabled','RegisterEnabled','PasswordLoginEnabled')) THEN RAISE EXCEPTION 'sanitization failed: option allowlist'; END IF;
  IF (SELECT count(*) FROM lmm_schema_contract WHERE singleton) <> 1 OR (SELECT count(*) FROM lmm_schema_release_ledger) <> 1 THEN RAISE EXCEPTION 'sanitization failed: contract ledger'; END IF;
  FOREACH sequence_name IN ARRAY sequences LOOP
    table_name := regexp_replace(sequence_name, '_id_seq$', '');
    IF NOT EXISTS (
      SELECT 1 FROM pg_class sequence_class
      JOIN pg_namespace sequence_schema ON sequence_schema.oid = sequence_class.relnamespace
      JOIN pg_depend dependency ON dependency.objid = sequence_class.oid AND dependency.deptype IN ('a', 'i')
      JOIN pg_class table_class ON table_class.oid = dependency.refobjid
      JOIN pg_namespace table_schema ON table_schema.oid = table_class.relnamespace
      JOIN pg_attribute column_ref ON column_ref.attrelid = table_class.oid AND column_ref.attnum = dependency.refobjsubid
      WHERE sequence_schema.nspname = target_schema AND sequence_class.relname = sequence_name
        AND table_schema.nspname = target_schema AND table_class.relname = table_name AND column_ref.attname = 'id'
    ) THEN RAISE EXCEPTION 'sanitization failed: missing owned sequence %', sequence_name; END IF;
  END LOOP;
END $$;
COMMIT;
SQL
} >"$sql"

if ((DRY_RUN)); then
  printf 'DRY_RUN schema=%s database=%s role=%s business_rows=0 sequences=29 credentials=0\n' "$SCHEMA" "$EXPECTED_DATABASE" "$EXPECTED_ROLE"
  exit 0
fi
psql "$DATABASE_URL" -X -v ON_ERROR_STOP=1 -v schema="$SCHEMA" -v contract_id="$contract_id" -v contract_sha="$contract_sha" \
  -v min_reader="$min_reader" -v max_reader="$max_reader" -v min_writer="$min_writer" -v max_writer="$max_writer" \
  -v release_id="$release_id" -v release_sha="$release_sha" -v components="$components" -f "$sql" >/dev/null || die 'schema transaction failed and was rolled back'
printf 'sanitized test schema created: schema=%s database=%s role=%s; initialize root only over loopback before opening nginx\n' "$SCHEMA" "$EXPECTED_DATABASE" "$EXPECTED_ROLE"
