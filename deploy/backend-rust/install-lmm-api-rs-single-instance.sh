#!/usr/bin/env bash
# Bootstrap or explicitly roll back the isolated fallback service.  Neither
# action enables a unit, reloads nginx, nor starts a service implicitly.
set -Eeuo pipefail
umask 077

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
readonly SCRIPT_DIR
readonly GUARD="$SCRIPT_DIR/fallback-target-guard.sh"
readonly SERVICE_NAME='lmm-api-rs-single.service'

die() { printf 'install-lmm-api-rs-single-instance: %s\n' "$*" >&2; exit 1; }
is_sha256() { [[ $1 =~ ^[0-9a-f]{64}$ ]]; }

if [[ ${LMM_RS_MOCK:-} == 1 ]]; then
  ASSET_ROOT=${LMM_RS_SINGLE_ASSET_ROOT:-/usr/lib/lmm-api-rs/deploy}
  ROOT=${LMM_RS_SINGLE_ROOT:-/opt/lmm-api-rs-single}
  ETC_ROOT=${LMM_RS_SINGLE_ETC_ROOT:-/etc/lmm-api-rs-single}
  STATE_ROOT=${LMM_RS_SINGLE_STATE_ROOT:-/var/lib/lmm-api-rs-single}
else
  ASSET_ROOT=/usr/lib/lmm-api-rs/deploy
  ROOT=/opt/lmm-api-rs-single
  ETC_ROOT=/etc/lmm-api-rs-single
  STATE_ROOT=/var/lib/lmm-api-rs-single
fi
readonly ASSET_ROOT ROOT ETC_ROOT STATE_ROOT
readonly RELEASES="$ROOT/releases"
readonly CURRENT="$ROOT/current"
readonly JOURNAL="$ROOT/release-journal.log"

[[ ${LMM_RS_TEST_INSTANCE:-} == 1 ]] || die 'refusing to bootstrap without LMM_RS_TEST_INSTANCE=1'
[[ -x $GUARD && ! -L $GUARD ]] || die 'shared fallback target guard is missing or unsafe'
"$GUARD"
[[ $EUID -eq 0 || ${LMM_RS_MOCK:-} == 1 ]] || die 'must run as root'

metadata_value() {
  local metadata=$1 key=$2
  awk -F= -v key="$key" '$1 == key { count++; value=$2 } END { if (count == 1) print value; else exit 1 }' "$metadata"
}

verify_release() {
  local manifest=$1
  local dir="$RELEASES/$manifest" metadata expected actual
  is_sha256 "$manifest" || return 1
  [[ -d $dir && ! -L $dir && -f $dir/release.env && ! -L $dir/release.env && -f $dir/lmm-api-rs && ! -L $dir/lmm-api-rs ]] || return 1
  metadata="$dir/release.env"
  [[ $(metadata_value "$metadata" manifest) == "$manifest" ]] || return 1
  expected=$(metadata_value "$metadata" binary_sha256) || return 1
  is_sha256 "$expected" || return 1
  actual=$(sha256sum "$dir/lmm-api-rs" | awk '{print $1}')
  [[ $actual == "$expected" ]]
}

current_manifest() {
  local target
  [[ -L $CURRENT ]] || return 1
  target=$(readlink "$CURRENT") || return 1
  [[ $target =~ ^releases/([0-9a-f]{64})$ ]] || return 1
  printf '%s\n' "${BASH_REMATCH[1]}"
}

select_release() {
  local manifest=$1
  local temporary_link="$ROOT/.rollback.${manifest}.$$.new"
  ln -s "releases/$manifest" "$temporary_link"
  mv -Tf "$temporary_link" "$CURRENT"
}

