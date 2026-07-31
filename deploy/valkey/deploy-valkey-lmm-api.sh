#!/usr/bin/env bash
set -Eeuo pipefail

readonly SERVICE='valkey-lmm-api.service'
readonly EXISTING_SERVICE='valkey.service'
readonly CONFIG='/etc/valkey/lmm-api.conf'
readonly ACL='/etc/valkey/lmm-api.acl'
readonly APP_ENV='/etc/lmm-api/valkey.env'
readonly UNIT='/etc/systemd/system/valkey-lmm-api.service'
readonly SYSCTL_CONFIG='/etc/sysctl.d/70-valkey-lmm-api.conf'
readonly TMPFILES_CONFIG='/etc/tmpfiles.d/valkey-lmm-api.conf'
readonly THP_SYSFS='/sys/kernel/mm/transparent_hugepage/enabled'
readonly STATE_DIR='/var/lib/valkey-lmm-api'
readonly BACKUP_ROOT='/var/lib/valkey-lmm-api-deploy/backups'
readonly LOCK='/run/lock/valkey-lmm-api-deploy.lock'
readonly PORT='6380'

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ACTION="${1:-install}"
BACKUP_ID="${2:-}"
STAGE=''
RESTORE_ON_EXIT=''
PREVIOUS_DEDICATED_ACTIVE=''
PREVIOUS_DEDICATED_ENABLED=''

log() { printf '[valkey-lmm-api] %s\n' "$*" >&2; }
die() { log "ERROR: $*"; exit 1; }
cleanup() {
  local exit_status=$?
  local restore_status=0
  if ((exit_status != 0)) && [[ -n "$RESTORE_ON_EXIT" ]]; then
    set +e
    log "install failed; restoring managed files from $(basename "$RESTORE_ON_EXIT")"
    (restore_transaction "$RESTORE_ON_EXIT")
    restore_status=$?
    if ((restore_status != 0)); then
      log "ROLLBACK ERROR: automatic restoration failed with status $restore_status (original status $exit_status)"
    else
      log "automatic restoration succeeded (original status $exit_status)"
    fi
    set -e
  fi
  [[ -z "$STAGE" ]] || rm -rf -- "$STAGE"
  return "$exit_status"
}
trap cleanup EXIT

require_root() { [[ $EUID -eq 0 ]] || die 'run as root'; }
require_tools() {
  local tool
  for tool in flock install mv cp rm mktemp systemctl systemd-tmpfiles sysctl valkey-server valkey-cli ss openssl sha256sum; do
    command -v "$tool" >/dev/null || die "missing command: $tool"
  done
  getent passwd valkey >/dev/null || die 'system user valkey is missing'
}

capture_existing_instance() {
  EXISTING_ACTIVE="$(systemctl is-active "$EXISTING_SERVICE" 2>/dev/null || true)"
  EXISTING_PID="$(systemctl show "$EXISTING_SERVICE" -p MainPID --value 2>/dev/null || true)"
  ss -ltnH 'sport = :6379' | grep -q . || die 'protected Valkey listener on port 6379 is missing'
}

capture_dedicated_state() {
  PREVIOUS_DEDICATED_ACTIVE="$(systemctl is-active "$SERVICE" 2>/dev/null || true)"
  PREVIOUS_DEDICATED_ENABLED="$(systemctl is-enabled "$SERVICE" 2>/dev/null || true)"
  [[ -n "$PREVIOUS_DEDICATED_ACTIVE" ]] || PREVIOUS_DEDICATED_ACTIVE='inactive'
  [[ -n "$PREVIOUS_DEDICATED_ENABLED" ]] || PREVIOUS_DEDICATED_ENABLED='not-found'
  case "$PREVIOUS_DEDICATED_ACTIVE" in active|inactive) ;; *) die "dedicated unit is not in a deployable active state: $PREVIOUS_DEDICATED_ACTIVE" ;; esac
  case "$PREVIOUS_DEDICATED_ENABLED" in enabled|disabled|not-found) ;; *) die "dedicated unit is not in a deployable enabled state: $PREVIOUS_DEDICATED_ENABLED" ;; esac
}

