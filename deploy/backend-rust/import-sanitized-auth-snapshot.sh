#!/usr/bin/env bash
# Imports a signed, offline, login-only snapshot into an existing empty test schema.
# It never reads a source database.
set -Eeuo pipefail
umask 077

die() { printf 'import-sanitized-auth-snapshot: %s\n' "$*" >&2; exit 1; }
usage() {
  cat <<'EOF'
Usage: LMM_RS_TEST_INSTANCE=1 DATABASE_URL=... import-sanitized-auth-snapshot.sh \
  --schema lmm_test_<schema> --expected-database lmm_test_<database> \
  --expected-role lmm_test_<role> --snapshot ABS --sha256 ABS \
  --signature ABS --public-key ABS --allow-user-ids ABS [--dry-run]

Imports only the signed sanitized-auth-snapshot-v1 TSV contract into an
existing empty test schema. DATABASE_URL is destination-only, comes solely
from the environment, is never printed, and must resolve to the named
non-privileged lmm_test_* database and role. Snapshot, digest, signature, and
allowlist must be absolute regular non-symlink files with mode 0600.
EOF
}

[[ ${LMM_RS_TEST_INSTANCE:-} == 1 ]] || die 'refusing without LMM_RS_TEST_INSTANCE=1'
[[ -n ${DATABASE_URL:-} ]] || die 'DATABASE_URL must be supplied through the environment'

SCHEMA='' EXPECTED_DATABASE='' EXPECTED_ROLE='' SNAPSHOT='' CHECKSUM='' SIGNATURE=''
PUBLIC_KEY='' ALLOWLIST='' DRY_RUN=0
while (($#)); do
  case $1 in
    --schema) SCHEMA=${2:?}; shift 2 ;;
    --expected-database) EXPECTED_DATABASE=${2:?}; shift 2 ;;
    --expected-role) EXPECTED_ROLE=${2:?}; shift 2 ;;
    --snapshot) SNAPSHOT=${2:?}; shift 2 ;;
    --sha256) CHECKSUM=${2:?}; shift 2 ;;
    --signature) SIGNATURE=${2:?}; shift 2 ;;
    --public-key) PUBLIC_KEY=${2:?}; shift 2 ;;
    --allow-user-ids) ALLOWLIST=${2:?}; shift 2 ;;
    --dry-run) DRY_RUN=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown argument: $1" ;;
  esac
done

safe_test_identifier() {
  [[ $1 =~ ^lmm_test_[a-z][a-z0-9_]{0,48}$ ]] && [[ $1 != public ]]
}
for value in "$SCHEMA" "$EXPECTED_DATABASE" "$EXPECTED_ROLE"; do
  safe_test_identifier "$value" || die 'schema, database, and role must be lmm_test_* identifiers'
done
if [[ $EUID -ne 0 ]]; then
  [[ $DRY_RUN == 1 && ${LMM_SANITIZED_AUTH_IMPORT_TEST_ALLOW_NONROOT:-} == 1 ]] || die 'must run as root'
fi
for command in awk mktemp openssl psql python3 sha256sum stat; do
  command -v "$command" >/dev/null || die "required command unavailable: $command"
done