probe_active_release() {
  local manifest=$1 build
  curl --fail --silent --show-error --max-time 3 http://127.0.0.1:3100/livez >/dev/null || return
  curl --fail --silent --show-error --max-time 3 http://127.0.0.1:3100/readyz >/dev/null || return
  build=$(curl --fail --silent --show-error --max-time 3 http://127.0.0.1:3100/_internal/build) || return
  jq -e --arg manifest "$manifest" '.revision == $manifest and .slot == "single"' <<<"$build" >/dev/null
}

rollback() {
  local requested=$1 current previous
  is_sha256 "$requested" || die 'rollback manifest must be a 64-character lowercase SHA-256'
  current=$(current_manifest) || die 'current release is unknown; refusing rollback'
  verify_release "$current" || die 'current release verification failed'
  previous=$(metadata_value "$RELEASES/$current/release.env" previous) || die 'current release lacks a verified prior release record'
  [[ $previous == "$requested" && $previous != none ]] || die 'rollback target is not the verified prior release'
  verify_release "$previous" || die 'rollback target verification failed'
  select_release "$previous"
  if ! systemctl restart "$SERVICE_NAME" || ! systemctl is-active --quiet "$SERVICE_NAME" || ! probe_active_release "$previous"; then
    select_release "$current"
    systemctl restart "$SERVICE_NAME" || true
    probe_active_release "$current" || true
    die 'rollback health or build identity probe failed; current release was restored'
  fi
  [[ ! -e $JOURNAL || ! -L $JOURNAL ]] || die 'release journal must not be a symlink'
  touch "$JOURNAL"
  if [[ ${LMM_RS_MOCK:-} != 1 ]]; then
    chown 0:0 "$JOURNAL"
  fi
  chmod 0600 "$JOURNAL"
  printf 'rollback_from=%s rollback_to=%s\n' "$current" "$previous" >>"$JOURNAL"
  printf 'rolled_back_manifest=%s nginx=unchanged\n' "$previous"
}

bootstrap() {
  [[ $ASSET_ROOT == /usr/lib/lmm-api-rs/deploy || ${LMM_RS_MOCK:-} == 1 ]] || die 'asset root is fixed for the packaged test instance'
  for path in "$ROOT" "$ETC_ROOT" "$STATE_ROOT"; do
    [[ ! -L $path ]] || die "managed path must not be a symlink: $path"
    [[ ! -e $path || -d $path ]] || die "managed path must be a directory: $path"
  done
  for asset in test-instance.env.example single.env; do
    [[ -f $ASSET_ROOT/$asset && ! -L $ASSET_ROOT/$asset ]] || die "missing packaged asset: $asset"
  done
  install -d -m 0700 "$ETC_ROOT"
  for config in common.env single.env; do
    [[ ! -L $ETC_ROOT/$config ]] || die "configuration must not be a symlink: $ETC_ROOT/$config"
  done
  if [[ ! -e $ETC_ROOT/common.env ]]; then install -m 0600 "$ASSET_ROOT/test-instance.env.example" "$ETC_ROOT/common.env"; fi
  if [[ ! -e $ETC_ROOT/single.env ]]; then install -m 0600 "$ASSET_ROOT/single.env" "$ETC_ROOT/single.env"; fi
  grep -Fxq 'PASSWORD_LOGIN_ENABLED=true' "$ETC_ROOT/common.env" || die 'test configuration must explicitly set PASSWORD_LOGIN_ENABLED=true'
  install -d -m 0755 "$RELEASES"
  install -d -m 0700 "$STATE_ROOT"
  if [[ ${LMM_RS_MOCK:-} != 1 ]]; then
    chown lmm-api-rs-fallback:lmm-api-rs-fallback "$STATE_ROOT"
  fi
  printf '%s\n' 'test single-instance layout is ready; replace each placeholder in common.env, then run the package-only deploy command with --activate'
}

case ${1:-bootstrap} in
  bootstrap)
    (($# == 0 || $# == 1)) || die 'bootstrap accepts no arguments'
    bootstrap
    ;;
  rollback)
    (($# == 2)) || die 'usage: install-lmm-api-rs-single-instance.sh rollback MANIFEST_SHA256'
    rollback "$2"
    ;;
  *) die 'usage: install-lmm-api-rs-single-instance.sh [bootstrap|rollback MANIFEST_SHA256]' ;;
esac