assert_existing_untouched() {
  local active pid
  active="$(systemctl is-active "$EXISTING_SERVICE" 2>/dev/null || true)"
  pid="$(systemctl show "$EXISTING_SERVICE" -p MainPID --value 2>/dev/null || true)"
  [[ "$active" == "$EXISTING_ACTIVE" && "$pid" == "$EXISTING_PID" ]] ||
    die 'protected valkey.service changed state or PID; manual investigation required'
  ss -ltnH 'sport = :6379' | grep -q . || die 'protected listener on port 6379 disappeared'
}

atomic_install() {
  local source="$1" target="$2" mode="$3" owner="$4" group="$5" temporary
  temporary="${target}.new.$$"
  install -o "$owner" -g "$group" -m "$mode" -- "$source" "$temporary"
  mv -fT -- "$temporary" "$target"
}

backup_managed_files() {
  local backup_dir="$1" path overcommit thp kernel_state_tmp unit_state_tmp manifest_tmp
  [[ -d "$backup_dir" ]] || die "backup directory was not reserved: $backup_dir"
  [[ ! -e "$backup_dir/manifest" ]] || die "backup manifest already exists: $backup_dir"
  if ! overcommit="$(sysctl -n vm.overcommit_memory)"; then
    die 'could not capture vm.overcommit_memory'
  fi
  [[ "$overcommit" =~ ^[012]$ ]] || die "invalid current overcommit state: $overcommit"
  if ! thp="$(current_thp_mode)"; then
    die 'could not capture current THP mode'
  fi
  case "$thp" in always|madvise|never) ;; *) die "invalid current THP state: $thp" ;; esac
  unit_state_tmp="$backup_dir/.unit-state.new.$$"
  printf 'active %s\nenabled %s\n' "$PREVIOUS_DEDICATED_ACTIVE" "$PREVIOUS_DEDICATED_ENABLED" \
    >"$unit_state_tmp"
  chmod 0600 "$unit_state_tmp"
  mv -fT -- "$unit_state_tmp" "$backup_dir/unit-state"
  kernel_state_tmp="$backup_dir/.kernel-state.new.$$"
  printf 'overcommit %s\nthp %s\n' "$overcommit" "$thp" >"$kernel_state_tmp"
  chmod 0600 "$kernel_state_tmp"
  mv -fT -- "$kernel_state_tmp" "$backup_dir/kernel-state"
  manifest_tmp="$backup_dir/.manifest.new.$$"
  : >"$manifest_tmp"
  chmod 0600 "$manifest_tmp"
  for path in "$CONFIG" "$ACL" "$APP_ENV" "$UNIT" "$SYSCTL_CONFIG" "$TMPFILES_CONFIG"; do
    if [[ -e "$path" ]]; then
      cp -a -- "$path" "$backup_dir/$(basename "$path")"
      printf 'present %s\n' "$path" >>"$manifest_tmp"
    else
      printf 'absent %s\n' "$path" >>"$manifest_tmp"
    fi
  done
  mv -fT -- "$manifest_tmp" "$backup_dir/manifest"
}

current_thp_mode() {
  local state
  [[ -r "$THP_SYSFS" ]] || die "THP state is unavailable: $THP_SYSFS"
  state="$(<"$THP_SYSFS")"
  if [[ "$state" =~ \[([a-z]+)\] ]]; then
    printf '%s\n' "${BASH_REMATCH[1]}"
  else
    die 'could not parse current THP mode'
  fi
}

apply_kernel_tuning() {
  sysctl -q -w vm.overcommit_memory=1
  systemd-tmpfiles --create "$TMPFILES_CONFIG"
  [[ "$(sysctl -n vm.overcommit_memory)" == 1 ]] || die 'vm.overcommit_memory did not become 1'
  [[ "$(current_thp_mode)" == madvise ]] || die 'THP mode did not become madvise'
}

