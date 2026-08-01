#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_PREFIX=
if [[ -n ${LMM_NGINX_TEST_ROOT:-} ]]; then
  [[ ${LMM_NGINX_TEST_MODE:-} == 1 ]] || { printf 'test root requires LMM_NGINX_TEST_MODE=1\n' >&2; exit 2; }
  [[ $LMM_NGINX_TEST_ROOT = /* && $LMM_NGINX_TEST_ROOT != / && -d $LMM_NGINX_TEST_ROOT ]] || { printf 'unsafe test root\n' >&2; exit 2; }
  ROOT_PREFIX=${LMM_NGINX_TEST_ROOT%/}
fi
readonly ROOT_PREFIX
readonly LOCK=$ROOT_PREFIX/run/lock/lmm-api-nginx-deploy.lock
readonly BACKUP_ROOT=$ROOT_PREFIX/var/lib/lmm-api-nginx-deploy/backups
readonly MIME_TARGET=$ROOT_PREFIX/etc/nginx/lmm-api-mime.types
readonly MAP_TARGET=$ROOT_PREFIX/etc/nginx/lmm-api-http-map.conf
readonly LOCATIONS_TARGET=$ROOT_PREFIX/etc/nginx/lmm-api-locations.conf
readonly SERVER_TARGET=$ROOT_PREFIX/etc/nginx/conf.d/new-api.conf
readonly RUST_UPSTREAM_TARGET=$ROOT_PREFIX/etc/nginx/conf.d/lmm-api-rs-active-upstream.conf
readonly RUST_PROBES_TARGET=$ROOT_PREFIX/etc/nginx/snippets/lmm-api-rs-probe-locations.conf
INSTALL_OWNER=root
INSTALL_GROUP=root
if [[ ${LMM_NGINX_TEST_MODE:-} == 1 ]]; then
  INSTALL_OWNER=$(id -u)
  INSTALL_GROUP=$(id -g)
fi
readonly INSTALL_OWNER INSTALL_GROUP

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
readonly SCRIPT_DIR
declare -Ar SOURCES=(
  [mime]="$SCRIPT_DIR/mime.types"
  [map]="$SCRIPT_DIR/http-map.conf"
  [locations]="$SCRIPT_DIR/lmm-api-locations.conf"
  [server]="$SCRIPT_DIR/new-api.conf"
  [rust_upstream]="$SCRIPT_DIR/../backend-rust/nginx/lmm-api-rs-upstream.conf"
  [rust_probes]="$SCRIPT_DIR/../backend-rust/nginx/lmm-api-rs-probe-locations.conf"
)
declare -Ar TARGETS=(
  [mime]="$MIME_TARGET"
  [map]="$MAP_TARGET"
  [locations]="$LOCATIONS_TARGET"
  [server]="$SERVER_TARGET"
  [rust_upstream]="$RUST_UPSTREAM_TARGET"
  [rust_probes]="$RUST_PROBES_TARGET"
)
readonly -a KEYS=(mime map locations rust_upstream rust_probes server)

log() { printf '[lmm-api-nginx] %s\n' "$*" >&2; }
die() { log "$*"; exit 1; }

atomic_install() {
  local source=$1 target=$2 mode=${3:-0644} owner=${4:-$INSTALL_OWNER} group=${5:-$INSTALL_GROUP} temp status
  temp=$target.tmp.$$
  install -o "$owner" -g "$group" -m "$mode" -- "$source" "$temp" || return
  mv -Tf -- "$temp" "$target" && return 0
  status=$?
  rm -f -- "$temp"
  return "$status"
}

capture_backup() {
  local backup=$1 key target mode owner group
  : >"$backup/manifest.tmp" || return
  for key in "${KEYS[@]}"; do
    target=${TARGETS[$key]}
    if [[ -e $target || -L $target ]]; then
      [[ -f $target && ! -L $target ]] || { log "unsafe existing target: $target"; return 1; }
      cp -a -- "$target" "$backup/$key" || return
      mode=$(stat -c '%a' "$target") || return
      owner=$(stat -c '%u' "$target") || return
      group=$(stat -c '%g' "$target") || return
      printf '%s present %s %s %s\n' "$key" "$mode" "$owner" "$group" >>"$backup/manifest.tmp" || return
    else
      printf '%s absent - - -\n' "$key" >>"$backup/manifest.tmp" || return
    fi
  done
  mv -Tf -- "$backup/manifest.tmp" "$backup/manifest" || return
}

deploy_candidate() {
  local key
  for key in "${KEYS[@]}"; do
    # The Rust deploy transaction owns an already-active upstream. This nginx
    # installer only supplies the disabled bootstrap file when it is absent.
    if [[ $key == rust_upstream && -e ${TARGETS[$key]} ]]; then
      continue
    fi
    atomic_install "${SOURCES[$key]}" "${TARGETS[$key]}" || return
  done
  nginx -t || return
  systemctl reload nginx || return
  systemctl is-active --quiet nginx || return
}

restore_backup() {
  local backup=$1 key state mode owner group target
  [[ -f $backup/manifest ]] || return 1
  while read -r key state mode owner group; do
    case $key in mime|map|locations|rust_upstream|rust_probes|server) ;; *) return 1 ;; esac
    target=${TARGETS[$key]}
    case $state in
      present)
        [[ -f $backup/$key && $mode =~ ^[0-7]{3,4}$ && $owner =~ ^[0-9]+$ && $group =~ ^[0-9]+$ ]] || return 1
        atomic_install "$backup/$key" "$target" "$mode" "$owner" "$group" || return
        ;;
      absent) rm -f -- "$target" || return ;;
      *) return 1 ;;
    esac
  done <"$backup/manifest"
  nginx -t || return
  systemctl reload nginx || return
  systemctl is-active --quiet nginx || return
}

[[ ${1:-} == install && $# == 1 ]] || die 'usage: install-nginx-split.sh install'
[[ $EUID == 0 || ${LMM_NGINX_TEST_MODE:-} == 1 ]] || die 'must run as root'
for tool in flock install mv cp rm openssl nginx systemctl date mkdir chmod stat; do
  command -v "$tool" >/dev/null || die "missing required command: $tool"
done
for key in "${KEYS[@]}"; do
  [[ -f ${SOURCES[$key]} && ! -L ${SOURCES[$key]} ]] || die "missing or unsafe source: ${SOURCES[$key]}"
done

install -d -o "$(id -u)" -g "$(id -g)" -m 0750 "$BACKUP_ROOT" "$(dirname -- "$LOCK")"
install -d -o "$INSTALL_OWNER" -g "$INSTALL_GROUP" -m 0755 \
  "$ROOT_PREFIX/etc/nginx/conf.d" "$ROOT_PREFIX/etc/nginx/snippets"
exec 9>"$LOCK"
flock -n 9 || die 'another nginx deployment is running'
systemctl is-active --quiet nginx || die 'nginx must be active before deployment'

backup_id=$(date -u +%Y%m%dT%H%M%SZ)-$(date -u +%N)-$(openssl rand -hex 8)
[[ $backup_id =~ ^[0-9]{8}T[0-9]{6}Z-[0-9]{9}-[0-9a-f]{16}$ ]] || die 'failed to generate safe backup id'
backup=$BACKUP_ROOT/$backup_id
mkdir -- "$backup" || die 'failed to reserve unique backup directory'
chmod 0700 "$backup"
capture_backup "$backup" || die "failed to capture backup: $backup_id"

deploy_status=0
deploy_candidate || deploy_status=$?
if (( deploy_status == 0 )); then
  log "deployment healthy; backup=$backup_id"
  exit 0
fi

log "candidate deployment failed with status $deploy_status; restoring $backup_id"
restore_status=0
restore_backup "$backup" || restore_status=$?
if (( restore_status != 0 )); then
  die "candidate failed ($deploy_status) and restore verification failed ($restore_status)"
fi
die "candidate failed ($deploy_status); previous nginx configuration restored and verified"
