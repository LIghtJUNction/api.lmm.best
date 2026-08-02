#!/usr/bin/env bash
# Install or roll back only the isolated fallback Nginx assets.  This is not a
# production routing tool: the machine-bound guard is deliberately mandatory.
set -Eeuo pipefail
umask 077

die() { printf 'install-fallback-nginx: %s\n' "$*" >&2; exit 1; }
log() { printf 'install-fallback-nginx: %s\n' "$*" >&2; }

[[ ${1:-} == install && $# -eq 1 || ${1:-} == rollback && $# -eq 2 ]] || \
  die 'usage: install-fallback-nginx.sh install | rollback BACKUP_ID'
readonly ACTION=$1
readonly REQUESTED_BACKUP=${2:-}
[[ -z $REQUESTED_BACKUP || $REQUESTED_BACKUP =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$ ]] || \
  die 'unsafe backup id'

ROOT_PREFIX=
if [[ ${LMM_RS_MOCK:-0} == 1 ]]; then
  [[ ${LMM_FALLBACK_NGINX_TEST_ROOT:-} == /* && ${LMM_FALLBACK_NGINX_TEST_ROOT:-} != / && -d ${LMM_FALLBACK_NGINX_TEST_ROOT:-} ]] || die 'unsafe test root'
  ROOT_PREFIX=${LMM_FALLBACK_NGINX_TEST_ROOT%/}
elif [[ -n ${LMM_FALLBACK_NGINX_TEST_ROOT:-} || -n ${LMM_RS_ASSET_ROOT:-} || -n ${LMM_FALLBACK_TARGET_GUARD:-} ]]; then
  die 'test overrides require LMM_RS_MOCK=1'
fi
readonly ROOT_PREFIX
[[ $EUID -eq 0 || ${LMM_RS_MOCK:-0} == 1 ]] || die 'must run as root'

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
readonly SCRIPT_DIR
readonly ASSET_ROOT=${LMM_RS_ASSET_ROOT:-$SCRIPT_DIR}
readonly GUARD=${LMM_FALLBACK_TARGET_GUARD:-$SCRIPT_DIR/fallback-target-guard.sh}
readonly BACKUP_ROOT=$ROOT_PREFIX/var/lib/lmm-api-rs-fallback-nginx/backups
readonly LOCK=$ROOT_PREFIX/run/lock/lmm-api-rs-fallback-nginx.lock
readonly MAP_TARGET=$ROOT_PREFIX/etc/nginx/lmm-api-http-map.conf
readonly MIME_TARGET=$ROOT_PREFIX/etc/nginx/lmm-api-mime.types
readonly VHOST_TARGET=$ROOT_PREFIX/etc/nginx/conf.d/fallback.lmm.best.conf
readonly CERT_TARGET=$ROOT_PREFIX/etc/letsencrypt/live/fallback.lmm.best/fullchain.pem
readonly KEY_TARGET=$ROOT_PREFIX/etc/letsencrypt/live/fallback.lmm.best/privkey.pem
INSTALL_UID=0
INSTALL_GID=0
if [[ ${LMM_RS_MOCK:-0} == 1 ]]; then
  INSTALL_UID=$(id -u)
  INSTALL_GID=$(id -g)
fi
readonly INSTALL_UID INSTALL_GID
readonly -a KEYS=(map mime vhost)
declare -Ar TARGETS=([map]="$MAP_TARGET" [mime]="$MIME_TARGET" [vhost]="$VHOST_TARGET")
declare -Ar SOURCES=(
  [map]="$ASSET_ROOT/nginx/lmm-api-http-map.conf"
  [mime]="$ASSET_ROOT/nginx/lmm-api-mime.types"
  [vhost]="$ASSET_ROOT/nginx/fallback.lmm.best.conf"
)

[[ -x $GUARD && ! -L $GUARD ]] || die 'missing or unsafe fallback target guard'
# The guard is intentionally before lock or directory creation: a rejected
# machine has no filesystem side effects from this privileged script.
"$GUARD"

for tool in flock install mv cp rm mkdir chmod chown stat sha256sum nginx curl openssl cmp date; do
  command -v "$tool" >/dev/null || die "missing required command: $tool"
done
for key in "${KEYS[@]}"; do
  [[ -f ${SOURCES[$key]} && ! -L ${SOURCES[$key]} ]] || die "missing or unsafe source: ${SOURCES[$key]}"
done

validate_candidate() {
  local server_lines all_server_lines proxy_lines
  server_lines=$(grep -Ec '^[[:space:]]*server_name[[:space:]]+fallback\.lmm\.best;[[:space:]]*$' "${SOURCES[vhost]}")
  all_server_lines=$(grep -Ec '^[[:space:]]*server_name[[:space:]]+' "${SOURCES[vhost]}")
  [[ $server_lines -eq 2 ]] || die 'candidate must contain exactly two fallback server_name directives'
  [[ $all_server_lines -eq 2 ]] || die 'candidate has an unexpected server_name directive'
  ! grep -Fq 'api.lmm.best' "${SOURCES[vhost]}" || die 'candidate mentions a forbidden host'
  grep -Fqx 'include /etc/nginx/lmm-api-http-map.conf;' "${SOURCES[vhost]}" >/dev/null || die 'candidate map include mismatch'
  grep -Fqx '    include /etc/nginx/lmm-api-mime.types;' "${SOURCES[vhost]}" >/dev/null || die 'candidate MIME include mismatch'
  proxy_lines=$(grep -Ec '^[[:space:]]*proxy_pass[[:space:]]+http://127\.0\.0\.1:3100;[[:space:]]*$' "${SOURCES[vhost]}")
  [[ $proxy_lines -eq 1 ]] || die 'candidate must proxy only loopback port 3100'
  [[ $(grep -Ec '^[[:space:]]*proxy_pass[[:space:]]+' "${SOURCES[vhost]}") -eq 1 ]] || die 'candidate has an unexpected proxy target'
  grep -Fqx '    location = /_internal/build { return 404; }' "${SOURCES[vhost]}" >/dev/null || die 'candidate exposes internal build metadata'
  grep -Fqx '    location = /livez { try_files /.__lmm_backend__ @fallback_lmm_api; }' "${SOURCES[vhost]}" >/dev/null || die 'candidate lacks public livez'
  grep -Fqx '    location = /readyz { try_files /.__lmm_backend__ @fallback_lmm_api; }' "${SOURCES[vhost]}" >/dev/null || die 'candidate lacks public readyz'
}

validate_tls() {
  local cert_pub key_pub
  [[ -f $CERT_TARGET && -r $CERT_TARGET && -f $KEY_TARGET && -r $KEY_TARGET ]] || die 'fallback certificate or key is absent'
  openssl x509 -in "$CERT_TARGET" -noout -checkhost fallback.lmm.best >/dev/null || die 'certificate does not match fallback host'
  cert_pub=$(mktemp "${TMPDIR:-/tmp}/lmm-fallback-cert.XXXXXX")
  key_pub=$(mktemp "${TMPDIR:-/tmp}/lmm-fallback-key.XXXXXX")
  trap 'rm -f -- "$cert_pub" "$key_pub"' RETURN
  openssl x509 -in "$CERT_TARGET" -pubkey -noout >"$cert_pub" || die 'cannot read fallback certificate key'
  openssl pkey -in "$KEY_TARGET" -pubout >"$key_pub" || die 'cannot read fallback private key'
  cmp -s "$cert_pub" "$key_pub" || die 'fallback certificate and key differ'
  rm -f -- "$cert_pub" "$key_pub"
  trap - RETURN
}

atomic_install() {
  local source=$1 target=$2 mode=$3 uid=$4 gid=$5 dir temp
  dir=${target%/*}
  mkdir -p -- "$dir" || return
  temp=$(mktemp "$dir/.${target##*/}.XXXXXX") || return
  install -m "$mode" -o "$uid" -g "$gid" -- "$source" "$temp" || { rm -f -- "$temp"; return 1; }
  mv -Tf -- "$temp" "$target"
}

safe_target_or_absent() {
  local target=$1
  [[ ! -e $target && ! -L $target ]] && return 0
  [[ -f $target && ! -L $target ]] || die "unsafe existing target: $target"
}

capture_backup() {
  local backup=$1 key target mode uid gid hash
  : >"$backup/manifest.tmp"
  for key in "${KEYS[@]}"; do
    target=${TARGETS[$key]}
    safe_target_or_absent "$target"
    if [[ -e $target ]]; then
      cp --preserve=mode,ownership -- "$target" "$backup/$key" || return
      mode=$(stat -c '%a' "$target") uid=$(stat -c '%u' "$target") gid=$(stat -c '%g' "$target")
      hash=$(sha256sum "$target" | awk '{print $1}')
      printf '%s present %s %s %s %s\n' "$key" "$mode" "$uid" "$gid" "$hash" >>"$backup/manifest.tmp"
    else
      printf '%s absent - - - -\n' "$key" >>"$backup/manifest.tmp"
    fi
  done
  mv -Tf -- "$backup/manifest.tmp" "$backup/manifest"
}

verify_backup() {
  local backup=$1 key state mode uid gid hash seen=0
  local -A seen_keys=()
  [[ -d $backup && ! -L $backup && -f $backup/manifest && ! -L $backup/manifest ]] || return 1
  while read -r key state mode uid gid hash; do
    case $key in map|mime|vhost) ;; *) return 1 ;; esac
    [[ ${seen_keys[$key]+present} != present ]] || return 1
    seen_keys[$key]=1
    ((seen++))
    case $state in
      present)
        [[ $mode =~ ^[0-7]{3,4}$ && $uid =~ ^[0-9]+$ && $gid =~ ^[0-9]+$ && $hash =~ ^[0-9a-f]{64}$ && -f $backup/$key && ! -L $backup/$key ]] || return 1
        [[ $(sha256sum "$backup/$key" | awk '{print $1}') == "$hash" ]] || return 1
        ;;
      absent) [[ $mode == - && $uid == - && $gid == - && $hash == - ]] || return 1 ;;
      *) return 1 ;;
    esac
  done <"$backup/manifest"
  [[ $seen -eq ${#KEYS[@]} ]]
}

restore_backup() {
  local backup=$1 key state mode uid gid hash target
  verify_backup "$backup" || return 1
  while read -r key state mode uid gid hash; do
    target=${TARGETS[$key]}
    safe_target_or_absent "$target"
    case $state in
      present) atomic_install "$backup/$key" "$target" "$mode" "$uid" "$gid" || return ;;
      absent) rm -f -- "$target" || return ;;
    esac
  done <"$backup/manifest"
  verify_restored "$backup"
}

