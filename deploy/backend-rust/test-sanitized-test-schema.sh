#!/usr/bin/env bash
set -Eeuo pipefail

HERE=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
SCRIPT="$HERE/create-sanitized-test-schema.sh"
[[ -f $SCRIPT && ! -L $SCRIPT ]] || { echo 'missing sanitizer' >&2; exit 1; }
bash -n "$SCRIPT"

tmp=$(mktemp -d "${TMPDIR:-/tmp}/lmm-sanitized-schema-test.XXXXXXXX")
trap 'rm -rf -- "$tmp"' EXIT
mkdir -p "$tmp/bin"
cat >"$tmp/bin/psql" <<'EOF'
#!/usr/bin/env bash
[[ ${1:-} == postgres://secret ]] || { echo 'psql did not receive DATABASE_URL' >&2; exit 92; }
shift
if [[ $* == *'current_database()'* ]]; then printf 'lmm_test_runtime|lmm_test_runtime|f|f|t\n'; exit 0; fi
echo 'psql should not be reached in this test' >&2; exit 91
EOF
chmod 0755 "$tmp/bin/psql"

for file in manifest baseline catalog contract provenance oracle api migrator; do
  printf '%s\n' "$file" >"$tmp/$file"
done
chmod 0755 "$tmp/api" "$tmp/migrator"
revision=abcdef123
component_json='{'
for pair in \
  "api-server-binary:$tmp/api" "db-migrator-binary:$tmp/migrator" \
  "postgresql-baseline:$tmp/baseline" "table-manifest:$tmp/manifest" \
  "postgres-catalog-exporter:$tmp/catalog" "platform-contract-sql:$tmp/contract" \
  "migration-provenance:$tmp/provenance" "legacy-route-oracle:$tmp/oracle"; do
  name=${pair%%:*}; file=${pair#*:}; hash=$(sha256sum "$file" | awk '{print $1}')
  component_json+="\"$name\":\"$hash\","
done
revision_hash=$(printf %s "$revision" | sha256sum | awk '{print $1}')
component_json+="\"api-server-revision\":\"$revision_hash\"}"
cat >"$tmp/release.json" <<EOF
{"contract_id":1,"contract_sha256":"$(sha256sum "$tmp/contract" | awk '{print $1}')","min_reader_version":1,"max_reader_version":1,"min_writer_version":1,"max_writer_version":1,"release_id":"test-release","release_sha256":"$(sha256sum "$tmp/manifest" | awk '{print $1}')","components":$component_json}
EOF

dry_args=(--schema lmm_test_runtime --expected-database lmm_test_runtime --expected-role lmm_test_runtime
  --manifest "$tmp/manifest" --baseline "$tmp/baseline" --catalog-sql "$tmp/catalog"
  --contract-migration "$tmp/contract" --provenance "$tmp/provenance" --legacy-route-oracle "$tmp/oracle"
  --api-server-binary "$tmp/api" --db-migrator-binary "$tmp/migrator" --api-server-revision "$revision"
  --release-metadata "$tmp/release.json" --dry-run)

if PATH="$tmp/bin:$PATH" DATABASE_URL='postgres://secret' "$SCRIPT" --schema lmm_test_runtime --expected-database lmm_test_runtime --expected-role lmm_test_runtime >/dev/null 2>&1; then
  echo 'missing test-instance guard unexpectedly succeeded' >&2; exit 1
fi
if LMM_RS_TEST_INSTANCE=1 LMM_SANITIZER_TEST_ALLOW_NONROOT=1 PATH="$tmp/bin:$PATH" DATABASE_URL='postgres://secret' "$SCRIPT" --schema public --expected-database lmm_test_runtime --expected-role lmm_test_runtime --dry-run >/dev/null 2>&1; then
  echo 'public schema unexpectedly accepted' >&2; exit 1
fi
if LMM_RS_TEST_INSTANCE=1 LMM_SANITIZER_TEST_ALLOW_NONROOT=1 PATH="$tmp/bin:$PATH" DATABASE_URL='postgres://secret' "$SCRIPT" --schema lmm_prod_snapshot_verified_20260801 --expected-database lmm_test_runtime --expected-role lmm_test_runtime --dry-run >/dev/null 2>&1; then
  echo 'verified schema unexpectedly accepted' >&2; exit 1
fi
grep -Fq 'LMM_RS_TEST_INSTANCE=1' "$SCRIPT"
grep -Fq "psql \"\$DATABASE_URL\"" "$SCRIPT"
grep -Fq 'target schema already exists; refusing to alter it' "$SCRIPT"
grep -Fq 'never reads a SQLite backup' "$SCRIPT"
grep -Fq 'DROP SCHEMA' "$SCRIPT" && { echo 'sanitizer must never drop schemas' >&2; exit 1; }
grep -Fq 'TRUNCATE TABLE' "$SCRIPT" && { echo 'sanitizer must not copy then truncate production data' >&2; exit 1; }
do_body=$(sed -n '/^DO \$\$/, /^END \$\$;/p' "$SCRIPT")
[[ -n $do_body ]] || { echo 'sanitizer is missing its transactional assertions' >&2; exit 1; }
grep -Fq "current_setting('lmm.sanitized_schema', true)" <<<"$do_body"
grep -Fq ":'schema'" <<<"$do_body" && { echo 'psql variables must not appear inside DO dollar quoting' >&2; exit 1; }
grep -Fq "dependency.deptype IN ('a', 'i')" "$SCRIPT"
baseline_source="$HERE/../../apps/api-rust/crates/lmm-db-migrate/schema/postgresql-baseline.sql"
if [[ ! -r $baseline_source ]]; then
  baseline_source=/usr/share/lmm-api-rs/migration/postgresql-baseline.sql
fi
[[ -r $baseline_source && ! -L $baseline_source ]] || { echo 'packaged baseline is missing' >&2; exit 1; }
grep -Fq 'ALTER SEQUENCE public.auth_flows_id_seq OWNED BY public.auth_flows.id;' "$baseline_source"
output=$(LMM_RS_TEST_INSTANCE=1 LMM_SANITIZER_TEST_ALLOW_NONROOT=1 PATH="$tmp/bin:$PATH" DATABASE_URL='postgres://secret' "$SCRIPT" "${dry_args[@]}")
grep -Fxq 'DRY_RUN schema=lmm_test_runtime database=lmm_test_runtime role=lmm_test_runtime business_rows=0 sequences=29 credentials=0' <<<"$output"
jq '.contract_sha256 = "0000000000000000000000000000000000000000000000000000000000000000"' "$tmp/release.json" >"$tmp/bad-release.json"
bad_args=("${dry_args[@]}")
for index in "${!bad_args[@]}"; do
  [[ ${bad_args[$index]} == "$tmp/release.json" ]] && bad_args[index]="$tmp/bad-release.json"
done
if LMM_RS_TEST_INSTANCE=1 LMM_SANITIZER_TEST_ALLOW_NONROOT=1 PATH="$tmp/bin:$PATH" DATABASE_URL='postgres://secret' "$SCRIPT" "${bad_args[@]}" >/dev/null 2>&1; then
  echo 'contract SHA mismatch unexpectedly succeeded' >&2; exit 1
fi
echo 'sanitized test schema static guards verified'
