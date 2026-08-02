#!/usr/bin/env bash
# Generate the immutable, non-secret ReleaseBinding JSON before a test deploy.
set -Eeuo pipefail
umask 077

die() { printf 'generate-release-metadata: %s\n' "$*" >&2; exit 1; }
usage() {
  cat <<'EOF'
Usage: generate-release-metadata.sh --revision SAFE_ID --release-id SAFE_ID \
  --release-package ABS --release-sha256 HEX --contract-id POSITIVE \
  --min-reader-version POSITIVE --max-reader-version POSITIVE \
  --min-writer-version POSITIVE --max-writer-version POSITIVE --output ABS \
  --api-server-binary ABS --api-server-revision-file ABS --db-migrator-binary ABS \
  --postgresql-baseline ABS --table-manifest ABS --postgres-catalog-exporter ABS \
  --platform-contract-sql ABS --migration-provenance ABS --legacy-route-oracle ABS

All contract/range values are explicit: this generator deliberately has no
implicit compatibility defaults. release_id must equal revision. release_sha256
must equal the SHA-256 of release-package, which is the exact .pkg.tar.zst
artifact being deployed. The revision file must contain exactly revision (with
one optional final newline); its component hash is SHA-256(revision bytes).
EOF
}

REVISION='' RELEASE_ID='' RELEASE_PACKAGE='' RELEASE_SHA='' CONTRACT_ID=''
MIN_READER='' MAX_READER='' MIN_WRITER='' MAX_WRITER='' OUTPUT=''
API_SERVER_BINARY='' API_SERVER_REVISION_FILE='' DB_MIGRATOR_BINARY=''
POSTGRESQL_BASELINE='' TABLE_MANIFEST='' POSTGRES_CATALOG_EXPORTER=''
PLATFORM_CONTRACT_SQL='' MIGRATION_PROVENANCE='' LEGACY_ROUTE_ORACLE=''
while (($#)); do
  case $1 in
    --revision) REVISION=${2:?}; shift 2 ;;
    --release-id) RELEASE_ID=${2:?}; shift 2 ;;
    --release-package) RELEASE_PACKAGE=${2:?}; shift 2 ;;
    --release-sha256) RELEASE_SHA=${2:?}; shift 2 ;;
    --contract-id) CONTRACT_ID=${2:?}; shift 2 ;;
    --min-reader-version) MIN_READER=${2:?}; shift 2 ;;
    --max-reader-version) MAX_READER=${2:?}; shift 2 ;;
    --min-writer-version) MIN_WRITER=${2:?}; shift 2 ;;
    --max-writer-version) MAX_WRITER=${2:?}; shift 2 ;;
    --output) OUTPUT=${2:?}; shift 2 ;;
    --api-server-binary) API_SERVER_BINARY=${2:?}; shift 2 ;;
    --api-server-revision-file) API_SERVER_REVISION_FILE=${2:?}; shift 2 ;;
    --db-migrator-binary) DB_MIGRATOR_BINARY=${2:?}; shift 2 ;;
    --postgresql-baseline) POSTGRESQL_BASELINE=${2:?}; shift 2 ;;
    --table-manifest) TABLE_MANIFEST=${2:?}; shift 2 ;;
    --postgres-catalog-exporter) POSTGRES_CATALOG_EXPORTER=${2:?}; shift 2 ;;
    --platform-contract-sql) PLATFORM_CONTRACT_SQL=${2:?}; shift 2 ;;
    --migration-provenance) MIGRATION_PROVENANCE=${2:?}; shift 2 ;;
    --legacy-route-oracle) LEGACY_ROUTE_ORACLE=${2:?}; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown argument: $1" ;;
  esac
done

for command in jq sha256sum mktemp mv chmod wc; do
  command -v "$command" >/dev/null 2>&1 || die "required command unavailable: $command"
done
[[ $REVISION =~ ^[A-Za-z0-9._-]{7,128}$ ]] || die 'revision is unsafe'
[[ $RELEASE_ID =~ ^[A-Za-z0-9._+-]{1,128}$ ]] || die 'release id is unsafe'
[[ $RELEASE_ID == "$REVISION" ]] || die 'release id must equal the exact build revision'
[[ $RELEASE_SHA =~ ^[0-9a-f]{64}$ ]] || die 'release SHA-256 is invalid'
for version in "$CONTRACT_ID" "$MIN_READER" "$MAX_READER" "$MIN_WRITER" "$MAX_WRITER"; do
  [[ $version =~ ^[1-9][0-9]*$ ]] || die 'contract and compatibility versions must be positive integers'
  (( version <= 9223372036854775807 )) || die 'version exceeds PostgreSQL BIGINT'
