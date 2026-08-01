#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

CURRENT_ENV=/etc/lmm-api/lmm-api.env
MIGRATION_ENV=/etc/lmm-api-cutover/migration.env
VALKEY_ACL=/etc/valkey/lmm-api.acl
OUTPUT=
SCHEMA=

usage() {
  echo "usage: ${0##*/} --schema ID --output ABSOLUTE_PATH [--current-env PATH] [--migration-env PATH] [--valkey-acl PATH]" >&2
}
while (($#)); do
  case $1 in
    --schema) SCHEMA=${2:?}; shift 2 ;;
    --output) OUTPUT=${2:?}; shift 2 ;;
    --current-env) CURRENT_ENV=${2:?}; shift 2 ;;
    --migration-env) MIGRATION_ENV=${2:?}; shift 2 ;;
    --valkey-acl) VALKEY_ACL=${2:?}; shift 2 ;;
    --help|-h) usage; exit 0 ;;
    *) usage; exit 2 ;;
  esac
done
[[ ${LMM_CUTOVER_TEST_MODE:-0} == 1 || $EUID -eq 0 ]] || { echo "must run as root" >&2; exit 1; }
[[ $SCHEMA =~ ^[a-z_][a-z0-9_]{0,62}$ ]] || { echo "unsafe schema" >&2; exit 1; }
[[ $OUTPUT == /* && $OUTPUT != "$CURRENT_ENV" ]] || { echo "output must be an absolute path distinct from current env" >&2; exit 1; }
for file in "$CURRENT_ENV" "$MIGRATION_ENV" "$VALKEY_ACL"; do
  [[ -f $file && ! -L $file ]] || { echo "unsafe input file" >&2; exit 1; }
done

migration_line=$(grep -E '^LMM_MIGRATE_DATABASE_URL=postgres(ql)?://' "$MIGRATION_ENV" | head -n1)
[[ -n $migration_line ]] || { echo "migration DSN is missing" >&2; exit 1; }
migration_dsn=${migration_line#*=}
if [[ $migration_dsn == *\?* ]]; then
  application_dsn="${migration_dsn}&options=-csearch_path%3D${SCHEMA}"
else
  application_dsn="${migration_dsn}?options=-csearch_path%3D${SCHEMA}"
fi
valkey_secret=$(awk '$1=="user" && $2=="lmm-api" {for(i=1;i<=NF;i++) if(substr($i,1,1)==">") {print substr($i,2); exit}}' "$VALKEY_ACL")
[[ $valkey_secret =~ ^[A-Za-z0-9._~-]{16,}$ ]] || { echo "dedicated Valkey credential is missing or URL-unsafe" >&2; exit 1; }

dir=${OUTPUT%/*}; base=${OUTPUT##*/}
mkdir -p "$dir"
temp="$dir/.${base}.$$.tmp"
grep -Ev '^(SQL_DSN|REDIS_CONN_STRING)=' "$CURRENT_ENV" >"$temp"
printf 'SQL_DSN=%s\nREDIS_CONN_STRING=redis://lmm-api:%s@127.0.0.1:6380/0\n' \
  "$application_dsn" "$valkey_secret" >>"$temp"
chmod 0600 "$temp"
if [[ ${LMM_CUTOVER_TEST_MODE:-0} != 1 ]]; then chown root:root "$temp"; fi
sync -f "$temp"
mv -Tf "$temp" "$OUTPUT"
sync -f "$dir"
unset migration_line migration_dsn application_dsn valkey_secret
echo "candidate environment created atomically"
