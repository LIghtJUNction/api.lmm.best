#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
: "${TMPDIR:?set TMPDIR to a marker-owned workspace}"
tmp=$(mktemp -d "$TMPDIR/lmm-go-rollback-state-test.XXXXXXXX")
trap 'rm -rf -- "$tmp"' EXIT
bin=$tmp/bin
mkdir -p "$bin"

fail() { printf 'go-rollback-state-test: %s\n' "$*" >&2; exit 1; }

cat >"$bin/hostnamectl" <<'EOF'
#!/usr/bin/env bash
printf 'arch-dmit\n'
EOF

cat >"$bin/systemctl" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
command=$1
shift
unit=''
for argument in "$@"; do
  [[ $argument == --* ]] || unit=$argument
done
state_file() {
  case $1 in
    lmm-api.service) printf '%s/old' "$LMM_TEST_SERVICE_STATE" ;;
    lmm-api-go.service) printf '%s/new' "$LMM_TEST_SERVICE_STATE" ;;
    *.timer) printf '%s/timer' "$LMM_TEST_SERVICE_STATE" ;;
    *.service) printf '%s/rollback' "$LMM_TEST_SERVICE_STATE" ;;
    *) return 1 ;;
  esac
}
case $command in
  is-active)
    file=$(state_file "$unit")
    [[ -f $file.active ]]
    ;;
  is-enabled)
    file=$(state_file "$unit")
    [[ -f $file.enabled ]]
    ;;
  enable)
    file=$(state_file "$unit")
    : >"$file.enabled"
    [[ " $* " != *' --now '* ]] || : >"$file.active"
    ;;
  disable)
    file=$(state_file "$unit")
    rm -f -- "$file.enabled"
    [[ " $* " != *' --now '* ]] || rm -f -- "$file.active"
    ;;
  stop)
    file=$(state_file "$unit")
    rm -f -- "$file.active"
    ;;
  cat)
    [[ $unit != lmm-api-go.service || -f $LMM_TEST_SERVICE_STATE/new.installed ]]
    ;;
  daemon-reload|reset-failed) ;;
  *) printf 'unexpected systemctl command: %s %s\n' "$command" "$*" >&2; exit 90 ;;
esac
EOF

cat >"$bin/systemd-run" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
unit=''
for argument in "$@"; do
  case $argument in --unit=*) unit=${argument#--unit=} ;; esac
  last=$argument
done
case $unit in
  lmm-api-go-schema-*)
    printf 'lmm_prod_contract\n' >"$last"
    chmod 0600 "$last"
    ;;
  lmm-api-go-token-*)
    printf 'sk-%032d' 0 >"$last"
    chmod 0600 "$last"
    ;;
	lmm-api-go-migrate-apply-*)
		printf '%s\n' "$@" >"$LMM_TEST_SERVICE_STATE/migrate.apply.args"
		: >"$LMM_TEST_SERVICE_STATE/migrate.apply"
		;;
	lmm-api-go-migrate-verify-*)
		printf '%s\n' "$@" >"$LMM_TEST_SERVICE_STATE/migrate.verify.args"
		[[ -f $LMM_TEST_SERVICE_STATE/migrate.apply ]] || exit 91
		: >"$LMM_TEST_SERVICE_STATE/migrate.verify"
		;;
  *) printf 'unexpected transient unit: %s\n' "$unit" >&2; exit 91 ;;
esac
EOF