restore_kernel_state() {
  local backup_dir="$1" key value overcommit='' thp='' observed step_status
  [[ -r "$backup_dir/kernel-state" ]] || die "kernel state metadata missing: $backup_dir"
  while read -r key value; do
    case "$key" in
      overcommit) overcommit="$value" ;;
      thp) thp="$value" ;;
      *) die 'invalid kernel state metadata' ;;
    esac
  done <"$backup_dir/kernel-state"
  [[ "$overcommit" =~ ^[012]$ ]] || die 'invalid saved overcommit state'
  case "$thp" in always|madvise|never) ;; *) die 'invalid saved THP state' ;; esac
  if sysctl -q -w "vm.overcommit_memory=$overcommit"; then :; else step_status=$?; return "$step_status"; fi
  if printf '%s\n' "$thp" >"$THP_SYSFS"; then :; else step_status=$?; return "$step_status"; fi
  if observed="$(sysctl -n vm.overcommit_memory)"; then :; else step_status=$?; return "$step_status"; fi
  [[ "$observed" == "$overcommit" ]] || { log 'overcommit runtime state was not restored'; return 1; }
  if observed="$(current_thp_mode)"; then :; else step_status=$?; return "$step_status"; fi
  [[ "$observed" == "$thp" ]] || { log 'THP runtime state was not restored'; return 1; }
}

reserve_backup_dir() {
  local candidate random
  install -d -o root -g root -m 0700 -- "$BACKUP_ROOT"
  for _ in {1..10}; do
    random="$(openssl rand -hex 8)"
    candidate="$BACKUP_ROOT/$(date -u +%Y%m%dT%H%M%SZ)-$(date -u +%N)-$random"
    if mkdir -m 0700 -- "$candidate" 2>/dev/null; then
      printf '%s\n' "$candidate"
      return 0
    fi
  done
  die 'could not reserve a unique backup directory'
}

restore_managed_files() {
  local backup_dir="$1" status path stored step_status
  [[ -r "$backup_dir/manifest" ]] || die "backup manifest missing: $backup_dir"
  while read -r status path; do
    case "$path" in "$CONFIG"|"$ACL"|"$APP_ENV"|"$UNIT"|"$SYSCTL_CONFIG"|"$TMPFILES_CONFIG") ;; *) die 'unsafe backup manifest' ;; esac
    stored="$backup_dir/$(basename "$path")"
    if [[ "$status" == present ]]; then
      [[ -e "$stored" ]] || die "backup payload missing for $path"
      if cp -a -- "$stored" "${path}.rollback.$$"; then :; else step_status=$?; return "$step_status"; fi
      if mv -fT -- "${path}.rollback.$$" "$path"; then :; else step_status=$?; return "$step_status"; fi
    elif [[ "$status" == absent ]]; then
      if rm -f -- "$path"; then :; else step_status=$?; return "$step_status"; fi
    else
      die 'invalid backup manifest'
    fi
  done <"$backup_dir/manifest"
}

read_unit_state() {
  local backup_dir="$1" key value
  RESTORE_ACTIVE=''
  RESTORE_ENABLED=''
  [[ -r "$backup_dir/unit-state" ]] || die "unit state metadata missing: $backup_dir"
  while read -r key value; do
    case "$key" in
      active) RESTORE_ACTIVE="$value" ;;
      enabled) RESTORE_ENABLED="$value" ;;
      *) die 'invalid unit state metadata' ;;
    esac
  done <"$backup_dir/unit-state"
  case "$RESTORE_ACTIVE" in active|inactive) ;; *) die 'invalid saved active state' ;; esac
  case "$RESTORE_ENABLED" in enabled|disabled|not-found) ;; *) die 'invalid saved enabled state' ;; esac
}