done
(( MAX_READER >= MIN_READER && MAX_WRITER >= MIN_WRITER )) || die 'compatibility range is inverted'

for file in "$RELEASE_PACKAGE" "$API_SERVER_BINARY" "$API_SERVER_REVISION_FILE" "$DB_MIGRATOR_BINARY" \
  "$POSTGRESQL_BASELINE" "$TABLE_MANIFEST" "$POSTGRES_CATALOG_EXPORTER" "$PLATFORM_CONTRACT_SQL" \
  "$MIGRATION_PROVENANCE" "$LEGACY_ROUTE_ORACLE"; do
  [[ $file == /* && -f $file && ! -L $file ]] || die 'every component and package input must be an absolute regular non-symlink file'
done
[[ $OUTPUT == /* ]] || die 'output must be an absolute path'
output_dir=${OUTPUT%/*}
[[ -d $output_dir && ! -L $output_dir ]] || die 'output directory is unsafe'
if [[ -e $OUTPUT ]]; then [[ -f $OUTPUT && ! -L $OUTPUT ]] || die 'output target is unsafe'; fi

actual_release_sha=$(sha256sum "$RELEASE_PACKAGE" | awk '{print $1}')
[[ $actual_release_sha == "$RELEASE_SHA" ]] || die 'release SHA-256 does not match exact package artifact'
revision_from_file=$(<"$API_SERVER_REVISION_FILE")
[[ $(wc -l <"$API_SERVER_REVISION_FILE") -le 1 ]] || die 'revision file must contain one line at most'
[[ $revision_from_file == "$REVISION" ]] || die 'revision file does not exactly match revision'

file_hash() { sha256sum "$1" | awk '{print $1}'; }
contract_sha=$(file_hash "$PLATFORM_CONTRACT_SQL")
tmp=$(mktemp "$output_dir/.release-metadata.XXXXXXXX")
trap 'rm -f -- "$tmp"' EXIT
chmod 0600 "$tmp"
jq -n \
  --argjson contract_id "$CONTRACT_ID" --arg contract_sha "$contract_sha" \
  --argjson min_reader "$MIN_READER" --argjson max_reader "$MAX_READER" \
  --argjson min_writer "$MIN_WRITER" --argjson max_writer "$MAX_WRITER" \
  --arg release_id "$RELEASE_ID" --arg release_sha "$RELEASE_SHA" \
  --arg api "$(file_hash "$API_SERVER_BINARY")" \
  --arg revision "$(printf %s "$REVISION" | sha256sum | awk '{print $1}')" \
  --arg migrator "$(file_hash "$DB_MIGRATOR_BINARY")" \
  --arg baseline "$(file_hash "$POSTGRESQL_BASELINE")" \
  --arg manifest "$(file_hash "$TABLE_MANIFEST")" \
  --arg catalog "$(file_hash "$POSTGRES_CATALOG_EXPORTER")" \
  --arg contract "$(file_hash "$PLATFORM_CONTRACT_SQL")" \
  --arg provenance "$(file_hash "$MIGRATION_PROVENANCE")" \
  --arg oracle "$(file_hash "$LEGACY_ROUTE_ORACLE")" \
  '{contract_id:$contract_id,contract_sha256:$contract_sha,min_reader_version:$min_reader,max_reader_version:$max_reader,min_writer_version:$min_writer,max_writer_version:$max_writer,release_id:$release_id,release_sha256:$release_sha,components:{"api-server-binary":$api,"api-server-revision":$revision,"db-migrator-binary":$migrator,"postgresql-baseline":$baseline,"table-manifest":$manifest,"postgres-catalog-exporter":$catalog,"platform-contract-sql":$contract,"migration-provenance":$provenance,"legacy-route-oracle":$oracle}}' >"$tmp"
jq -e '
  (.components | keys | sort) == ["api-server-binary","api-server-revision","db-migrator-binary","legacy-route-oracle","migration-provenance","platform-contract-sql","postgres-catalog-exporter","postgresql-baseline","table-manifest"] and
  .contract_sha256 == .components["platform-contract-sql"]
' "$tmp" >/dev/null || die 'generated release metadata failed self-validation'
chmod 0600 "$tmp"
mv -f -- "$tmp" "$OUTPUT"
trap - EXIT
printf 'release metadata written: %s\n' "$OUTPUT"
