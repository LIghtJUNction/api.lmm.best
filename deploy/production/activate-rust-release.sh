#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

EXPECTED_HOST=arch-dmit
SERVICE=lmm-api.service
BACKEND_CONFIG=/etc/lmm-api/backend.conf
ENV_CONFIG=/etc/lmm-api/lmm-api.env
FRONTEND_ROOT=/srv/lmm-api-frontend
FRONTEND_SOURCE=/usr/share/lmm-api/frontend-dist
BACKEND_ROOT=/usr/lib/lmm-api/backends
STAGING_ROOT=/var/lib/lmm-api/deploy-work
BACKUP_ROOT=/var/lib/lmm-api/deploy-backups
TRANSACTION_LOCK=/var/lib/lmm-api/deploy-transaction.lock
SYSTEMD_UNIT_DIR=/etc/systemd/system
PACMAN_CACHE=/var/cache/pacman/pkg
HEALTH_URL=http://127.0.0.1:3000/api/status
ACCEPTANCE_RUNNER=/usr/lib/lmm-api/deploy/production-acceptance.mjs
ACCEPTANCE_LIB=/usr/lib/lmm-api/deploy/production-acceptance-lib.mjs
DEPLOY_LIBDIR=/usr/lib/lmm-api/deploy
if (( ${LMM_DEPLOY_TEST_MODE:-0} == 1 )); then
  BACKEND_CONFIG=${LMM_DEPLOY_TEST_BACKEND_CONFIG:-$BACKEND_CONFIG}
  ENV_CONFIG=${LMM_DEPLOY_TEST_ENV_CONFIG:-$ENV_CONFIG}
  FRONTEND_ROOT=${LMM_DEPLOY_TEST_FRONTEND_ROOT:-$FRONTEND_ROOT}
  FRONTEND_SOURCE=${LMM_DEPLOY_TEST_FRONTEND_SOURCE:-$FRONTEND_SOURCE}
  BACKEND_ROOT=${LMM_DEPLOY_TEST_BACKEND_ROOT:-$BACKEND_ROOT}
  STAGING_ROOT=${LMM_DEPLOY_TEST_STAGING_ROOT:-$STAGING_ROOT}
  BACKUP_ROOT=${LMM_DEPLOY_TEST_BACKUP_ROOT:-$BACKUP_ROOT}
  TRANSACTION_LOCK=${LMM_DEPLOY_TEST_TRANSACTION_LOCK:-$TRANSACTION_LOCK}
  SYSTEMD_UNIT_DIR=${LMM_DEPLOY_TEST_SYSTEMD_UNIT_DIR:-$SYSTEMD_UNIT_DIR}
  PACMAN_CACHE=${LMM_DEPLOY_TEST_PACMAN_CACHE:-$PACMAN_CACHE}
  HEALTH_URL=${LMM_DEPLOY_TEST_HEALTH_URL:-$HEALTH_URL}
  ACCEPTANCE_RUNNER=${LMM_DEPLOY_TEST_ACCEPTANCE_RUNNER:-$ACCEPTANCE_RUNNER}
  ACCEPTANCE_LIB=${LMM_DEPLOY_TEST_ACCEPTANCE_LIB:-$ACCEPTANCE_LIB}
  DEPLOY_LIBDIR=${LMM_DEPLOY_TEST_DEPLOY_LIBDIR:-$DEPLOY_LIBDIR}
fi
readonly EXPECTED_HOST SERVICE BACKEND_CONFIG ENV_CONFIG FRONTEND_ROOT FRONTEND_SOURCE BACKEND_ROOT
readonly STAGING_ROOT BACKUP_ROOT TRANSACTION_LOCK SYSTEMD_UNIT_DIR PACMAN_CACHE HEALTH_URL
readonly ACCEPTANCE_RUNNER ACCEPTANCE_LIB DEPLOY_LIBDIR

die() { printf 'activate-rust-release: %s\n' "$*" >&2; exit 1; }
is_sha256() { [[ ${1:-} =~ ^[0-9a-f]{64}$ ]]; }
safe_identity() { [[ ${1:-} =~ ^[A-Za-z0-9][A-Za-z0-9._+-]{0,127}$ ]]; }

CORE_PACKAGE=''
CORE_SHA256=''
BACKEND_PACKAGE=''
BACKEND_SHA256=''
ROLLBACK_CORE=''
ROLLBACK_BACKEND=''
FRONTEND_RELEASE_SCRIPT=''
EXPECTED_RELEASE=''
EXPECTED_REVISION=''
ROUTE_GATE=''
ROUTE_GATE_SHA256=''
STATUS_FILE=''
WORKSPACE=''
TARGET_BACKUP=''
GUARD=''
PREPARE_ONLY=0
ROLLBACK_ONLY=0
CONFIRM_ONLY=0
while (($#)); do
  case $1 in
    --core-package) CORE_PACKAGE=${2:?}; shift 2 ;;
    --core-sha256) CORE_SHA256=${2:?}; shift 2 ;;
    --backend-package) BACKEND_PACKAGE=${2:?}; shift 2 ;;
    --backend-sha256) BACKEND_SHA256=${2:?}; shift 2 ;;
    --rollback-core) ROLLBACK_CORE=${2:?}; shift 2 ;;
    --rollback-backend) ROLLBACK_BACKEND=${2:?}; shift 2 ;;
    --frontend-release-script) FRONTEND_RELEASE_SCRIPT=${2:?}; shift 2 ;;
    --expected-release) EXPECTED_RELEASE=${2:?}; shift 2 ;;
    --expected-revision) EXPECTED_REVISION=${2:?}; shift 2 ;;
    --route-gate) ROUTE_GATE=${2:?}; shift 2 ;;
    --route-gate-sha256) ROUTE_GATE_SHA256=${2:?}; shift 2 ;;
    --status-file) STATUS_FILE=${2:?}; shift 2 ;;
    --workspace) WORKSPACE=${2:?}; shift 2 ;;
    --target-backup) TARGET_BACKUP=${2:?}; shift 2 ;;
    --guard) GUARD=${2:?}; shift 2 ;;
    --prepare-only) PREPARE_ONLY=1; shift ;;
    --rollback-only) ROLLBACK_ONLY=1; shift ;;
    --confirm-only) CONFIRM_ONLY=1; shift ;;
    *) die "unknown argument: $1" ;;
  esac
done
((PREPARE_ONLY + ROLLBACK_ONLY + CONFIRM_ONLY <= 1)) || die 'prepare, rollback, and confirm modes are mutually exclusive'

required_commands=(awk bsdtar chmod curl diff find grep install jq mkdir mktemp mv pacman readlink realpath sed sha256sum stat systemctl tar)
((ROLLBACK_ONLY == 1 || CONFIRM_ONLY == 1)) || required_commands+=(node)
required_commands+=(flock)
((CONFIRM_ONLY == 0)) || required_commands+=(sleep sync)
for command in "${required_commands[@]}"; do
  command -v "$command" >/dev/null 2>&1 || die "required target command is unavailable: $command"