cat >"$bin/pacman" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
case $1 in
  -Qp)
    case ${2##*/} in
      candidate.pkg.tar.zst) printf 'lmm-api-go %s-1\n' "$LMM_TEST_NEW_VERSION" ;;
      rollback-core.pkg.tar.zst) printf 'lmm-api %s-1\n' "$LMM_TEST_OLD_CORE_VERSION" ;;
      rollback-go.pkg.tar.zst) printf 'lmm-api-go %s-1\n' "$LMM_TEST_OLD_VERSION" ;;
      *) exit 92 ;;
    esac
    ;;
  -Q)
    case $2 in
      lmm-api) printf 'lmm-api %s-1\n' "$LMM_TEST_OLD_CORE_VERSION" ;;
      lmm-api-go) printf 'lmm-api-go %s-1\n' "$(<"$LMM_TEST_SERVICE_STATE/version")" ;;
      *) exit 93 ;;
    esac
    ;;
  -Qkk) ;;
  -Rdd)
    shift
    [[ ${1:-} == --noconfirm ]] || exit 94
    shift
    [[ $# == 1 && $1 == lmm-api ]] || exit 94
    : >"$LMM_TEST_SERVICE_STATE/core.removed"
    rm -f -- "$LMM_DEPLOY_TEST_REMOVED_BINARY" "$LMM_DEPLOY_TEST_REMOVED_SELECTOR" \
      "$LMM_DEPLOY_TEST_OLD_SERVICE_FILE"
    ;;
  -U)
    shift
    [[ ${1:-} != --noconfirm ]] || shift
	if (($# == 1)); then
		[[ -f $LMM_TEST_SERVICE_STATE/core.removed ]] || exit 94
		[[ -f $LMM_TEST_SERVICE_STATE/migrate.verify ]] || exit 94
      printf '%s\n' "$LMM_TEST_NEW_VERSION" >"$LMM_TEST_SERVICE_STATE/version"
      : >"$LMM_TEST_SERVICE_STATE/new.installed"
      rm -rf -- "$LMM_DEPLOY_TEST_REMOVED_PROVIDER_ROOT"
      install -d -m0755 "$LMM_DEPLOY_TEST_PACKAGED_FRONTEND_DIR"
      printf 'new frontend\n' >"$LMM_DEPLOY_TEST_PACKAGED_FRONTEND_DIR/index.html"
      install -Dm0755 "$LMM_TEST_PROBE_SOURCE" "$LMM_DEPLOY_TEST_INSTALLED_BINARY"
    elif (($# == 2)); then
      printf '%s\n' "$LMM_TEST_OLD_VERSION" >"$LMM_TEST_SERVICE_STATE/version"
      rm -f -- "$LMM_TEST_SERVICE_STATE/new.installed"
      rm -f -- "$LMM_TEST_SERVICE_STATE/core.removed"
      install -Dm0755 "$LMM_TEST_OLD_EXECUTABLE" "$LMM_DEPLOY_TEST_REMOVED_BINARY"
      install -Dm0755 "$LMM_TEST_OLD_EXECUTABLE" "$LMM_DEPLOY_TEST_REMOVED_SELECTOR"
      install -Dm0755 "$LMM_TEST_OLD_EXECUTABLE" "$LMM_DEPLOY_TEST_REMOVED_PROVIDER_ROOT/backends/go/lmm-api"
      install -Dm0644 "$LMM_TEST_OLD_SERVICE_SOURCE" "$LMM_DEPLOY_TEST_OLD_SERVICE_FILE"
    else
      exit 94
    fi
    ;;
  *) printf 'unexpected pacman command: %s\n' "$*" >&2; exit 95 ;;
esac
EOF

cat >"$bin/lmm-api-go" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
case ${1:-} in
  version) cat "$LMM_TEST_SERVICE_STATE/version"; exit 0 ;;
  migrate) exit 0 ;;
  request) shift ;;
  *) exit 96 ;;
esac
output=''
status_file=''
request_path='/'
while (($#)); do
  case $1 in
    --output) output=$2; shift 2 ;;
    --status-file) status_file=$2; shift 2 ;;
    --path) request_path=$2; shift 2 ;;
    --base-url|--timeout|--token-file) shift 2 ;;
    --fail) shift ;;
    *) shift ;;
  esac
done
version=$(<"$LMM_TEST_SERVICE_STATE/version")
status=200
if [[ ${LMM_TEST_FAIL_NEW:-0} == 1 && $version == "$LMM_TEST_NEW_VERSION" ]]; then
  status=503
fi
case $request_path in
  /api/status) printf '{"success":true,"ready":true,"data":{"version":"%s"}}' "$version" >"$output" ;;
  /api/livez) printf '{"success":true,"live":true}' >"$output" ;;
  /v1/models) printf '{"data":[]}' >"$output" ;;
  /) cp -- "$LMM_DEPLOY_TEST_FRONTEND_ROOT/current/index.html" "$output" ;;
  *) exit 97 ;;