restore_unit_state() {
  local active_now enabled_now step_status
  case "$RESTORE_ENABLED" in
    enabled)
      if systemctl enable "$SERVICE"; then :; else step_status=$?; return "$step_status"; fi
      ;;
    not-found|disabled) ;;
  esac

  if [[ "$RESTORE_ACTIVE" == active ]]; then
    if systemctl restart "$SERVICE"; then :; else step_status=$?; return "$step_status"; fi
    if health_check; then :; else step_status=$?; return "$step_status"; fi
  fi

  active_now="$(systemctl is-active "$SERVICE" 2>/dev/null || true)"
  enabled_now="$(systemctl is-enabled "$SERVICE" 2>/dev/null || true)"
  [[ "$active_now" == "$RESTORE_ACTIVE" ]] || die "dedicated unit active state was not restored ($active_now != $RESTORE_ACTIVE)"
  [[ "$enabled_now" == "$RESTORE_ENABLED" ]] || die "dedicated unit enabled state was not restored ($enabled_now != $RESTORE_ENABLED)"
}

restore_steps() {
  local backup_dir="$1" step_status current_active
  if read_unit_state "$backup_dir"; then :; else step_status=$?; return "$step_status"; fi
  if systemctl stop "$SERVICE" >/dev/null 2>&1; then
    :
  else
    step_status=$?
    current_active="$(systemctl is-active "$SERVICE" 2>/dev/null || true)"
    case "$current_active" in
      inactive|failed|unknown) ;;
      *) return "$step_status" ;;
    esac
  fi
  case "$RESTORE_ENABLED" in
    disabled|not-found)
      if systemctl disable "$SERVICE" >/dev/null 2>&1; then
        :
      else
        step_status=$?
        current_active="$(systemctl is-enabled "$SERVICE" 2>/dev/null || true)"
        case "$current_active" in
          disabled|not-found) ;;
          *) return "$step_status" ;;
        esac
      fi
      ;;
  esac
  if restore_managed_files "$backup_dir"; then :; else step_status=$?; return "$step_status"; fi
  if restore_kernel_state "$backup_dir"; then :; else step_status=$?; return "$step_status"; fi
  if systemctl daemon-reload; then :; else step_status=$?; return "$step_status"; fi
  if restore_unit_state; then :; else step_status=$?; return "$step_status"; fi
}

restore_transaction() {
  local backup_dir="$1" restore_status=0 invariant_status=0
  (restore_steps "$backup_dir") || restore_status=$?

  (assert_existing_untouched) || invariant_status=$?
  if ((restore_status != 0)); then
    log "restore steps failed with status $restore_status"
  fi
  if ((invariant_status != 0)); then
    log "protected 6379 invariant check failed with status $invariant_status"
  fi
  if ((restore_status != 0)); then
    return "$restore_status"
  fi
  return "$invariant_status"
}