require_private_input() {
  local file=$1 mode
  [[ $file == /* && -f $file && ! -L $file ]] || die 'snapshot inputs must be absolute regular non-symlink files'
  mode=$(stat -c '%a' "$file") || die 'cannot inspect snapshot input mode'
  [[ $mode == 600 ]] || die 'snapshot, digest, signature, and allowlist must have mode 0600'
}
require_private_input "$SNAPSHOT"
require_private_input "$CHECKSUM"
require_private_input "$SIGNATURE"
require_private_input "$ALLOWLIST"
[[ $PUBLIC_KEY == /* && -f $PUBLIC_KEY && ! -L $PUBLIC_KEY ]] || die 'public key must be an absolute regular non-symlink file'
public_key_mode=$(stat -c '%a' "$PUBLIC_KEY") || die 'cannot inspect public key mode'
(( (8#$public_key_mode & 8#022) == 0 )) || die 'public key must not be group/world writable'

expected_sha=$(tr -d '\n' <"$CHECKSUM")
[[ $expected_sha =~ ^[0-9a-f]{64}$ ]] || die 'checksum must contain exactly one lowercase SHA-256 digest'
[[ $(wc -l <"$CHECKSUM" | tr -d ' ') == 1 ]] || die 'checksum must contain exactly one line'
actual_sha=$(sha256sum "$SNAPSHOT" | awk '{print $1}')
[[ $actual_sha == "$expected_sha" ]] || die 'snapshot SHA-256 mismatch'
openssl pkey -pubin -in "$PUBLIC_KEY" -noout >/dev/null 2>&1 || die 'public key is not a readable PEM public key'
openssl dgst -sha256 -verify "$PUBLIC_KEY" -signature "$SIGNATURE" "$SNAPSHOT" >/dev/null 2>&1 || die 'snapshot signature verification failed'

work=$(mktemp -d "${TMPDIR:-/tmp}/lmm-sanitized-auth-import.XXXXXXXX")
trap 'rm -rf -- "$work"' EXIT
chmod 0700 "$work"
staged_rows="$work/users.csv"
row_count_file="$work/row-count"

python3 - "$SNAPSHOT" "$ALLOWLIST" "$staged_rows" "$row_count_file" <<'PY'
import csv
import re
import sys
from pathlib import Path

snapshot, allowlist, staged, count_path = map(Path, sys.argv[1:])
header = ["id", "username", "password_bcrypt", "display_name", "role", "status", "group", "quota", "used_quota", "request_count", "auth_version"]
positive = re.compile(r"^[1-9][0-9]*$")
integer = re.compile(r"^-?[0-9]+$")
nonnegative = re.compile(r"^[0-9]+$")
bcrypt = re.compile(r"^\$2[aby]\$(?:0[4-9]|[12][0-9]|3[01])\$[./A-Za-z0-9]{53}$")

def fail(message: str) -> None:
    raise SystemExit(f"snapshot contract rejected: {message}")

def clean_text(value: str, field: str, row: int, required: bool = True) -> str:
    if required and not value:
        fail(f"row {row}: {field} is empty")
    if any(ch in value for ch in ("\t", "\r", "\n", "\x00")):
        fail(f"row {row}: {field} has a forbidden control separator")
    if len(value.encode("utf-8")) > 255:
        fail(f"row {row}: {field} is too long")
    return value

try:
    raw_allowlist = allowlist.read_text(encoding="utf-8").splitlines()
except UnicodeDecodeError:
    fail("allowlist is not UTF-8")
if not raw_allowlist:
    fail("allowlist is empty")
allow_ids: list[int] = []
for line_number, value in enumerate(raw_allowlist, 1):
    if not positive.fullmatch(value):
        fail(f"allowlist line {line_number} is not a positive decimal ID")
    allow_ids.append(int(value))
if allow_ids != sorted(set(allow_ids)):
    fail("allowlist must be strictly ascending with no duplicate IDs")
allow_set = set(allow_ids)

try:
    source = snapshot.open("r", encoding="utf-8", newline="")
except UnicodeDecodeError:
    fail("snapshot is not UTF-8")
with source:
    reader = csv.reader(source, delimiter="\t", strict=True)
    try:
        actual_header = next(reader)
    except StopIteration:
        fail("snapshot is empty")
    if actual_header != header:
        fail("snapshot header is not sanitized-auth-snapshot-v1")
    rows: list[list[str]] = []
    seen: set[int] = set()
    for row_number, row in enumerate(reader, 2):
        if len(row) != len(header):
            fail(f"row {row_number}: expected {len(header)} fields")
        user_id, username, password, display_name, role, status, group, quota, used, requests, auth_version = row
        if not positive.fullmatch(user_id):
            fail(f"row {row_number}: id is not a positive decimal ID")
        user_id_number = int(user_id)
        if user_id_number not in allow_set:
            fail(f"row {row_number}: ID is absent from the allowlist")
        if user_id_number in seen:
            fail(f"row {row_number}: duplicate ID")
        seen.add(user_id_number)
        clean_text(username, "username", row_number)
        clean_text(display_name, "display_name", row_number, required=False)
        clean_text(group, "group", row_number)
        if not bcrypt.fullmatch(password):
            fail(f"row {row_number}: password_bcrypt is not a supported bcrypt verifier")
        if not integer.fullmatch(role) or not integer.fullmatch(status):
            fail(f"row {row_number}: role/status must be decimal integers")
        if not all(nonnegative.fullmatch(value) for value in (quota, used, requests)):
            fail(f"row {row_number}: quota counters must be non-negative decimal integers")
        if not positive.fullmatch(auth_version):
            fail(f"row {row_number}: auth_version must be a positive decimal integer")
        rows.append(row)
if not rows:
    fail("snapshot has no users")
if seen != allow_set:
    fail("snapshot IDs and allowlist IDs differ")
rows.sort(key=lambda row: int(row[0]))
with staged.open("w", encoding="utf-8", newline="") as destination:
    csv.writer(destination, lineterminator="\n").writerows(rows)
count_path.write_text(str(len(rows)), encoding="ascii")
PY
row_count=$(<"$row_count_file")
[[ $row_count =~ ^[1-9][0-9]*$ ]] || die 'snapshot parser did not produce a safe row count'

preflight=$(psql "$DATABASE_URL" -X -v ON_ERROR_STOP=1 -Atq -c "SELECT current_database(), current_user, COALESCE(to_regnamespace('$SCHEMA') IS NOT NULL, FALSE), (SELECT rolsuper OR rolcreaterole OR rolcreatedb FROM pg_roles WHERE rolname = current_user), (SELECT pg_get_userbyid(datdba) = current_user FROM pg_database WHERE datname = current_database())" 2>/dev/null) || die 'destination database preflight failed'
IFS='|' read -r actual_database actual_role schema_exists role_is_privileged role_owns_database <<<"$preflight"
[[ $actual_database == "$EXPECTED_DATABASE" ]] || die 'DATABASE_URL does not select the expected lmm_test_* database'
[[ $actual_role == "$EXPECTED_ROLE" ]] || die 'DATABASE_URL does not authenticate as the expected lmm_test_* role'
[[ $schema_exists == t ]] || die 'target test schema does not exist; create it first with create-sanitized-test-schema.sh'
[[ $role_is_privileged == f && $role_owns_database == t ]] || die 'test role must be non-privileged owner of its dedicated test database'

if ((DRY_RUN)); then
  printf 'DRY_RUN schema=%s database=%s role=%s users=%s source=offline-signed-snapshot credentials=redacted\n' "$SCHEMA" "$EXPECTED_DATABASE" "$EXPECTED_ROLE" "$row_count"
  exit 0
fi

sql="$work/import.sql"
cat >"$sql" <<'SQL'
\set ON_ERROR_STOP on
BEGIN;
SET LOCAL lock_timeout = '5s';
SET LOCAL search_path TO :"schema", pg_catalog;
DO $$
DECLARE
  target_schema text := current_schema(); table_name text; row_count bigint;
  empty_tables text[] := ARRAY['abilities','auth_flows','authz_roles','casbin_rule','channels','checkins','custom_oauth_providers','external_identity_claims','logs','midjourneys','models','passkey_credentials','perf_metrics','prefill_groups','quota_data','redemptions','setups','subscription_orders','subscription_plans','subscription_pre_consume_records','system_instances','system_task_locks','system_tasks','tasks','tokens','top_ups','two_fa_backup_codes','two_fas','user_oauth_bindings','user_sessions','user_subscriptions','users','vendors'];
BEGIN
  IF target_schema !~ '^lmm_test_[a-z][a-z0-9_]{0,48}$' THEN RAISE EXCEPTION 'unsafe test schema'; END IF;
  FOREACH table_name IN ARRAY empty_tables LOOP
    EXECUTE format('SELECT count(*) FROM %I.%I', target_schema, table_name) INTO row_count;
    IF row_count <> 0 THEN RAISE EXCEPTION 'target must remain empty before auth import: %', table_name; END IF;
  END LOOP;
  IF (SELECT count(*) FROM options) <> 6 OR EXISTS (
    SELECT 1 FROM options WHERE NOT (
      (key = 'SystemName' AND value = 'LMM API Test') OR
      (key = 'ServerAddress' AND value = 'https://fallback.lmm.best') OR
      (key = 'SelfUseModeEnabled' AND value = 'false') OR
      (key = 'DemoSiteEnabled' AND value = 'false') OR
      (key = 'RegisterEnabled' AND value = 'false') OR
      (key = 'PasswordLoginEnabled' AND value = 'true')
    )
  ) THEN RAISE EXCEPTION 'target options are not the empty sanitized-schema baseline'; END IF;
END $$;
COPY :"schema".users (id, username, password, display_name, role, status, "group", quota, used_quota, request_count, auth_version)
FROM STDIN WITH (FORMAT csv, HEADER false);
SQL
cat "$staged_rows" >>"$sql"
cat >>"$sql" <<'SQL'
\.
UPDATE users SET
  email = 'user-' || id::text || '@invalid.test',
  github_id = NULL, discord_id = NULL, oidc_id = NULL, wechat_id = NULL,
  telegram_id = NULL, linux_do_id = NULL, access_token = NULL, setting = '{}',
  remark = NULL, stripe_customer = NULL, inviter_id = NULL, deleted_at = NULL,
  aff_code = NULL, aff_count = 0, aff_quota = 0, aff_history = 0,
  created_at = EXTRACT(EPOCH FROM clock_timestamp())::bigint, last_login_at = 0;
INSERT INTO setups (id, version, initialized_at)
VALUES (1, 'sanitized-auth-snapshot-v1', EXTRACT(EPOCH FROM clock_timestamp())::bigint);
INSERT INTO options (key, value) VALUES
  ('SystemName','LMM API Test'), ('ServerAddress','https://fallback.lmm.best'),
  ('SelfUseModeEnabled','false'), ('DemoSiteEnabled','false'), ('RegisterEnabled','false'),
  ('PasswordLoginEnabled','true'), ('PasswordRegisterEnabled','false'),
  ('GitHubOAuthEnabled','false'), ('discord.enabled','false'), ('LinuxDOOAuthEnabled','false'),
  ('TelegramOAuthEnabled','false'), ('TurnstileCheckEnabled','false'), ('TurnstileSiteKey',''),
  ('WaffoEnabled','false'), ('WaffoPancakeEnabled','false'), ('EpayEnabled','false'),
  ('StripeEnabled','false'), ('CreemEnabled','false'),
  ('payment_setting','{"compliance_confirmed":false,"methods":[]}')
ON CONFLICT (key) DO UPDATE SET value = EXCLUDED.value;
SELECT setval(:'schema' || '.users_id_seq', GREATEST((SELECT COALESCE(MAX(id), 1) FROM users), 1), TRUE);
SELECT setval(:'schema' || '.setups_id_seq', 1, TRUE);
DO $$
DECLARE forbidden_count bigint;
BEGIN
  SELECT count(*) INTO forbidden_count FROM users
   WHERE access_token IS NOT NULL OR email !~ '^user-[1-9][0-9]*@invalid\.test$'
      OR github_id IS NOT NULL OR discord_id IS NOT NULL OR oidc_id IS NOT NULL
      OR wechat_id IS NOT NULL OR telegram_id IS NOT NULL OR linux_do_id IS NOT NULL
      OR stripe_customer IS NOT NULL OR remark IS NOT NULL OR setting <> '{}';
  IF forbidden_count <> 0 THEN RAISE EXCEPTION 'sanitization failed: imported user privacy fields'; END IF;
  IF (SELECT count(*) FROM setups) <> 1 OR (SELECT count(*) FROM users) = 0 THEN RAISE EXCEPTION 'sanitization failed: synthetic setup or users missing'; END IF;
  IF (SELECT count(*) FROM options) <> 19 OR EXISTS (
    SELECT 1 FROM options WHERE NOT (
      (key = 'SystemName' AND value = 'LMM API Test') OR
      (key = 'ServerAddress' AND value = 'https://fallback.lmm.best') OR
      (key = 'SelfUseModeEnabled' AND value = 'false') OR
      (key = 'DemoSiteEnabled' AND value = 'false') OR
      (key = 'RegisterEnabled' AND value = 'false') OR
      (key = 'PasswordLoginEnabled' AND value = 'true') OR
      (key = 'PasswordRegisterEnabled' AND value = 'false') OR
      (key = 'GitHubOAuthEnabled' AND value = 'false') OR
      (key = 'discord.enabled' AND value = 'false') OR
      (key = 'LinuxDOOAuthEnabled' AND value = 'false') OR
      (key = 'TelegramOAuthEnabled' AND value = 'false') OR
      (key = 'TurnstileCheckEnabled' AND value = 'false') OR
      (key = 'TurnstileSiteKey' AND value = '') OR
      (key = 'WaffoEnabled' AND value = 'false') OR
      (key = 'WaffoPancakeEnabled' AND value = 'false') OR
      (key = 'EpayEnabled' AND value = 'false') OR
      (key = 'StripeEnabled' AND value = 'false') OR
      (key = 'CreemEnabled' AND value = 'false') OR
      (key = 'payment_setting' AND value = '{"compliance_confirmed":false,"methods":[]}')
    )
  ) THEN RAISE EXCEPTION 'sanitization failed: test-only option allowlist'; END IF;
  IF EXISTS (SELECT 1 FROM auth_flows) OR EXISTS (SELECT 1 FROM passkey_credentials) OR EXISTS (SELECT 1 FROM tokens)
    OR EXISTS (SELECT 1 FROM two_fas) OR EXISTS (SELECT 1 FROM two_fa_backup_codes) OR EXISTS (SELECT 1 FROM user_oauth_bindings)
    OR EXISTS (SELECT 1 FROM user_sessions) OR EXISTS (SELECT 1 FROM top_ups) OR EXISTS (SELECT 1 FROM subscription_orders)
    OR EXISTS (SELECT 1 FROM logs) OR EXISTS (SELECT 1 FROM tasks) OR EXISTS (SELECT 1 FROM channels) OR EXISTS (SELECT 1 FROM custom_oauth_providers) THEN
    RAISE EXCEPTION 'sanitization failed: forbidden state exists';
  END IF;
END $$;
COMMIT;
SQL
psql "$DATABASE_URL" -X -v ON_ERROR_STOP=1 -v schema="$SCHEMA" -f "$sql" >/dev/null || die 'auth snapshot transaction failed and was rolled back'
printf 'sanitized auth snapshot imported: schema=%s database=%s role=%s users=%s source=offline-signed-snapshot credentials=redacted\n' "$SCHEMA" "$EXPECTED_DATABASE" "$EXPECTED_ROLE" "$row_count"
