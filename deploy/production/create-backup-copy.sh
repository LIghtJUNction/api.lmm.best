#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

die() { printf 'create-backup-copy: %s\n' "$*" >&2; exit 2; }
is_safe_value() { [[ $1 =~ ^[A-Za-z0-9][A-Za-z0-9._:+@,-]{0,255}$ ]]; }
is_sha256() { [[ $1 =~ ^[0-9a-f]{64}$ ]]; }

COPY_ROLE=''
OUTPUT=''
DEPLOYMENT_ID=''
VERIFIED_HOST=''
RELEASE_ID=''
ARTIFACT_SHA256=''
CORE_SHA256=''
BACKEND_SHA256=''
GIT_REVISION=''
SERVICE_STATE=''
FRONTEND_RELEASE=''
APPLICATION=''
FRONTEND=''
CONFIGURATION=''
DATABASE=''
AGE_RECIPIENT_FILE=''
while (($#)); do
  case $1 in
    --copy-role) COPY_ROLE=${2:?}; shift 2 ;;
    --output) OUTPUT=${2:?}; shift 2 ;;
    --deployment-id) DEPLOYMENT_ID=${2:?}; shift 2 ;;
    --verified-host) VERIFIED_HOST=${2:?}; shift 2 ;;
    --release-id) RELEASE_ID=${2:?}; shift 2 ;;
    --artifact-sha256) ARTIFACT_SHA256=${2:?}; shift 2 ;;
    --core-sha256) CORE_SHA256=${2:?}; shift 2 ;;
    --backend-sha256) BACKEND_SHA256=${2:?}; shift 2 ;;
    --git-revision) GIT_REVISION=${2:?}; shift 2 ;;
    --service-state) SERVICE_STATE=${2:?}; shift 2 ;;
    --frontend-release) FRONTEND_RELEASE=${2:?}; shift 2 ;;
    --application) APPLICATION=${2:?}; shift 2 ;;
    --frontend) FRONTEND=${2:?}; shift 2 ;;
    --configuration) CONFIGURATION=${2:?}; shift 2 ;;
    --database) DATABASE=${2:?}; shift 2 ;;
    --age-recipient-file) AGE_RECIPIENT_FILE=${2:?}; shift 2 ;;
    *) die "unknown argument: $1" ;;
  esac
done

case $COPY_ROLE in target|controller|off-host) ;; *) die 'copy role must be target, controller, or off-host' ;; esac
[[ $OUTPUT == /* && $OUTPUT != /tmp/* && $OUTPUT != /var/tmp/* ]] || die 'output must be a persistent absolute path'
[[ ! -e $OUTPUT && ! -L $OUTPUT ]] || die 'output already exists'
[[ $DEPLOYMENT_ID =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$ ]] || die 'invalid deployment ID'
is_safe_value "$VERIFIED_HOST" || die 'invalid verified host'
is_safe_value "$RELEASE_ID" || die 'invalid release ID'
is_sha256 "$ARTIFACT_SHA256" || die 'invalid artifact checksum'
is_sha256 "$CORE_SHA256" || die 'invalid core package checksum'
is_sha256 "$BACKEND_SHA256" || die 'invalid backend package checksum'
[[ $GIT_REVISION =~ ^[0-9a-f]{7,64}$ ]] || die 'invalid Git revision'
is_safe_value "$SERVICE_STATE" || die 'invalid service state'
is_safe_value "$FRONTEND_RELEASE" || die 'invalid frontend release'
for input in "$APPLICATION" "$FRONTEND" "$CONFIGURATION" "$DATABASE"; do
  [[ $input == /* && -s $input && -f $input && ! -L $input ]] || die 'backup input is missing, empty, or unsafe'
done
if [[ $COPY_ROLE == controller || $COPY_ROLE == off-host ]]; then
  [[ -f $AGE_RECIPIENT_FILE && ! -L $AGE_RECIPIENT_FILE ]] || die 'encrypted copies require an age recipient file'
  command -v age >/dev/null 2>&1 || die 'age is unavailable'
fi

mkdir -m0700 -- "$OUTPUT"
cleanup=true
trap 'if [[ $cleanup == true ]]; then rm -rf -- "$OUTPUT"; fi' EXIT
install -m0600 -- "$APPLICATION" "$OUTPUT/application.archive"
install -m0600 -- "$FRONTEND" "$OUTPUT/frontend.archive"
configuration_encrypted=false
database_encrypted=false
if [[ $COPY_ROLE == target ]]; then
  install -m0600 -- "$CONFIGURATION" "$OUTPUT/configuration.archive"
  install -m0600 -- "$DATABASE" "$OUTPUT/database.archive"
else
  age --encrypt --recipients-file "$AGE_RECIPIENT_FILE" --output "$OUTPUT/configuration.age" "$CONFIGURATION"
  age --encrypt --recipients-file "$AGE_RECIPIENT_FILE" --output "$OUTPUT/database.age" "$DATABASE"
  chmod 0600 "$OUTPUT/configuration.age" "$OUTPUT/database.age"
  configuration_encrypted=true
  database_encrypted=true
fi

created_at=$(date -u +%FT%TZ)
configuration_name=$([[ $configuration_encrypted == true ]] && printf configuration.age || printf configuration.archive)
database_name=$([[ $database_encrypted == true ]] && printf database.age || printf database.archive)
{
  printf 'format=1\ncreated_at_utc=%s\ndeployment_id=%s\ncopy_role=%s\n' "$created_at" "$DEPLOYMENT_ID" "$COPY_ROLE"
  printf 'deployment_role=production\nverified_host=%s\nrelease_id=%s\n' "$VERIFIED_HOST" "$RELEASE_ID"
  printf 'artifact_sha256=%s\ngit_revision=%s\ndatabase_engine=postgres\n' "$ARTIFACT_SHA256" "$GIT_REVISION"
  printf 'core_sha256=%s\nbackend_sha256=%s\n' "$CORE_SHA256" "$BACKEND_SHA256"
  printf 'service_state=%s\nfrontend_release=%s\n' "$SERVICE_STATE" "$FRONTEND_RELEASE"
  for pair in "application:application.archive:false" "frontend:frontend.archive:false" \
    "configuration:$configuration_name:$configuration_encrypted" "database:$database_name:$database_encrypted"; do
    kind=${pair%%:*}; remainder=${pair#*:}; filename=${remainder%%:*}; encrypted=${remainder##*:}
    file="$OUTPUT/$filename"
    printf '%s_file=%s\n%s_size=%s\n%s_mode=%s\n%s_mtime_utc=%s\n' \
      "$kind" "$filename" "$kind" "$(stat -c %s "$file")" "$kind" "$(stat -c %a "$file")" \
      "$kind" "$(date -u -d "@$(stat -c %Y "$file")" +%FT%TZ)"
    [[ $kind == configuration || $kind == database ]] && printf '%s_encrypted=%s\n' "$kind" "$encrypted"
  done
} >"$OUTPUT/manifest.env"
sha256sum "$OUTPUT"/application.archive "$OUTPUT"/frontend.archive \
  "$OUTPUT/$configuration_name" "$OUTPUT/$database_name" | sed "s|$OUTPUT/||" >"$OUTPUT/SHA256SUMS"
chmod 0600 "$OUTPUT/manifest.env" "$OUTPUT/SHA256SUMS"
cleanup=false
trap - EXIT
printf 'backup_copy=%s\npath=%s\n' "$COPY_ROLE" "$OUTPUT"