health_check() {
  local password denied_output
  password="$(sed -n 's/^user lmm-api on >\([[:xdigit:]]\{64\}\) .*/\1/p' "$ACL")"
  [[ ${#password} -eq 64 ]] || die 'managed ACL is malformed'
  VALKEYCLI_AUTH="$password" valkey-cli --no-auth-warning -h 127.0.0.1 -p "$PORT" \
    --user lmm-api ping 2>/dev/null | grep -qx PONG || die 'authenticated PING failed'
  denied_output="$(VALKEYCLI_AUTH="$password" valkey-cli --no-auth-warning --raw \
    -h 127.0.0.1 -p "$PORT" --user lmm-api CONFIG GET '*' 2>&1 || true)"
  grep -qiE 'NOPERM|no permissions' <<<"$denied_output" ||
    die 'application user unexpectedly has dangerous CONFIG permission'
  systemctl is-active --quiet "$SERVICE" || die "$SERVICE is not active"
  ss -ltnH 'sport = :6380' | grep -q '127.0.0.1:6380' || die 'loopback listener is missing'
  if ss -ltnH 'sport = :6380' | grep -Eq '(^|[[:space:]])(0\.0\.0\.0|\*|\[::\]):6380'; then
    die 'Valkey is exposed beyond IPv4 loopback'
  fi
}

install_instance() {
  local backup_dir password
  [[ -r "$SCRIPT_DIR/lmm-api.conf" && -r "$SCRIPT_DIR/valkey-lmm-api.service" &&
    -r "$SCRIPT_DIR/70-valkey-lmm-api.conf" && -r "$SCRIPT_DIR/valkey-lmm-api.tmpfiles.conf" ]] ||
    die 'deployment templates are missing'
  [[ "$(grep -Ec '^port 6380$' "$SCRIPT_DIR/lmm-api.conf")" == 1 ]] || die 'template port check failed'
  [[ "$(grep -Ec '^bind 127\.0\.0\.1 -::1$' "$SCRIPT_DIR/lmm-api.conf")" == 1 ]] || die 'template bind check failed'

  backup_dir="$(reserve_backup_dir)"
  backup_managed_files "$backup_dir"
  RESTORE_ON_EXIT="$backup_dir"
  log "backup retained at $backup_dir"

  install -d -o root -g valkey -m 0750 /etc/valkey
  install -d -o root -g root -m 0700 /etc/lmm-api "$BACKUP_ROOT"
  install -d -o valkey -g valkey -m 0750 "$STATE_DIR"

  if [[ -s "$ACL" && -s "$APP_ENV" ]]; then
    cp -a -- "$ACL" "$STAGE/acl"
    cp -a -- "$APP_ENV" "$STAGE/env"
  else
    password="$(openssl rand -hex 32)"
    printf 'user default off\nuser lmm-api on >%s ~* &* +@all -@dangerous\n' "$password" >"$STAGE/acl"
    printf 'REDIS_CONN_STRING=redis://lmm-api:%s@127.0.0.1:6380/0\n' "$password" >"$STAGE/env"
  fi

  atomic_install "$SCRIPT_DIR/lmm-api.conf" "$CONFIG" 0640 root valkey
  atomic_install "$STAGE/acl" "$ACL" 0640 root valkey
  atomic_install "$STAGE/env" "$APP_ENV" 0600 root root
  atomic_install "$SCRIPT_DIR/valkey-lmm-api.service" "$UNIT" 0644 root root
  atomic_install "$SCRIPT_DIR/70-valkey-lmm-api.conf" "$SYSCTL_CONFIG" 0644 root root
  atomic_install "$SCRIPT_DIR/valkey-lmm-api.tmpfiles.conf" "$TMPFILES_CONFIG" 0644 root root
  apply_kernel_tuning
  valkey-server --check-system >/dev/null || die 'valkey-server --check-system failed after kernel tuning'
  systemctl daemon-reload
  systemctl enable "$SERVICE"
  systemctl restart "$SERVICE"
  health_check
  assert_existing_untouched
  sha256sum "$CONFIG" "$UNIT" "$SYSCTL_CONFIG" "$TMPFILES_CONFIG" >"$backup_dir/installed.sha256"
  RESTORE_ON_EXIT=''
  log 'installation healthy; application credential is in /etc/lmm-api/valkey.env (mode 0600)'
}

rollback_instance() {
  local backup_dir
  [[ -n "$BACKUP_ID" && "$BACKUP_ID" =~ ^[0-9]{8}T[0-9]{6}Z-[0-9]{9}-[0-9a-f]{16}$ ]] ||
    die 'usage: deploy-valkey-lmm-api.sh rollback <backup-id>'
  backup_dir="$BACKUP_ROOT/$BACKUP_ID"
  [[ -r "$backup_dir/manifest" ]] || die "backup not found: $BACKUP_ID"
  restore_transaction "$backup_dir"
  log "rollback to $BACKUP_ID completed"
}

main() {
  require_root
  require_tools
  exec 9>"$LOCK"
  flock -n 9 || die 'another Valkey deployment is running'
  STAGE="$(mktemp -d /tmp/valkey-lmm-api.XXXXXX)"
  chmod 0700 "$STAGE"
  capture_existing_instance
  case "$ACTION" in
    install)
      [[ -z "$BACKUP_ID" ]] || die 'install takes no positional argument'
      capture_dedicated_state
      install_instance
      ;;
    health) [[ -z "$BACKUP_ID" ]] || die 'health takes no positional argument'; health_check; assert_existing_untouched ;;
    rollback) rollback_instance ;;
    *) die 'usage: deploy-valkey-lmm-api.sh {install|health|rollback <backup-id>}' ;;
  esac
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