esac
printf '%s\n' "$status" >"$status_file"
chmod 0600 "$output" "$status_file"
((status < 400))
EOF

cat >"$bin/frontend-release" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
action=$1
shift
root=''
source=''
release=''
while (($#)); do
  case $1 in
    --root) root=$2; shift 2 ;;
    --source) source=$2; shift 2 ;;
    --release) release=$2; shift 2 ;;
    --keep) shift 2 ;;
    *) shift ;;
  esac
done
case $action in
  publish)
    install -d -m0755 "$root/releases/$release"
    cp -a -- "$source/." "$root/releases/$release/"
    ;;
  rollback) [[ -f $root/releases/$release/index.html ]] ;;
  *) exit 98 ;;
esac
ln -sfn -- "releases/$release" "$root/.current.new"
mv -Tf -- "$root/.current.new" "$root/current"
EOF
chmod 0755 "$bin"/*

export PATH="$bin:$PATH"
export LMM_DEPLOY_TEST_MODE=1
export LMM_DEPLOY_OBSERVED_HOST=arch-dmit
export LMM_DEPLOY_TEST_PROBE_ATTEMPTS=1
export LMM_TEST_NEW_VERSION=0.1.0.r233.gb57eb0977
export LMM_TEST_OLD_VERSION=0.1.0.r122.g27d4df76
export LMM_TEST_OLD_CORE_VERSION=0.1.0.r31.g3e39995.payrate2.cachefix1.txfix1

setup_case() {
  local id=$1 case_root workspace
  case_root=$tmp/$id
  export LMM_DEPLOY_TEST_WORK_ROOT=$case_root/work
  export LMM_DEPLOY_TEST_BACKUP_ROOT=$case_root/backups
  export LMM_DEPLOY_TEST_LOCK_FILE=$case_root/run/deploy.lock
  export LMM_DEPLOY_TEST_FRONTEND_ROOT=$case_root/frontend
  export LMM_DEPLOY_TEST_SYSTEMD_UNIT_ROOT=$case_root/systemd
  export LMM_DEPLOY_TEST_OLD_CONFIG_DIR=$case_root/etc/lmm-api
  export LMM_DEPLOY_TEST_NEW_CONFIG_DIR=$case_root/etc/lmm-api-go
  export LMM_DEPLOY_TEST_OLD_DROPIN_DIR=$case_root/etc/systemd/lmm-api.service.d
  export LMM_DEPLOY_TEST_NEW_DROPIN_DIR=$case_root/etc/systemd/lmm-api-go.service.d
  export LMM_DEPLOY_TEST_INSTALLED_BINARY=$case_root/usr/bin/lmm-api-go
  export LMM_DEPLOY_TEST_PACKAGED_FRONTEND_DIR=$case_root/usr/share/lmm-api-go/frontend-dist
  export LMM_DEPLOY_TEST_MIGRATION_WORKDIR=$case_root/state-old
  export LMM_DEPLOY_TEST_REMOVED_BINARY=$case_root/usr/bin/lmm-api
  export LMM_DEPLOY_TEST_REMOVED_SELECTOR=$case_root/usr/bin/lmm-api-select
  export LMM_DEPLOY_TEST_REMOVED_PROVIDER_ROOT=$case_root/usr/lib/lmm-api
  export LMM_DEPLOY_TEST_OLD_SERVICE_FILE=$case_root/usr/lib/systemd/system/lmm-api.service
  export LMM_DEPLOY_TEST_TRANSACTION_LOCK=$case_root/transaction-lock
  export LMM_TEST_SERVICE_STATE=$case_root/service-state
  export LMM_TEST_PROBE_SOURCE=$bin/lmm-api-go
  export LMM_TEST_OLD_EXECUTABLE=$bin/hostnamectl
  export LMM_TEST_OLD_SERVICE_SOURCE=$case_root/old-service.fixture

  workspace=$LMM_DEPLOY_TEST_WORK_ROOT/$id
  install -d -m0700 "$workspace/staging" "$LMM_DEPLOY_TEST_BACKUP_ROOT/$id" \
    "$LMM_DEPLOY_TEST_FRONTEND_ROOT/releases/old" "$LMM_DEPLOY_TEST_SYSTEMD_UNIT_ROOT" \
    "$LMM_DEPLOY_TEST_OLD_CONFIG_DIR" "$LMM_DEPLOY_TEST_OLD_DROPIN_DIR" \
    "$LMM_DEPLOY_TEST_MIGRATION_WORKDIR" "$LMM_TEST_SERVICE_STATE"
  printf 'format=1\ndeployment_id=%s\n' "$id" >"$workspace/.lmm-deploy-workspace"
  printf '%s\n' "$LMM_TEST_OLD_VERSION" >"$LMM_TEST_SERVICE_STATE/version"
  : >"$LMM_TEST_SERVICE_STATE/old.active"
  : >"$LMM_TEST_SERVICE_STATE/old.enabled"
  printf 'old frontend\n' >"$LMM_DEPLOY_TEST_FRONTEND_ROOT/releases/old/index.html"
  ln -s releases/old "$LMM_DEPLOY_TEST_FRONTEND_ROOT/current"
  printf 'SQL_DSN=postgres://fixture\nSESSION_SECRET=fixture\n' >"$LMM_DEPLOY_TEST_OLD_CONFIG_DIR/lmm-api.env"
  chmod 0600 "$LMM_DEPLOY_TEST_OLD_CONFIG_DIR/lmm-api.env"
  printf 'LMM_API_BACKEND=go\n' >"$LMM_DEPLOY_TEST_OLD_CONFIG_DIR/backend.conf"
  printf '[Service]\nMemoryHigh=224M\n' >"$LMM_DEPLOY_TEST_OLD_DROPIN_DIR/50-memory.conf"
  printf '[Service]\nExecStart=/usr/bin/lmm-api\n' >"$LMM_TEST_OLD_SERVICE_SOURCE"
  install -Dm0755 "$LMM_TEST_OLD_EXECUTABLE" "$LMM_DEPLOY_TEST_REMOVED_BINARY"
  install -Dm0755 "$LMM_TEST_OLD_EXECUTABLE" "$LMM_DEPLOY_TEST_REMOVED_SELECTOR"
  install -Dm0755 "$LMM_TEST_OLD_EXECUTABLE" "$LMM_DEPLOY_TEST_REMOVED_PROVIDER_ROOT/backends/go/lmm-api"
  install -Dm0644 "$LMM_TEST_OLD_SERVICE_SOURCE" "$LMM_DEPLOY_TEST_OLD_SERVICE_FILE"
  tar -C "$case_root/etc" -cf "$LMM_DEPLOY_TEST_BACKUP_ROOT/$id/configuration.archive" lmm-api
  for file in candidate.pkg.tar.zst rollback-core.pkg.tar.zst rollback-go.pkg.tar.zst; do
    printf '%s\n' "$file" >"$workspace/staging/$file"
  done
  install -Dm0755 "$bin/lmm-api-go" "$workspace/staging/lmm-api-go"
  install -Dm0755 "$bin/frontend-release" "$workspace/staging/frontend-release.sh"
  install -Dm0755 "$here/activate-go-release.sh" "$workspace/staging/activate-go-release.sh"
  CASE_WORKSPACE=$workspace
}

activate_case() {
  local workspace=$1 id candidate
  id=${workspace##*/}
  candidate=$workspace/staging/candidate.pkg.tar.zst
  local core=$workspace/staging/rollback-core.pkg.tar.zst go=$workspace/staging/rollback-go.pkg.tar.zst
  local probe=$workspace/staging/lmm-api-go frontend_sha
  frontend_sha=$(printf 'new frontend\n' | sha256sum | awk '{print $1}')
  "$workspace/staging/activate-go-release.sh" activate \
    --workspace "$workspace" \
    --package "$candidate" --package-sha256 "$(sha256sum "$candidate" | awk '{print $1}')" \
    --rollback-core-package "$core" --rollback-core-sha256 "$(sha256sum "$core" | awk '{print $1}')" \
    --rollback-go-package "$go" --rollback-go-sha256 "$(sha256sum "$go" | awk '{print $1}')" \
    --probe-binary "$probe" --probe-binary-sha256 "$(sha256sum "$probe" | awk '{print $1}')" \
    --expected-version "$LMM_TEST_NEW_VERSION" --old-version "$LMM_TEST_OLD_VERSION" \
    --frontend-index-sha256 "$frontend_sha" \
    --frontend-release-script "$workspace/staging/frontend-release.sh" \
    --backup-dir "$LMM_DEPLOY_TEST_BACKUP_ROOT/$id" --rollback-seconds 600
}