done
[[ $EUID -eq 0 || ${LMM_DEPLOY_TEST_MODE:-0} == 1 ]] || die 'must run as root'
observed_host=${LMM_DEPLOY_OBSERVED_HOST:-$(hostnamectl --static)}
[[ $observed_host == "$EXPECTED_HOST" ]] || die 'production host identity mismatch'
[[ $WORKSPACE == "$STAGING_ROOT"/* && -d $WORKSPACE && ! -L $WORKSPACE ]] || die 'unsafe target workspace'
[[ -f $WORKSPACE/.lmm-deploy-workspace && ! -L $WORKSPACE/.lmm-deploy-workspace ]] || die 'target workspace marker is missing'
grep -Fqx 'role=target' "$WORKSPACE/.lmm-deploy-workspace" || die 'target workspace role marker mismatch'
deployment_id=${WORKSPACE##*/}
grep -Fqx "deployment_id=$deployment_id" "$WORKSPACE/.lmm-deploy-workspace" || die 'target workspace deployment mismatch'
[[ $TARGET_BACKUP == "$BACKUP_ROOT/$deployment_id" && -d $TARGET_BACKUP && ! -L $TARGET_BACKUP ]] || \
  die 'verified target backup directory is required'
grep -Fqx 'copy_role=target' "$TARGET_BACKUP/manifest.env" || die 'target backup role mismatch'
grep -Fqx 'database_engine=postgres' "$TARGET_BACKUP/manifest.env" || die 'target backup database mismatch'
(cd "$TARGET_BACKUP" && sha256sum -c SHA256SUMS >/dev/null) || die 'target backup checksum verification failed'
[[ $STATUS_FILE == "$WORKSPACE/staging/status" && ! -L $STATUS_FILE ]] || die 'unsafe status path'
[[ $GUARD == "$WORKSPACE/state/rollback.guard" && ! -L $GUARD ]] || die 'unsafe rollback guard path'
if ((ROLLBACK_ONLY == 0 && CONFIRM_ONLY == 0)); then
  [[ -x $ACCEPTANCE_RUNNER && ! -L $ACCEPTANCE_RUNNER && -f $ACCEPTANCE_LIB && ! -L $ACCEPTANCE_LIB ]] || \
    die 'installed production acceptance runner/library is missing or unsafe'
  [[ $(stat -c '%a' "$ACCEPTANCE_RUNNER") == 755 && $(stat -c '%a' "$ACCEPTANCE_LIB") == 644 ]] || \
    die 'installed production acceptance runner/library mode is unsafe'
  if (( ${LMM_DEPLOY_TEST_MODE:-0} == 0 )); then
    [[ $(stat -c '%U:%G' "$ACCEPTANCE_RUNNER") == root:root && \
      $(stat -c '%U:%G' "$ACCEPTANCE_LIB") == root:root ]] || \
      die 'installed production acceptance runner/library ownership is unsafe'
  fi
  (( (${LMM_ACCEPTANCE_CREDENTIAL_FILE:+1}0) + (${LMM_ACCEPTANCE_CREDENTIAL_FD:+1}0) == 10 )) || \
    die 'set exactly one LMM acceptance credential file or descriptor'
fi

lock_marker="$TRANSACTION_LOCK/deployment.env"
acquire_transaction_lock() {
  if mkdir -m0700 -- "$TRANSACTION_LOCK" 2>/dev/null; then
    printf 'format=1\ndeployment_id=%s\nstatus=ACTIVE\n' "$deployment_id" >"$lock_marker"
    chmod 0600 "$lock_marker"
  else
    [[ -d $TRANSACTION_LOCK && ! -L $TRANSACTION_LOCK && -f $lock_marker && ! -L $lock_marker ]] || \
      die 'target deployment lock is unsafe or incomplete'
    grep -Fqx "deployment_id=$deployment_id" "$lock_marker" || die 'another deployment transaction is active'
    grep -Fqx 'status=ACTIVE' "$lock_marker" || die 'target deployment lock is not active'
  fi
}
validate_transaction_lock() {
  [[ -d $TRANSACTION_LOCK && ! -L $TRANSACTION_LOCK && -f $lock_marker && ! -L $lock_marker ]] || \
    die 'target deployment lock is missing or unsafe'
  grep -Fqx "deployment_id=$deployment_id" "$lock_marker" || die 'target deployment lock belongs to another transaction'
  grep -Fqx 'status=ACTIVE' "$lock_marker" || die 'target deployment lock is not active'
}
release_transaction_lock() {
  validate_transaction_lock
  rm -f -- "$lock_marker"
  rmdir -- "$TRANSACTION_LOCK"
}

package_record() { LC_ALL=C pacman -Qp "$1"; }
package_archive_arch() {
  LC_ALL=C pacman -Qip "$1" | awk -F ': ' '$1 ~ /^Architecture[[:space:]]*$/ { print $2; exit }'
}
installed_arch() {
  LC_ALL=C pacman -Qi "$1" | awk -F ': ' '$1 ~ /^Architecture[[:space:]]*$/ { print $2; exit }'
}
embedded_revision() { bsdtar -xOf "$1" "usr/share/doc/$2/REVISION"; }
guard_value() { sed -n "s/^$1=//p" "$GUARD"; }

write_status() {
  local value=$1 temporary="$STATUS_FILE.$$.tmp"
  printf '%s\n' "$value" >"$temporary"
  chmod 0600 "$temporary"
  mv -Tf -- "$temporary" "$STATUS_FILE"
}
replace_guard_field() {
  local field=$1 expected=$2 replacement=$3 temporary="$GUARD.$$.tmp"
  awk -F= -v field="$field" -v expected="$expected" -v replacement="$replacement" '
    $1 == field {
      if ($0 != field "=" expected || found) exit 2
      print field "=" replacement
      found=1
      next
    }
    { print }
    END { if (!found) exit 2 }
  ' "$GUARD" >"$temporary" || { rm -f -- "$temporary"; die "rollback guard $field transition refused"; }
  chmod 0600 "$temporary"
  (( ${LMM_DEPLOY_TEST_MODE:-0} == 1 )) || chown root:root "$temporary"
  mv -Tf -- "$temporary" "$GUARD"
}

TERMINAL_MUTEX_FD=''
acquire_terminal_mutex() {
  local mutex
  mutex=$(guard_value terminal_mutex)
  [[ $mutex == "$WORKSPACE/state/terminal.mutex" && -f $mutex && ! -L $mutex ]] || \
    die 'deployment terminal mutex is missing or unsafe'
  [[ $(stat -c '%a' "$mutex") == 600 ]] || die 'deployment terminal mutex mode is unsafe'
  if (( ${LMM_DEPLOY_TEST_MODE:-0} == 0 )); then
    [[ $(stat -c '%U:%G' "$mutex") == root:root ]] || die 'deployment terminal mutex ownership is unsafe'
  fi
  exec {TERMINAL_MUTEX_FD}<>"$mutex"
  if (( ${LMM_DEPLOY_TEST_MODE:-0} == 1 )) && [[ -n ${LMM_DEPLOY_TEST_MUTEX_WAITING_FILE:-} ]]; then
    : >"$LMM_DEPLOY_TEST_MUTEX_WAITING_FILE"
  fi
  flock -x "$TERMINAL_MUTEX_FD"
  [[ $(guard_value terminal_mutex) == "$mutex" && -f $mutex && ! -L $mutex ]] || \
    die 'deployment terminal mutex changed while acquiring it'
}
release_terminal_mutex() {
  [[ $TERMINAL_MUTEX_FD =~ ^[0-9]+$ ]] || return 0
  flock -u "$TERMINAL_MUTEX_FD"
  exec {TERMINAL_MUTEX_FD}>&-
  TERMINAL_MUTEX_FD=''
}

frontend_manifest_digest() {
  local root=$1 index
  index=$root/index.html
  if [[ -n ${LMM_DEPLOY_TEST_FRONTEND_DIGEST:-} ]]; then
    printf '%s\n' "$LMM_DEPLOY_TEST_FRONTEND_DIGEST"
    return
  fi
  [[ -f $index && ! -L $index ]] || die 'new frontend index is missing or unsafe'
  node --input-type=module - "$root" "$ACCEPTANCE_LIB" <<'NODE'
import { createHash } from 'node:crypto'
import { lstat, readFile } from 'node:fs/promises'
import { pathToFileURL } from 'node:url'
import path from 'node:path'
const [root, library] = process.argv.slice(2)
const { frontendManifestDigest } = await import(pathToFileURL(library).href)
const index = path.join(root, 'index.html')
const indexBytes = await readFile(index)
const text = indexBytes.toString('utf8')
const assets = []
const seen = new Set()
for (const match of text.matchAll(/(?:src|href)=["']([^"']+)["']/gi)) {
  const raw = match[1]
  if (!raw || raw.startsWith('data:') || raw.startsWith('#')) continue
  const url = new URL(raw, 'https://api.lmm.best')
  if (url.origin !== 'https://api.lmm.best' || url.pathname === '/') throw new Error('invalid frontend asset')
  const assetPath = `${url.pathname}${url.search}`
  if (seen.has(assetPath) || assets.length >= 128) throw new Error('invalid frontend asset set')
  seen.add(assetPath)
  const file = path.resolve(root, decodeURIComponent(url.pathname).replace(/^\/+/, ''))
  if (file !== root && !file.startsWith(`${root}${path.sep}`)) throw new Error('frontend asset escapes release')
  const stat = await lstat(file)
  if (!stat.isFile()) throw new Error('frontend asset is not a regular file')
  assets.push({ path: assetPath, bytes: await readFile(file) })
}
if (assets.length === 0) throw new Error('frontend has no assets')
process.stdout.write(`${frontendManifestDigest([{ path: '/', bytes: indexBytes }, ...assets])}\n`)
NODE
}

acceptance_bindings() {
  local guard_file=$1
  jq -cn --arg deployment_id "$deployment_id" --arg backend_revision "$(sed -n 's/^git_revision=//p' "$guard_file")" \
    --arg frontend_release "$(sed -n 's/^new_frontend=releases\///p' "$guard_file")" \
    --arg frontend_digest "$(sed -n 's/^frontend_digest=//p' "$guard_file")" \
    --argjson deadline_epoch "$(sed -n 's/^acceptance_deadline_epoch=//p' "$guard_file")" \
    --argjson watchdog_deadline_epoch "$(sed -n 's/^acceptance_watchdog_deadline_epoch=//p' "$guard_file")" \
    '{deployment_id:$deployment_id,backend_revision:$backend_revision,frontend_release:$frontend_release,frontend_digest:$frontend_digest,deadline_epoch:$deadline_epoch,watchdog_deadline_epoch:$watchdog_deadline_epoch}'
}

validate_acceptance_evidence() {
  local mode=$1 evidence=$2 baseline=${3:-} bindings
  [[ -f $evidence && ! -L $evidence && $(stat -c '%s' "$evidence") -le 65536 ]] || die 'acceptance evidence is missing, symlinked, or oversized'
  [[ $(stat -c '%a' "$evidence") == 600 ]] || die 'acceptance evidence mode is unsafe'
  if (( ${LMM_DEPLOY_TEST_MODE:-0} == 0 )); then
    [[ $(stat -c '%U:%G' "$evidence") == root:root ]] || die 'acceptance evidence ownership is unsafe'
  fi
  bindings=$(acceptance_bindings "$GUARD")
  if [[ $mode == baseline ]]; then
    jq -e --argjson bindings "$bindings" '
      .schema_version == 2 and .mode == "baseline" and .target == "https://api.lmm.best" and .success == true and
      .bindings == $bindings and (.channels|length) == 0 and (.failures|length) == 0 and (.enabled_channels|length) > 0 and
      .checks == {enabled_channel_count:(.enabled_channels|length),root_logout_refresh:true,root_role:true} and
      .cleanup.attempts == {root_logout:true,test_user_logout:false,token_delete:false,user_delete:false} and
      .cleanup.token_deleted == false and .cleanup.user_deleted == false and .cleanup.retained_test_identity == null and .cleanup.retained_token == null
    ' "$evidence" >/dev/null || die 'acceptance baseline evidence failed schema/binding validation'
  else
    jq -e --argjson bindings "$bindings" --slurpfile baseline "$baseline" '
      .schema_version == 2 and .mode == "verify" and .target == "https://api.lmm.best" and .success == true and
      .bindings == $bindings and (.failures|length) == 0 and
      ([.channels[] | select(.enabled == true)]|length) == ($baseline[0].enabled_channels|length) and
      ([.channels[] | select(.enabled == true and .passed == true)]|length) == ($baseline[0].enabled_channels|length) and
      .checks.enabled_channels_tested == ($baseline[0].enabled_channels|length) and
      .checks.enabled_channels_passed == ($baseline[0].enabled_channels|length) and
      .cleanup.attempts == {root_logout:true,test_user_logout:true,token_delete:true,user_delete:true} and
      .cleanup.token_deleted == true and .cleanup.user_deleted == true and .cleanup.retained_test_identity == null and .cleanup.retained_token == null
    ' "$evidence" >/dev/null || die 'acceptance verification evidence failed schema/binding/channel validation'
  fi
}

run_acceptance() {
  local mode=$1 evidence=$2 baseline=${3:-} deadline watchdog output rc
  local -a args
  deadline=$(sed -n 's/^acceptance_deadline_epoch=//p' "$GUARD")
  watchdog=$(sed -n 's/^acceptance_watchdog_deadline_epoch=//p' "$GUARD")
  output="$evidence.tmp"
  args=("$mode" --deployment-id "$deployment_id" \
    --backend-revision "$(sed -n 's/^git_revision=//p' "$GUARD")" \
    --frontend-release "$(sed -n 's/^new_frontend=releases\///p' "$GUARD")" \
    --frontend-digest "$(sed -n 's/^frontend_digest=//p' "$GUARD")" \
    --deadline-epoch "$deadline" --watchdog-deadline-epoch "$watchdog")
  [[ -z $baseline ]] || args+=(--baseline-file "$baseline")
  set +e
  "$ACCEPTANCE_RUNNER" "${args[@]}" >"$output" 2>/dev/null
  rc=$?
  set -e
  [[ -f $output && $(stat -c '%s' "$output") -le 65536 ]] || die 'acceptance output exceeded 64 KiB'
  chmod 0600 "$output"
  mv -Tf -- "$output" "$evidence"
  ((rc == 0)) || die "production acceptance $mode failed"
}

prepare_acceptance_baseline() {
  local baseline="$WORKSPACE/state/acceptance-baseline.json"
  if [[ -f $baseline && ! -L $baseline ]]; then
    validate_acceptance_evidence baseline "$baseline"
    return
  fi
  run_acceptance baseline "$baseline"
  validate_acceptance_evidence baseline "$baseline"
}

validate_new_artifacts() {
  local core_record backend_record core_arch backend_arch core_revision backend_revision
  is_sha256 "$CORE_SHA256" || die 'invalid core checksum'
  is_sha256 "$BACKEND_SHA256" || die 'invalid backend checksum'
  [[ $(sha256sum "$CORE_PACKAGE" | awk '{print $1}') == "$CORE_SHA256" ]] || die 'core checksum mismatch'
  [[ $(sha256sum "$BACKEND_PACKAGE" | awk '{print $1}') == "$BACKEND_SHA256" ]] || die 'backend checksum mismatch'
  core_record=$(package_record "$CORE_PACKAGE") || die 'core package query failed'
  backend_record=$(package_record "$BACKEND_PACKAGE") || die 'Rust package query failed'
  [[ $core_record == lmm-api-bin\ * ]] || die 'unexpected core package identity'
  [[ $backend_record == lmm-api-rs-bin\ * ]] || die 'unexpected Rust package identity'
  core_arch=$(package_archive_arch "$CORE_PACKAGE")
  backend_arch=$(package_archive_arch "$BACKEND_PACKAGE")
  [[ $core_arch == any && $backend_arch == x86_64 ]] || die 'new package architecture mismatch'
  core_revision=$(embedded_revision "$CORE_PACKAGE" lmm-api-bin)
  backend_revision=$(embedded_revision "$BACKEND_PACKAGE" lmm-api-rs-bin)
  [[ $core_revision == "$EXPECTED_REVISION" && $backend_revision == "$EXPECTED_REVISION" ]] || \
    die 'new package embedded revision mismatch'
  if [[ -f $GUARD ]]; then
    [[ $core_record == "$(guard_value new_core_package)" && $backend_record == "$(guard_value new_backend_package)" ]] || \
      die 'new package records disagree with rollback guard'
    [[ $core_arch == "$(guard_value new_core_arch)" && $backend_arch == "$(guard_value new_backend_arch)" ]] || \
      die 'new package architectures disagree with rollback guard'
    [[ $CORE_SHA256 == "$(guard_value core_sha256)" && $BACKEND_SHA256 == "$(guard_value backend_sha256)" ]] || \
      die 'new package checksums disagree with rollback guard'
    [[ $EXPECTED_REVISION == "$(guard_value git_revision)" ]] || die 'expected revision disagrees with rollback guard'
  fi
  for fact in "git_revision=$EXPECTED_REVISION" "core_sha256=$CORE_SHA256" "backend_sha256=$BACKEND_SHA256"; do
    grep -Fqx "$fact" "$TARGET_BACKUP/manifest.env" || die "target backup identity mismatch: $fact"
  done
}

prepare_route_validator() {
  local libdir=$1 manifest="$1/route-gate-assets.sha256" manifest_sha=$2 label=$3
  local authentication_dir authenticated_manifest expected_validator_sha authenticated_validator
  [[ -f $manifest && ! -L $manifest ]] || die 'route-gate asset manifest is missing or unsafe'
  awk '
    NF != 2 || $1 !~ /^[0-9a-f]{64}$/ { failed=1; next }
    $2 !~ /^(migration-gate.tsv|validate-route-gate|migration-compatibility.env|frozen-route-auth.tsv)$/ { failed=1 }
    { if (seen[$2]++) failed=1 }
    END { if (NR != 4 || length(seen) != 4) failed=1; exit failed }
  ' "$manifest" || die 'route-gate asset manifest is invalid'
  is_sha256 "$manifest_sha" || die 'route-gate asset manifest checksum is invalid'
  authentication_dir=$(mktemp -d "$WORKSPACE/staging/route-validator-$label.XXXXXXXX")
  authenticated_manifest="$authentication_dir/route-gate-assets.sha256"
  cp --no-dereference --preserve=mode,ownership -- "$manifest" "$authenticated_manifest" || \
    die 'route-gate asset manifest authentication copy failed'
  [[ -f $authenticated_manifest && ! -L $authenticated_manifest && \
    $(sha256sum "$authenticated_manifest" | awk '{print $1}') == "$manifest_sha" ]] || \
    die 'route-gate asset manifest changed after authentication'
  expected_validator_sha=$(awk '$2 == "validate-route-gate" { print $1 }' "$authenticated_manifest")
  is_sha256 "$expected_validator_sha" || die 'route-gate validator checksum is invalid'
  authenticated_validator="$authentication_dir/validate-route-gate"
  cp --no-dereference --preserve=mode,ownership -- "$libdir/validate-route-gate" "$authenticated_validator" || \
    die 'route-gate validator authentication copy failed'
  [[ -f $authenticated_validator && ! -L $authenticated_validator && \
    $(sha256sum "$authenticated_validator" | awk '{print $1}') == "$expected_validator_sha" ]] || \
    die 'route-gate validator changed after authentication'
  chmod 0500 "$authenticated_validator"
  ROUTE_AUTH_MANIFEST=$authenticated_manifest
  ROUTE_AUTH_VALIDATOR=$authenticated_validator
}

run_route_validator() {
  local libdir=$1 gate_path=$2 label=$3 manifest_sha=$4 snapshot
  prepare_route_validator "$libdir" "$manifest_sha" "$label"
  snapshot=$(mktemp -d "$WORKSPACE/staging/route-validation-$label.XXXXXXXX")
  LMM_ROUTE_GATE_TEST_MODE=${LMM_DEPLOY_TEST_MODE:-0} \
    "$ROUTE_AUTH_VALIDATOR" --mode activate --snapshot-dir "$snapshot" \
    --assets-manifest "$ROUTE_AUTH_MANIFEST" --assets-manifest-sha256 "$manifest_sha" \
    --gate "$gate_path" --frozen-contract "$libdir/frozen-route-auth.tsv" \
    --evidence-root "$libdir" \
    --revision "$EXPECTED_REVISION" --migration-compatibility "$libdir/migration-compatibility.env" || {
      rm -rf -- "$snapshot" "$(dirname -- "$ROUTE_AUTH_VALIDATOR")"
      die "$label route-gate validation failed"
    }
  rm -rf -- "$snapshot" "$(dirname -- "$ROUTE_AUTH_VALIDATOR")"
}

prepare_extracted_route_payload() {
  local extracted="$WORKSPACE/staging/core-package-root" marker="$WORKSPACE/staging/core-package-root.marker"
  local temporary revision_file package_manifest_sha
  if [[ -e $extracted || -L $extracted || -e $marker || -L $marker ]]; then
    [[ -d $extracted && ! -L $extracted && -f $marker && ! -L $marker ]] || \
      die 'extracted core route payload is incomplete or unsafe'
    grep -Fqx "core_sha256=$CORE_SHA256" "$marker" || die 'extracted core route payload checksum marker mismatch'
  else
    temporary=$(mktemp -d "$WORKSPACE/staging/core-package-root.XXXXXXXX")
    bsdtar -xf "$CORE_PACKAGE" -C "$temporary" \
      usr/lib/lmm-api/deploy usr/share/doc/lmm-api-bin/REVISION || {
        rm -rf -- "$temporary"
        die 'core route payload extraction failed'
      }
    printf 'format=1\ncore_sha256=%s\n' "$CORE_SHA256" >"$marker.new"
    chmod 0600 "$marker.new"
    mv -T -- "$temporary" "$extracted"
    mv -T -- "$marker.new" "$marker"
  fi
  revision_file="$extracted/usr/share/doc/lmm-api-bin/REVISION"
  [[ -f $revision_file && ! -L $revision_file && $(sed -n '1p' "$revision_file") == "$EXPECTED_REVISION" ]] || \
    die 'extracted core package revision mismatch'
  EXTRACTED_DEPLOY_LIBDIR="$extracted/usr/lib/lmm-api/deploy"
  [[ -d $EXTRACTED_DEPLOY_LIBDIR && ! -L $EXTRACTED_DEPLOY_LIBDIR ]] || \
    die 'extracted core deployment payload is missing or unsafe'
  package_manifest_sha=$(bsdtar -xOf "$CORE_PACKAGE" \
    usr/lib/lmm-api/deploy/route-gate-assets.sha256 | sha256sum | awk '{print $1}') || \
    die 'core package route-gate asset manifest is unavailable'
  is_sha256 "$package_manifest_sha" || die 'core package route-gate asset manifest checksum is invalid'
  [[ $(sha256sum "$EXTRACTED_DEPLOY_LIBDIR/route-gate-assets.sha256" | awk '{print $1}') == "$package_manifest_sha" ]] || \
    die 'extracted route-gate asset manifest differs from the SHA-pinned core package'
  EXTRACTED_ROUTE_MANIFEST_SHA=$package_manifest_sha
}

validate_preinstall_route_payloads() {
  prepare_extracted_route_payload
  is_sha256 "$ROUTE_GATE_SHA256" || die 'invalid route-gate checksum'
  [[ $(sha256sum "$ROUTE_GATE" | awk '{print $1}') == "$ROUTE_GATE_SHA256" ]] || die 'route-gate checksum mismatch'
  run_route_validator "$EXTRACTED_DEPLOY_LIBDIR" "$ROUTE_GATE" transferred-preinstall \
    "$EXTRACTED_ROUTE_MANIFEST_SHA"
  run_route_validator "$EXTRACTED_DEPLOY_LIBDIR" \
    "$EXTRACTED_DEPLOY_LIBDIR/migration-gate.tsv" canonical-preinstall "$EXTRACTED_ROUTE_MANIFEST_SHA"
}

validate_installed_route_payload() {
  local core_record backend_record core_name backend_name revision_path owner path installed_manifest_sha
  local -a owned_paths
  core_record=$(guard_value new_core_package)
  backend_record=$(guard_value new_backend_package)
  core_name=${core_record%% *}
  backend_name=${backend_record%% *}
  [[ $core_name == lmm-api-bin && $backend_name == lmm-api-rs-bin ]] || \
    die 'installed release package names are not exact'
  [[ $(pacman -Q "$core_name") == "$core_record" && $(pacman -Q "$backend_name") == "$backend_record" ]] || \
    die 'installed release package name/version identity mismatch'
  pacman -Qkk "$core_name" "$backend_name" >/dev/null || die 'installed release package integrity check failed'
  revision_path=/usr/share/doc/lmm-api-bin/REVISION
  if (( ${LMM_DEPLOY_TEST_MODE:-0} == 1 )) && [[ -n ${LMM_DEPLOY_TEST_REVISION_PATH:-} ]]; then
    revision_path=$LMM_DEPLOY_TEST_REVISION_PATH
  fi
  owned_paths=(
    "$DEPLOY_LIBDIR/validate-route-gate"
    "$DEPLOY_LIBDIR/migration-gate.tsv"
    "$DEPLOY_LIBDIR/frozen-route-auth.tsv"
    "$DEPLOY_LIBDIR/migration-compatibility.env"
    "$DEPLOY_LIBDIR/route-gate-assets.sha256"
    "$revision_path"
  )
  for path in "${owned_paths[@]}"; do
    [[ -f $path && ! -L $path ]] || die "installed route-gate asset is missing or unsafe: $path"
    owner=$(pacman -Qqo -- "$path") || die "installed route-gate asset has no package owner: $path"
    [[ $owner == "$core_name" ]] || die "installed route-gate asset package owner mismatch: $path"
  done
  [[ $(sed -n '1p' "$revision_path") == "$EXPECTED_REVISION" ]] || die 'installed core revision mismatch'
  installed_manifest_sha=$(sha256sum "$DEPLOY_LIBDIR/route-gate-assets.sha256" | awk '{print $1}')
  run_route_validator "$DEPLOY_LIBDIR" "$DEPLOY_LIBDIR/migration-gate.tsv" installed-postinstall \
    "$installed_manifest_sha"
}

render_and_enable_units() {
  local deadline_epoch=$1 service_template timer_template service_rendered timer_rendered
  service_template="$WORKSPACE/staging/lmm-api-rollback.service"
  timer_template="$WORKSPACE/staging/lmm-api-rollback.timer"
  service_rendered="$WORKSPACE/staging/lmm-api-rollback.service.rendered"
  timer_rendered="$WORKSPACE/staging/lmm-api-rollback.timer.rendered"
  [[ -f $service_template && ! -L $service_template && -f $timer_template && ! -L $timer_template ]] || \
    die 'rollback unit templates are missing or unsafe'
  sed -e "s|__LMM_GUARD__|$GUARD|g" \
    -e "s|__LMM_ACTIVATOR__|$WORKSPACE/staging/activate-rust-release.sh|g" \
    -e "s|__LMM_WORKSPACE__|$WORKSPACE|g" \
    -e "s|__LMM_TARGET_BACKUP__|$TARGET_BACKUP|g" \
    -e "s|__LMM_ROLLBACK_CORE__|$WORKSPACE/staging/rollback-core.pkg|g" \
    -e "s|__LMM_ROLLBACK_BACKEND__|$WORKSPACE/staging/rollback-backend.pkg|g" \
    -e "s|__LMM_FRONTEND_SCRIPT__|$FRONTEND_RELEASE_SCRIPT|g" \
    -e "s|__LMM_STATUS_FILE__|$STATUS_FILE|g" "$service_template" >"$service_rendered"
  sed "s/@__LMM_ROLLBACK_DEADLINE_EPOCH__$/@$deadline_epoch/" "$timer_template" >"$timer_rendered"
  grep -Fqx "OnCalendar=@$deadline_epoch" "$timer_rendered" || die 'rollback timer deadline rendering failed'
  grep -Fqx "ExecCondition=/usr/bin/grep -Eq ^status=(ARMED|ROLLING_BACK)\$ $GUARD" "$service_rendered" || \
    die 'rollback service guard rendering failed'
  install -Dm0644 "$service_rendered" "$SYSTEMD_UNIT_DIR/lmm-api-rollback.service"
  install -Dm0644 "$timer_rendered" "$SYSTEMD_UNIT_DIR/lmm-api-rollback.timer"
  systemctl daemon-reload
  systemctl enable --now lmm-api-rollback.timer
  systemctl is-enabled --quiet lmm-api-rollback.timer
  systemctl is-active --quiet lmm-api-rollback.timer
}

prepare_transaction() {
  local old_selection old_backend_path old_core_name old_backend_name old_core_record old_backend_record
  local old_core_arch old_backend_arch old_backend_sha old_backend_config_sha old_env_config_sha old_revision
  local response configuration_file config_snapshot config_snapshot_sha old_frontend deadline_epoch acceptance_deadline_epoch
  local frontend_stage frontend_digest terminal_mutex
  local core_record backend_record core_arch backend_arch
  local -a core_candidates=() backend_candidates=()
  safe_identity "$EXPECTED_RELEASE" || die 'invalid release identity'
  [[ $EXPECTED_REVISION =~ ^[0-9a-f]{7,64}$ ]] || die 'invalid revision identity'
  [[ -f $CORE_PACKAGE && ! -L $CORE_PACKAGE && -f $BACKEND_PACKAGE && ! -L $BACKEND_PACKAGE ]] || die 'new packages are missing'
  [[ -f $ROUTE_GATE && ! -L $ROUTE_GATE ]] || die 'route gate is missing'
  [[ $FRONTEND_RELEASE_SCRIPT == "$WORKSPACE/staging/"* && -f $FRONTEND_RELEASE_SCRIPT && ! -L $FRONTEND_RELEASE_SCRIPT ]] || \
    die 'frontend release helper is missing or unsafe'
  if [[ -e $GUARD || -L $GUARD ]]; then
    [[ -f $GUARD && ! -L $GUARD ]] || die 'existing rollback guard is unsafe'
    [[ $(guard_value deployment_id) == "$deployment_id" ]] || die 'existing rollback guard belongs to another deployment'
    case $(guard_value status) in
      CONFIRMED|ROLLED_BACK)
        die "prepare refused for terminal deployment: $(guard_value status)"
        ;;
      PREPARED|ARMED|ROLLING_BACK) ;;
      *) die 'existing rollback guard has an invalid state' ;;
    esac
  fi
  validate_new_artifacts
  validate_preinstall_route_payloads
  acquire_transaction_lock
  if [[ -e $GUARD || -L $GUARD ]]; then
    [[ -f $GUARD && ! -L $GUARD ]] || die 'existing rollback guard is unsafe'
    [[ $(guard_value deployment_id) == "$deployment_id" ]] || die 'existing rollback guard cannot be overwritten'
    case $(guard_value status) in
      PREPARED) ;;
      ARMED)
        [[ -f $STATUS_FILE && $(sed -n '1p' "$STATUS_FILE") == AWAITING_CONFIRMATION\ * ]] || \
          die 'existing armed deployment is not safely resumable'
        ;;
      *) die 'existing rollback guard cannot be overwritten' ;;
    esac
      validate_new_artifacts
    systemctl is-enabled --quiet lmm-api-rollback.timer
    systemctl is-active --quiet lmm-api-rollback.timer
    prepare_acceptance_baseline
    return 0
  fi
  old_selection=$(sed -nE 's/^LMM_API_BACKEND=(go|rs)$/\1/p' "$BACKEND_CONFIG")
  [[ $old_selection == go || $old_selection == rs ]] || die 'current backend selection is invalid'
  old_core_name=$(pacman -Qqo /usr/bin/lmm-api)
  case $old_selection in
    go) old_backend_path="$BACKEND_ROOT/go/lmm-api" ;;
    rs) old_backend_path="$BACKEND_ROOT/rs/lmm-api-rs" ;;
  esac
  old_backend_name=$(pacman -Qqo "$old_backend_path")
  old_core_record=$(pacman -Q "$old_core_name")
  old_backend_record=$(pacman -Q "$old_backend_name")
  old_core_arch=$(installed_arch "$old_core_name")
  old_backend_arch=$(installed_arch "$old_backend_name")
  [[ -n $old_core_arch && -n $old_backend_arch ]] || die 'installed rollback package architecture is unavailable'
  mapfile -t core_candidates < <(find "$PACMAN_CACHE" -maxdepth 1 -type f \
    -name "${old_core_record/ /-}-$old_core_arch.pkg.tar.*" ! -name '*.sig' -print)
  mapfile -t backend_candidates < <(find "$PACMAN_CACHE" -maxdepth 1 -type f \
    -name "${old_backend_record/ /-}-$old_backend_arch.pkg.tar.*" ! -name '*.sig' -print)
  ((${#core_candidates[@]} == 1 && ${#backend_candidates[@]} == 1)) || \
    die 'rollback package archive selection is not unique'
  [[ $(package_record "${core_candidates[0]}") == "$old_core_record" && \
    $(package_archive_arch "${core_candidates[0]}") == "$old_core_arch" ]] || die 'rollback core archive identity mismatch'
  [[ $(package_record "${backend_candidates[0]}") == "$old_backend_record" && \
    $(package_archive_arch "${backend_candidates[0]}") == "$old_backend_arch" ]] || die 'rollback provider archive identity mismatch'
  install -m0600 "${core_candidates[0]}" "$WORKSPACE/staging/rollback-core.pkg"
  install -m0600 "${backend_candidates[0]}" "$WORKSPACE/staging/rollback-backend.pkg"
  old_backend_sha=$(sha256sum "$old_backend_path" | awk '{print $1}')
  old_backend_config_sha=$(sha256sum "$BACKEND_CONFIG" | awk '{print $1}')
  old_env_config_sha=$(sha256sum "$ENV_CONFIG" | awk '{print $1}')
  response=$(curl --fail --silent --show-error --max-time 5 "$HEALTH_URL") || die 'current backend health probe failed'
  old_revision=$(jq -er '
    select(.success == true and .ready == true and (.data | type == "object")) |
    [.data.revision?, .data.version?] | map(select(type == "string" and length > 0)) | unique |
    if length == 1 then .[0] else error("ambiguous health identity") end
  ' <<<"$response")
  safe_identity "$old_revision" || die 'current backend health identity is unsafe'
  old_frontend=$(readlink -- "$FRONTEND_ROOT/current")
  [[ $old_frontend == releases/* ]] || die 'current frontend identity is unsafe'
  configuration_file=$(sed -n 's/^configuration_file=//p' "$TARGET_BACKUP/manifest.env")
  config_snapshot="$TARGET_BACKUP/$configuration_file"
  [[ -f $config_snapshot && ! -L $config_snapshot ]] || die 'configuration snapshot is unavailable'
  config_snapshot_sha=$(sha256sum "$config_snapshot" | awk '{print $1}')
  core_record=$(package_record "$CORE_PACKAGE")
  backend_record=$(package_record "$BACKEND_PACKAGE")
  core_arch=$(package_archive_arch "$CORE_PACKAGE")
  backend_arch=$(package_archive_arch "$BACKEND_PACKAGE")
  install -d -m0700 "${GUARD%/*}"
  deadline_epoch=$(( $(date -u +%s) + 600 ))
  acceptance_deadline_epoch=$(( deadline_epoch - 360 ))
  frontend_stage=$(mktemp -d "$WORKSPACE/staging/frontend-identity.XXXXXXXX")
  bsdtar -xf "$CORE_PACKAGE" -C "$frontend_stage" usr/share/lmm-api/frontend-dist || {
    rm -rf -- "$frontend_stage"
    die 'new frontend archive extraction failed'
  }
  frontend_digest=$(frontend_manifest_digest "$frontend_stage/usr/share/lmm-api/frontend-dist") || {
    rm -rf -- "$frontend_stage"
    die 'new frontend identity digest failed'
  }
  rm -rf -- "$frontend_stage"
  terminal_mutex="$WORKSPACE/state/terminal.mutex"
  if [[ -e $terminal_mutex || -L $terminal_mutex ]]; then
    [[ -f $terminal_mutex && ! -L $terminal_mutex ]] || die 'deployment terminal mutex is unsafe'
  else
    : >"$terminal_mutex"
  fi
  chmod 0600 "$terminal_mutex"
  (( ${LMM_DEPLOY_TEST_MODE:-0} == 1 )) || chown root:root "$terminal_mutex"
  cat >"$GUARD.new" <<EOF
format=2
deployment_id=$deployment_id
transaction_lock=$TRANSACTION_LOCK
terminal_mutex=$terminal_mutex
git_revision=$EXPECTED_REVISION
status=PREPARED
deadline_epoch=$deadline_epoch
acceptance_deadline_epoch=$acceptance_deadline_epoch
acceptance_watchdog_deadline_epoch=$deadline_epoch
target_backup=$TARGET_BACKUP
config_snapshot=$config_snapshot
config_snapshot_sha256=$config_snapshot_sha
old_core_package=$old_core_record
old_core_arch=$old_core_arch
old_backend_package=$old_backend_record
old_backend_arch=$old_backend_arch
old_backend_selection=$old_selection
old_backend_path=$old_backend_path
old_backend_sha256=$old_backend_sha
old_backend_config_sha256=$old_backend_config_sha
old_env_config_sha256=$old_env_config_sha
old_revision=$old_revision
new_core_package=$core_record
new_core_arch=$core_arch
new_backend_package=$backend_record
new_backend_arch=$backend_arch
old_frontend=$old_frontend
new_frontend=releases/$EXPECTED_RELEASE
frontend_digest=$frontend_digest
core_sha256=$CORE_SHA256
backend_sha256=$BACKEND_SHA256
rollback_core_sha256=$(sha256sum "$WORKSPACE/staging/rollback-core.pkg" | awk '{print $1}')
rollback_backend_sha256=$(sha256sum "$WORKSPACE/staging/rollback-backend.pkg" | awk '{print $1}')
EOF
  chmod 0600 "$GUARD.new"
  (( ${LMM_DEPLOY_TEST_MODE:-0} == 1 )) || chown root:root "$GUARD.new"
  mv -Tf -- "$GUARD.new" "$GUARD"
  chmod 0700 "$WORKSPACE/staging/activate-rust-release.sh" "$FRONTEND_RELEASE_SCRIPT"
  render_and_enable_units "$deadline_epoch"
  write_status PREPARED
  prepare_acceptance_baseline
}

validate_guard_and_lock() {
  [[ -f $GUARD && ! -L $GUARD ]] || die 'root-only rollback guard is required'
  [[ $(stat -c '%U:%G:%a' "$GUARD") == root:root:600 || ${LMM_DEPLOY_TEST_MODE:-0} == 1 ]] || \
    die 'rollback guard ownership/mode is unsafe'
  [[ $(guard_value deployment_id) == "$deployment_id" ]] || die 'rollback guard deployment mismatch'
  [[ $(guard_value transaction_lock) == "$TRANSACTION_LOCK" ]] || die 'rollback guard lock mismatch'
  [[ $(guard_value terminal_mutex) == "$WORKSPACE/state/terminal.mutex" ]] || die 'rollback guard mutex mismatch'
  [[ $(guard_value target_backup) == "$TARGET_BACKUP" ]] || die 'rollback guard target backup mismatch'
  [[ $(guard_value config_snapshot) == "$TARGET_BACKUP"/* ]] || die 'rollback guard config snapshot mismatch'
  [[ $(sha256sum "$(guard_value config_snapshot)" | awk '{print $1}') == "$(guard_value config_snapshot_sha256)" ]] || \
    die 'rollback configuration snapshot checksum mismatch'
  if ((CONFIRM_ONLY == 0)); then
    [[ $(sha256sum "$ROLLBACK_CORE" | awk '{print $1}') == "$(guard_value rollback_core_sha256)" ]] || die 'rollback core checksum mismatch'
    [[ $(sha256sum "$ROLLBACK_BACKEND" | awk '{print $1}') == "$(guard_value rollback_backend_sha256)" ]] || die 'rollback backend checksum mismatch'
  fi
  case $(guard_value status) in
    CONFIRMED|ROLLED_BACK) [[ ! -e $TRANSACTION_LOCK && ! -L $TRANSACTION_LOCK ]] || validate_transaction_lock ;;
    *) validate_transaction_lock ;;
  esac
}

reset_watchdog_deadline() {
  local deadline_epoch previous_deadline
  previous_deadline=$(guard_value deadline_epoch)
  [[ $previous_deadline =~ ^[0-9]+$ ]] || die 'rollback guard deadline is invalid'
  deadline_epoch=$(( $(date -u +%s) + 600 ))
  replace_guard_field deadline_epoch "$previous_deadline" "$deadline_epoch"
  render_and_enable_units "$deadline_epoch"
}
prepare_switch_watchdog() {
  [[ $(guard_value status) == PREPARED ]] || die 'rollback guard is not prepared before switch'
  systemctl is-enabled --quiet lmm-api-rollback.timer || die 'rollback timer is not enabled before switch'
  systemctl is-active --quiet lmm-api-rollback.timer || die 'rollback timer is not active before switch'
  reset_watchdog_deadline
  replace_guard_field status PREPARED ARMED
}
disable_watchdog() {
  systemctl disable --now lmm-api-rollback.timer >/dev/null 2>&1 || {
    ! systemctl is-enabled --quiet lmm-api-rollback.timer && ! systemctl is-active --quiet lmm-api-rollback.timer
  }
  systemctl disable lmm-api-rollback.service >/dev/null 2>&1 || ! systemctl is-enabled --quiet lmm-api-rollback.service
}

verify_rollback_state() {
  local old_core old_backend old_core_name old_backend_name old_backend_path old_revision response
  old_core=$(guard_value old_core_package)
  old_backend=$(guard_value old_backend_package)
  old_core_name=${old_core%% *}
  old_backend_name=${old_backend%% *}
  old_backend_path=$(guard_value old_backend_path)
  old_revision=$(guard_value old_revision)
  [[ $(pacman -Q "$old_core_name") == "$old_core" && $(installed_arch "$old_core_name") == "$(guard_value old_core_arch)" ]] || \
    die 'rollback core identity mismatch'
  [[ $(pacman -Q "$old_backend_name") == "$old_backend" && $(installed_arch "$old_backend_name") == "$(guard_value old_backend_arch)" ]] || \
    die 'rollback provider identity mismatch'
  pacman -Qkk "$old_core_name" "$old_backend_name" >/dev/null || die 'rollback package integrity check failed'
  [[ $(pacman -Qqo "$old_backend_path") == "$old_backend_name" ]] || die 'rollback backend path owner mismatch'
  [[ $(sha256sum "$old_backend_path" | awk '{print $1}') == "$(guard_value old_backend_sha256)" ]] || die 'rollback backend binary checksum mismatch'
  [[ $(sha256sum "$BACKEND_CONFIG" | awk '{print $1}') == "$(guard_value old_backend_config_sha256)" ]] || die 'rollback backend config checksum mismatch'
  [[ $(sha256sum "$ENV_CONFIG" | awk '{print $1}') == "$(guard_value old_env_config_sha256)" ]] || die 'rollback environment checksum mismatch'
  grep -Fqx "LMM_API_BACKEND=$(guard_value old_backend_selection)" "$BACKEND_CONFIG" || die 'rollback backend selection mismatch'
  [[ $(readlink -- "$FRONTEND_ROOT/current") == "$(guard_value old_frontend)" ]] || die 'rollback frontend identity mismatch'
  systemctl is-active --quiet "$SERVICE" || die 'rollback service is not active'
  response=$(curl --fail --silent --show-error --max-time 5 "$HEALTH_URL") || die 'rollback backend health probe failed'
  jq -e --arg revision "$old_revision" \
    '.success == true and .ready == true and (.data.version == $revision or .data.revision == $revision)' \
    <<<"$response" >/dev/null || die 'rollback backend supplementary health identity mismatch'
}

verify_new_deployed_state() {
  local new_core new_backend response
  new_core=$(guard_value new_core_package)
  new_backend=$(guard_value new_backend_package)
  [[ $(pacman -Q "${new_core%% *}") == "$new_core" ]] || die 'installed core identity mismatch'
  [[ $(pacman -Q "${new_backend%% *}") == "$new_backend" ]] || die 'installed Rust identity mismatch'
  [[ $(installed_arch "${new_core%% *}") == "$(guard_value new_core_arch)" ]] || die 'installed core architecture mismatch'
  [[ $(installed_arch "${new_backend%% *}") == "$(guard_value new_backend_arch)" ]] || die 'installed Rust architecture mismatch'
  pacman -Qkk "${new_core%% *}" "${new_backend%% *}" >/dev/null || die 'installed package integrity check failed'
  grep -Fqx 'LMM_API_BACKEND=rs' "$BACKEND_CONFIG" || die 'installed backend selection mismatch'
  systemctl is-active --quiet "$SERVICE" || die 'installed service is not active'
  [[ $(readlink -- "$FRONTEND_ROOT/current") == "releases/$EXPECTED_RELEASE" ]] || die 'installed frontend identity mismatch'
  response=$(curl --fail --silent --show-error --max-time 5 "$HEALTH_URL") || die 'installed backend health probe failed'
  jq -e --arg revision "$EXPECTED_REVISION" \
    '.success == true and .ready == true and (.data.version == $revision or .data.revision == $revision)' \
    <<<"$response" >/dev/null || die 'installed backend identity mismatch'
}

perform_guarded_confirmation() {
  local status baseline evidence
  baseline="$WORKSPACE/state/acceptance-baseline.json"
  evidence="$WORKSPACE/state/acceptance-verify.json"
  acquire_terminal_mutex
  if (( ${LMM_DEPLOY_TEST_MODE:-0} == 1 )) && [[ -n ${LMM_DEPLOY_TEST_CONFIRM_HOLD_FILE:-} ]]; then
    [[ -n ${LMM_DEPLOY_TEST_CONFIRM_READY_FILE:-} ]] || die 'confirmation race ready file is missing'
    : >"$LMM_DEPLOY_TEST_CONFIRM_READY_FILE"
    while [[ -e $LMM_DEPLOY_TEST_CONFIRM_HOLD_FILE ]]; do sleep 0.01; done
  fi
  status=$(guard_value status)
  case $status in
    ARMED) validate_transaction_lock ;;
    CONFIRMED) [[ ! -e $TRANSACTION_LOCK && ! -L $TRANSACTION_LOCK ]] || validate_transaction_lock ;;
    ROLLING_BACK|ROLLED_BACK)
      release_terminal_mutex
      die "confirmation refused after rollback began: $status"
      ;;
    *) release_terminal_mutex; die "confirmation requires exact ARMED state: $status" ;;
  esac
  validate_new_artifacts
  verify_new_deployed_state
  validate_acceptance_evidence baseline "$baseline"
  validate_acceptance_evidence verify "$evidence" "$baseline"
  if [[ $status == ARMED ]]; then
    replace_guard_field status ARMED CONFIRMED
    sync -f "$GUARD"
  fi
  write_status "CONFIRMED deployment=$deployment_id"
  sync -f "$STATUS_FILE"
  systemctl disable --now lmm-api-rollback.timer >/dev/null 2>&1 || true
  systemctl disable lmm-api-rollback.service >/dev/null 2>&1 || true

  # Let a rollback process that passed ExecCondition before the CAS acquire the
  # mutex, observe CONFIRMED, and exit without touching deployment state.
  release_terminal_mutex
  for _ in {1..50}; do
    systemctl is-active --quiet lmm-api-rollback.service || break
    sleep 0.1
  done
  acquire_terminal_mutex
  [[ $(guard_value status) == CONFIRMED ]] || die 'confirmed guard state was not durable'
  ! systemctl is-active --quiet lmm-api-rollback.timer || die 'rollback timer remained active after confirmation'
  ! systemctl is-enabled --quiet lmm-api-rollback.timer || die 'rollback timer remained enabled after confirmation'
  ! systemctl is-active --quiet lmm-api-rollback.service || die 'rollback service remained active after confirmation'
  ! systemctl is-enabled --quiet lmm-api-rollback.service || die 'rollback service remained enabled after confirmation'
  validate_new_artifacts
  verify_new_deployed_state
  validate_acceptance_evidence verify "$evidence" "$baseline"
  if [[ -e $TRANSACTION_LOCK || -L $TRANSACTION_LOCK ]]; then
    release_transaction_lock
  fi
  [[ ! -e $TRANSACTION_LOCK && ! -L $TRANSACTION_LOCK ]] || die 'confirmed deployment lock was not released'
  sync -f "${TRANSACTION_LOCK%/*}"
  release_terminal_mutex
}

perform_guarded_rollback() {
  local reason=$1 status old_frontend restore_dir config_snapshot old_core old_backend
  acquire_terminal_mutex
  status=$(guard_value status)
  old_frontend=$(guard_value old_frontend)
  case $status in
    ARMED) replace_guard_field status ARMED ROLLING_BACK ;;
    ROLLING_BACK) ;;
    CONFIRMED)
      write_status "CONFIRMED deployment=$deployment_id"
      release_terminal_mutex
      return 0
      ;;
    ROLLED_BACK)
      verify_rollback_state
      write_status "ROLLED_BACK ${old_frontend#releases/} reason=already-rolled-back"
      disable_watchdog
      [[ ! -e $TRANSACTION_LOCK ]] || release_transaction_lock
      release_terminal_mutex
      return 0
      ;;
    *) release_terminal_mutex; die "rollback guard is not armed: $status" ;;
  esac
  old_core=$(guard_value old_core_package)
  old_backend=$(guard_value old_backend_package)
  [[ $(package_record "$ROLLBACK_CORE") == "$old_core" && \
    $(package_archive_arch "$ROLLBACK_CORE") == "$(guard_value old_core_arch)" ]] || die 'rollback core archive revalidation failed'
  [[ $(package_record "$ROLLBACK_BACKEND") == "$old_backend" && \
    $(package_archive_arch "$ROLLBACK_BACKEND") == "$(guard_value old_backend_arch)" ]] || die 'rollback provider archive revalidation failed'
  write_status "ROLLBACK_STARTED $reason"
  pacman -U --noconfirm "$ROLLBACK_CORE" "$ROLLBACK_BACKEND" || die 'rollback package installation failed'
  config_snapshot=$(guard_value config_snapshot)
  restore_dir=$(mktemp -d "$WORKSPACE/staging/config-restore.XXXXXXXX")
  tar -xf "$config_snapshot" -C "$restore_dir"
  [[ -f $restore_dir/lmm-api/backend.conf && -f $restore_dir/lmm-api/lmm-api.env ]] || die 'configuration snapshot is incomplete'
  install -m0644 "$restore_dir/lmm-api/backend.conf" "$BACKEND_CONFIG"
  install -m0600 "$restore_dir/lmm-api/lmm-api.env" "$ENV_CONFIG"
  "$FRONTEND_RELEASE_SCRIPT" rollback --root "$FRONTEND_ROOT" --release "${old_frontend#releases/}" --keep 5 || \
    die 'rollback frontend restoration failed'
  systemctl restart "$SERVICE" || die 'rollback service restart failed'
  verify_rollback_state
  replace_guard_field status ROLLING_BACK ROLLED_BACK
  write_status "ROLLED_BACK ${old_frontend#releases/} reason=$reason"
  disable_watchdog
  release_transaction_lock
  release_terminal_mutex
}

if ((PREPARE_ONLY)); then
  prepare_transaction
  exit 0
fi

required_paths=()
if ((ROLLBACK_ONLY)); then
  required_paths+=("$ROLLBACK_CORE" "$ROLLBACK_BACKEND" "$FRONTEND_RELEASE_SCRIPT")
elif ((CONFIRM_ONLY)); then
  required_paths+=("$CORE_PACKAGE" "$BACKEND_PACKAGE")
else
  required_paths+=("$ROLLBACK_CORE" "$ROLLBACK_BACKEND" "$FRONTEND_RELEASE_SCRIPT" \
    "$CORE_PACKAGE" "$BACKEND_PACKAGE" "$ROUTE_GATE")
fi
for path in "${required_paths[@]}"; do
  [[ $path == "$WORKSPACE/staging/"* && -f $path && ! -L $path ]] || die "unsafe staged path: $path"
done
validate_guard_and_lock
if ((ROLLBACK_ONLY)); then
  perform_guarded_rollback watchdog
  exit 0
fi

safe_identity "$EXPECTED_RELEASE" || die 'invalid release identity'
[[ $EXPECTED_REVISION =~ ^[0-9a-f]{7,64}$ ]] || die 'invalid revision identity'
if ((CONFIRM_ONLY)); then
  perform_guarded_confirmation
  exit 0
fi
validate_new_artifacts
validate_preinstall_route_payloads

if [[ $(guard_value status) == ARMED && -f $STATUS_FILE && $(sed -n '1p' "$STATUS_FILE") == AWAITING_CONFIRMATION\ * ]]; then
  verify_new_deployed_state
  systemctl is-enabled --quiet lmm-api-rollback.timer
  systemctl is-active --quiet lmm-api-rollback.timer
  exit 0
fi

rollback() {
  local reason=$1
  perform_guarded_rollback "$reason" || write_status "ROLLBACK_FAILED reason=$reason"
  exit 1
}
prepare_switch_watchdog
if (( ${LMM_DEPLOY_TEST_CRASH_AFTER_ARM:-0} == 1 )); then
  exit 99
fi
trap 'rollback unexpected-error' ERR
write_status PREPARING
pacman -U --noconfirm "$CORE_PACKAGE" "$BACKEND_PACKAGE"
validate_installed_route_payload
printf '# Managed by lmm-api deployment.\nLMM_API_BACKEND=rs\n' >"$BACKEND_CONFIG"
systemctl restart "$SERVICE"
[[ -f $FRONTEND_SOURCE/index.html ]] || rollback frontend-source-missing
"$FRONTEND_RELEASE_SCRIPT" publish --root "$FRONTEND_ROOT" --source "$FRONTEND_SOURCE" \
  --release "$EXPECTED_RELEASE" --keep 5 || rollback frontend-publish-failed
backend_response=$(curl --fail --silent --show-error --max-time 5 "$HEALTH_URL") || rollback backend-health-failed
jq -e --arg revision "$EXPECTED_REVISION" \
  '.success == true and .ready == true and (.data.version == $revision or .data.revision == $revision)' \
  <<<"$backend_response" >/dev/null || rollback backend-identity-failed
[[ $(readlink -- "$FRONTEND_ROOT/current") == "releases/$EXPECTED_RELEASE" ]] || rollback frontend-identity-failed
verify_new_deployed_state
verify_evidence="$WORKSPACE/state/acceptance-verify.json"
baseline_evidence="$WORKSPACE/state/acceptance-baseline.json"
run_acceptance verify "$verify_evidence" "$baseline_evidence"
validate_acceptance_evidence verify "$verify_evidence" "$baseline_evidence"
reset_watchdog_deadline
write_status "AWAITING_CONFIRMATION release=$EXPECTED_RELEASE revision=$EXPECTED_REVISION frontend=$EXPECTED_RELEASE"
trap - ERR