verify_restored() {
  local backup=$1 key state mode uid gid hash target
  while read -r key state mode uid gid hash; do
    target=${TARGETS[$key]}
    case $state in
      present)
        [[ -f $target && ! -L $target ]] || return 1
        [[ $(stat -c '%a %u %g' "$target") == "$mode $uid $gid" ]] || return 1
        [[ $(sha256sum "$target" | awk '{print $1}') == "$hash" ]] || return 1
        ;;
      absent) [[ ! -e $target && ! -L $target ]] || return 1 ;;
      *) return 1 ;;
    esac
  done <"$backup/manifest"
}

verify_serving() {
  local internal_status
  nginx -t || return
  nginx -s reload || return
  curl --fail --silent --show-error --cacert "$CERT_TARGET" --resolve fallback.lmm.best:443:127.0.0.1 https://fallback.lmm.best/livez >/dev/null || return
  curl --fail --silent --show-error --cacert "$CERT_TARGET" --resolve fallback.lmm.best:443:127.0.0.1 https://fallback.lmm.best/readyz >/dev/null || return
  internal_status=$(curl --silent --show-error --cacert "$CERT_TARGET" \
    --resolve fallback.lmm.best:443:127.0.0.1 --output /dev/null --write-out '%{http_code}' \
    https://fallback.lmm.best/_internal/build) || return
  [[ $internal_status == 404 ]]
}

verify_restored_state() {
  local backup=$1
  verify_restored "$backup" || return
  nginx -t || return
  nginx -s reload || return
  if [[ -f ${TARGETS[vhost]} && -f $CERT_TARGET && -f $KEY_TARGET ]]; then
    verify_serving
  fi
}

install_candidate() {
  local key
  for key in "${KEYS[@]}"; do
    atomic_install "${SOURCES[$key]}" "${TARGETS[$key]}" 0644 "$INSTALL_UID" "$INSTALL_GID" || return
  done
  verify_serving
}

new_backup() {
  local kind=$1 id backup
  id="$kind-$(date -u +%Y%m%dT%H%M%SZ)-$$-$(openssl rand -hex 8)"
  [[ $id =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$ ]] || die 'failed to make safe backup id'
  backup=$BACKUP_ROOT/$id
  mkdir -p -- "$BACKUP_ROOT" || die 'cannot create backup root'
  mkdir -- "$backup" || die 'cannot reserve backup directory'
  chmod 0700 "$backup"
  capture_backup "$backup" || die "cannot capture backup $id"
  printf '%s\n' "$id"
}

mkdir -p -- "${LOCK%/*}"
exec 9>"$LOCK"
flock -n 9 || die 'another fallback nginx transaction is running'

if [[ $ACTION == install ]]; then
  validate_candidate
  validate_tls
  backup_id=$(new_backup install)
  backup=$BACKUP_ROOT/$backup_id
  candidate_status=0
  install_candidate || candidate_status=$?
  if ((candidate_status == 0)); then
    log "installed fallback-only configuration; backup=$backup_id"
    exit 0
  fi
  restore_status=0
  { restore_backup "$backup" && verify_restored_state "$backup"; } || restore_status=$?
  ((restore_status == 0)) || die "candidate failed ($candidate_status) and restore verification failed ($restore_status)"
  die "candidate failed ($candidate_status); byte-identical previous configuration restored and verified"
fi

backup=$BACKUP_ROOT/$REQUESTED_BACKUP
verify_backup "$backup" || die 'unknown or unsafe backup release'
checkpoint_id=$(new_backup rollback)
checkpoint=$BACKUP_ROOT/$checkpoint_id
rollback_status=0
{ restore_backup "$backup" && verify_restored_state "$backup"; } || rollback_status=$?
if ((rollback_status == 0)); then
  log "rolled back to $REQUESTED_BACKUP; safety-checkpoint=$checkpoint_id"
  exit 0
fi
restore_status=0
{ restore_backup "$checkpoint" && verify_restored_state "$checkpoint"; } || restore_status=$?
((restore_status == 0)) || die "rollback failed ($rollback_status) and checkpoint restoration failed ($restore_status)"
die "rollback failed ($rollback_status); byte-identical previous configuration restored and verified"