CASE_WORKSPACE=''
setup_case insecure-work-root
insecure_workspace=$CASE_WORKSPACE
chmod 0777 "$LMM_DEPLOY_TEST_WORK_ROOT"
if activate_case "$insecure_workspace" >"$tmp/activate-insecure.out" 2>"$tmp/activate-insecure.err"; then
  fail 'activation accepted a service-writable deployment root'
fi
grep -Fq 'deployment path component is not root-controlled' "$tmp/activate-insecure.err" || \
  fail 'activation did not identify the unsafe deployment root'

setup_case confirm-case
confirm_workspace=$CASE_WORKSPACE
activate_case "$confirm_workspace" >"$tmp/activate-confirm.out"
grep -Fq 'AWAITING_CONFIRMATION' "$confirm_workspace/state/status" || fail 'activation did not await confirmation'
[[ -f $LMM_TEST_SERVICE_STATE/core.removed ]] || fail 'activation did not explicitly remove the old core package'
[[ -f $LMM_TEST_SERVICE_STATE/migrate.apply && -f $LMM_TEST_SERVICE_STATE/migrate.verify ]] || \
  fail 'activation did not apply and verify the candidate migration before package replacement'
grep -Fqx -- '--setenv=PGOPTIONS=-c search_path=lmm_prod_contract' \
  "$LMM_TEST_SERVICE_STATE/migrate.apply.args" || fail 'migration did not use the captured production schema'
