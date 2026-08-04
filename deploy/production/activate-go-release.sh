#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

readonly SERVICE=lmm-api.service
readonly EXPECTED_HOST=arch-dmit
readonly BACKEND_CONFIG=/etc/lmm-api/backend.conf
readonly ENV_FILE=/etc/lmm-api/lmm-api.env
readonly BINARY=/usr/lib/lmm-api/backends/go/lmm-api
readonly BACKUP_ROOT=/var/lib/lmm-api/deploy-backups
readonly LOCK_FILE=/run/lock/lmm-api-go-deploy.lock

die() { printf 'activate-go-release: %s\n' "$*" >&2; exit 1; }
is_sha256() { [[ $1 =~ ^[0-9a-f]{64}$ ]]; }

PACKAGE=''
PACKAGE_SHA256=''
ROLLBACK_PACKAGE=''
ROLLBACK_SHA256=''
EXPECTED_VERSION=''
STATUS_FILE=''
while (($#)); do
  case $1 in
    --package) (($# >= 2)) || die '--package requires a value'; PACKAGE=$2; shift 2 ;;
    --package-sha256) (($# >= 2)) || die '--package-sha256 requires a value'; PACKAGE_SHA256=$2; shift 2 ;;
    --rollback-package) (($# >= 2)) || die '--rollback-package requires a value'; ROLLBACK_PACKAGE=$2; shift 2 ;;
    --rollback-sha256) (($# >= 2)) || die '--rollback-sha256 requires a value'; ROLLBACK_SHA256=$2; shift 2 ;;
    --expected-version) (($# >= 2)) || die '--expected-version requires a value'; EXPECTED_VERSION=$2; shift 2 ;;
    --status-file) (($# >= 2)) || die '--status-file requires a value'; STATUS_FILE=$2; shift 2 ;;
    *) die "unknown argument: $1" ;;
  esac
done

[[ $EUID -eq 0 ]] || die 'must run as root'
[[ $(hostnamectl --static) == "$EXPECTED_HOST" ]] || die 'refusing to run on an unexpected host'
[[ $EXPECTED_VERSION =~ ^[0-9][0-9A-Za-z._+]*$ ]] || die 'invalid expected version'
[[ $STATUS_FILE == /var/lib/lmm-api/deploy-staging/* && ! -L $STATUS_FILE ]] || die 'unsafe status path'
for path in "$PACKAGE" "$ROLLBACK_PACKAGE"; do
  [[ $path == /var/lib/lmm-api/deploy-staging/* && -f $path && ! -L $path ]] || die "unsafe package path: $path"
done
is_sha256 "$PACKAGE_SHA256" || die 'invalid package checksum'
is_sha256 "$ROLLBACK_SHA256" || die 'invalid rollback checksum'
[[ $(sha256sum "$PACKAGE" | awk '{print $1}') == "$PACKAGE_SHA256" ]] || die 'package checksum mismatch'
[[ $(sha256sum "$ROLLBACK_PACKAGE" | awk '{print $1}') == "$ROLLBACK_SHA256" ]] || die 'rollback checksum mismatch'
for command in curl flock jq pacman pg_dump pg_restore sha256sum systemctl; do
  command -v "$command" >/dev/null 2>&1 || die "required command is unavailable: $command"
done

write_status() {
  local value=$1 temporary="$STATUS_FILE.$$.new"
  printf '%s\n' "$value" >"$temporary"
  chmod 0600 "$temporary"
  mv -Tf -- "$temporary" "$STATUS_FILE"
}

restart_service() {
  local state
  systemctl stop --no-block "$SERVICE"
  for _ in {1..15}; do
    state=$(systemctl show "$SERVICE" --property=ActiveState --value)
    [[ $state == inactive || $state == failed ]] && break
    sleep 1
  done
  if [[ $state != inactive && $state != failed ]]; then
    systemctl kill --kill-who=main --signal=SIGKILL "$SERVICE"
  fi
  for _ in {1..10}; do
    state=$(systemctl show "$SERVICE" --property=ActiveState --value)
    [[ $state == inactive || $state == failed ]] && break
    sleep 1
  done
  [[ $state == inactive || $state == failed ]] || return 1
  systemctl reset-failed "$SERVICE" 2>/dev/null || true
  systemctl start "$SERVICE"
}

probe_version() {
  local expected=$1 response
  for _ in {1..40}; do
    response=$(curl --fail --silent --show-error --max-time 3 http://127.0.0.1:3000/api/status 2>/dev/null || true)
    if jq -e --arg version "$expected" \
      '.success == true and .ready == true and .data.version == $version' \
      <<<"$response" >/dev/null 2>&1; then
      return 0
    fi
    sleep 1
  done
  return 1
}

install -d -m0700 "${LOCK_FILE%/*}" "$BACKUP_ROOT"
exec 9>"$LOCK_FILE"
flock -n 9 || die 'another Go deployment is running'
write_status PREPARING

new_record=$(pacman -Qp --print-format '%n %v' "$PACKAGE")
rollback_record=$(pacman -Qp --print-format '%n %v' "$ROLLBACK_PACKAGE")
[[ $new_record == "lmm-api-go $EXPECTED_VERSION-1" ]] || die "unexpected release package: $new_record"
[[ $rollback_record == lmm-api-go\ * ]] || die "unexpected rollback package: $rollback_record"
old_version=${rollback_record#lmm-api-go }
old_version=${old_version%-1}
[[ $(pacman -Q lmm-api-go) == "lmm-api-go $old_version-1" ]] || die 'rollback package does not match the installed version'
grep -Fqx 'LMM_API_BACKEND=go' "$BACKEND_CONFIG" || die 'production backend is not explicitly Go'
systemctl is-active --quiet "$SERVICE" || die 'service is not active before deployment'
[[ $($BINARY --version) == "$old_version" ]] || die 'installed binary version does not match package metadata'

snapshot="$BACKUP_ROOT/$(date -u +%Y%m%dT%H%M%SZ)-$EXPECTED_VERSION"
install -d -m0700 "$snapshot"
cp -a -- "$BINARY" "$BACKEND_CONFIG" "$ENV_FILE" "$snapshot/"
pacman -Qi lmm-api lmm-api-go >"$snapshot/package-info.txt"
sha256sum "$snapshot/lmm-api" "$snapshot/backend.conf" "$snapshot/lmm-api.env" >"$snapshot/files.sha256"

set -a
# shellcheck disable=SC1090
source "$ENV_FILE"
set +a
[[ -n ${SQL_DSN:-} ]] || die 'SQL_DSN is unavailable'
pg_dump --format=custom --file="$snapshot/postgresql.dump.new" "$SQL_DSN"
pg_restore --list "$snapshot/postgresql.dump.new" >/dev/null
mv -T "$snapshot/postgresql.dump.new" "$snapshot/postgresql.dump"
chmod 0600 "$snapshot/postgresql.dump"
printf 'expected_version=%s\nold_version=%s\ncreated_at=%s\n' \
  "$EXPECTED_VERSION" "$old_version" "$(date -u +%FT%TZ)" >"$snapshot/release.env"
write_status "BACKUP_READY $snapshot"

rollback() {
  local reason=$1
  write_status "ROLLBACK_STARTED $reason"
  pacman -U --noconfirm "$ROLLBACK_PACKAGE"
  restart_service
  if probe_version "$old_version"; then
    write_status "ROLLED_BACK $old_version $reason"
  else
    write_status "ROLLBACK_FAILED $reason"
  fi
  exit 1
}

if ! pacman -U --noconfirm "$PACKAGE"; then
  rollback package-install-failed
fi
if ! pacman -Qkk lmm-api-go >/dev/null; then
  rollback package-integrity-failed
fi
if [[ $($BINARY --version) != "$EXPECTED_VERSION" ]]; then
  rollback binary-version-failed
fi
write_status "PACKAGE_INSTALLED $EXPECTED_VERSION"

if ! restart_service; then
  rollback service-restart-failed
fi
if ! probe_version "$EXPECTED_VERSION"; then
  rollback health-or-version-probe-failed
fi
write_status "DEPLOYED $EXPECTED_VERSION $snapshot"