grep -Fqx 'database_schema=lmm_prod_contract' "$confirm_workspace/state/deployment.env" || \
  fail 'deployment manifest did not freeze the production schema'
grep -Fqx 'PGOPTIONS="-c search_path=lmm_prod_contract"' \
  "$LMM_DEPLOY_TEST_NEW_CONFIG_DIR/lmm-api-go.env" || fail 'new service config did not preserve the production schema'
[[ $(readlink "$LMM_DEPLOY_TEST_FRONTEND_ROOT/current") == "releases/$LMM_TEST_NEW_VERSION" ]] || fail 'new frontend was not published'
[[ -f $LMM_TEST_SERVICE_STATE/timer.active ]] || fail 'rollback timer was not armed'
"$confirm_workspace/staging/activate-go-release.sh" confirm --workspace "$confirm_workspace" >"$tmp/confirm.out"
grep -Fq 'CONFIRMED' "$confirm_workspace/state/status" || fail 'confirmation state was not recorded'
[[ ! -e $LMM_TEST_SERVICE_STATE/timer.active ]] || fail 'confirmation did not stop the timer'
[[ ! -e $confirm_workspace/state/probe-token ]] || fail 'confirmation retained the probe token'

setup_case rollback-case
rollback_workspace=$CASE_WORKSPACE
export LMM_TEST_FAIL_NEW=1
if activate_case "$rollback_workspace" >"$tmp/activate-rollback.out" 2>"$tmp/activate-rollback.err"; then
  fail 'injected post-install probe failure unexpectedly succeeded'
fi
unset LMM_TEST_FAIL_NEW
grep -Fq 'ROLLED_BACK' "$rollback_workspace/state/status" || fail 'probe failure did not roll back'
[[ $(readlink "$LMM_DEPLOY_TEST_FRONTEND_ROOT/current") == releases/old ]] || fail 'rollback did not restore the frontend'
[[ -x $LMM_DEPLOY_TEST_REMOVED_BINARY && -f $LMM_DEPLOY_TEST_OLD_SERVICE_FILE ]] || fail 'rollback did not restore old package paths'
[[ -f $LMM_TEST_SERVICE_STATE/old.active && ! -e $LMM_TEST_SERVICE_STATE/new.active ]] || fail 'rollback did not restore the old service state'
[[ ! -e $LMM_TEST_SERVICE_STATE/timer.active ]] || fail 'rollback left its timer active'

printf 'Go rollback and confirmation state machine verified\n'
