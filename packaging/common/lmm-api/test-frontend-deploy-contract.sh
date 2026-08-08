#!/usr/bin/env bash
set -Eeuo pipefail

here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
repo=$(cd -- "$here/../../.." && pwd -P)
cli="$here/lmm-api-launcher"
launcher="$here/lmm-api-launcher"
fail(){ printf 'frontend-deploy-contract: %s\n' "$*" >&2; exit 1; }
expect_fail(){ if "$@" >"$tmp/out" 2>"$tmp/err"; then fail "expected failure: $*"; fi; }

tmp=$(mktemp -d "$repo/.lmm-frontend-deploy-contract.XXXXXXXX")
trap 'rm -rf -- "$tmp"' EXIT
mkdir -p "$tmp/bin" "$tmp/frontend/index" "$tmp/work"
revision=$(git -C "$repo" rev-parse HEAD)
printf '<!doctype html><script src="static/app.js"></script>\n' >"$tmp/frontend/index/index.html"
mkdir -p "$tmp/frontend/index/static"
printf 'console.log("frontend-contract")\n' >"$tmp/frontend/index/static/app.js"
core="$tmp/lmm-api-git-0.1.2.r1.gcontract-1-any.pkg.tar.zst"
printf 'core-package-fixture\n' >"$core"

cat >"$tmp/bin/pacman" <<'EOF'
#!/usr/bin/env bash
case $1 in
  -Qp) printf '%s 0.1.2.r1.gcontract-1\n' "${FRONTEND_CONTRACT_PACKAGE_NAME:-lmm-api-git}" ;;
  -Qip) printf 'Architecture : any\n' ;;
  *) exit 2 ;;
esac
EOF
cat >"$tmp/bin/bsdtar" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
case $1 in
  -xOf)
    case ${3:-} in
      usr/bin/lmm-api) printf '%s\n' 'readonly LMM_API_DEPLOY_PROTOCOL_MIN=1' 'readonly LMM_API_DEPLOY_PROTOCOL_MAX=1' ;;
      *) printf '%s\n' "${FRONTEND_CONTRACT_REVISION:?}" ;;
    esac
    ;;
  -xf)
    destination=''
    while (($#)); do case $1 in -C) destination=$2; shift 2;; *) shift;; esac; done
    mkdir -p "$destination/usr/share/lmm-api/frontend-dist"
    cp -R -- "${FRONTEND_CONTRACT_DIST:?}/." "$destination/usr/share/lmm-api/frontend-dist/"
    ;;
  *) exit 2 ;;
esac
EOF
cat >"$tmp/bin/ssh" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
printf '%s\n' "$*" >>"${FRONTEND_CONTRACT_SSH_LOG:?}"
if [[ $* == *' bash -s -- '* ]]; then
  script=$(cat)
  if [[ $script == *'make_copy()'* ]]; then
    printf 'target_verified=true\nfrontend_release=old-release\ncurrent_backend_sha256=%s\n' \
      "${FRONTEND_CONTRACT_BACKEND_SHA:?}"
  fi
fi
EOF
cat >"$tmp/bin/scp" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
printf '%s\n' "$*" >>"${FRONTEND_CONTRACT_SCP_LOG:?}"
args=("$@")
destination=${args[${#args[@]}-1]}
role=''
for argument in "${args[@]}"; do
  if [[ $argument == *'/deploy-backups/'* || $argument == *'/staging/backup-target/'* ]]; then
    printf 'plaintext target backup transfer attempted: %s\n' "$argument" >&2
    exit 90
  fi
done
case $destination in
  "${FRONTEND_CONTRACT_CONTROLLER_OUTPUT:-__unset__}"|"${FRONTEND_CONTRACT_CONTROLLER_OUTPUT:-__unset__}"/) \
    role=controller; destination=${destination%/} ;;
  */staging/backup-off-host/) role=off-host; destination=${destination%/} ;;
esac
[[ -n $role ]] || exit 0
mkdir -p -m0700 -- "$destination"
encrypted=false
[[ $role == controller || $role == off-host ]] && encrypted=true
for kind in application frontend configuration database; do
  suffix=archive
  [[ $encrypted == true && ( $kind == configuration || $kind == database ) ]] && suffix=age
  printf '%s-%s\n' "$role" "$kind" >"$destination/$kind.$suffix"
  chmod 0600 "$destination/$kind.$suffix"
done
created=$(date -u +%FT%TZ)
{
  printf 'format=1\ncreated_at_utc=%s\ndeployment_id=%s\ncopy_role=%s\n' \
    "$created" "$FRONTEND_CONTRACT_DEPLOYMENT_ID" "$role"
  printf 'deployment_role=production\nverified_host=arch-dmit\nrelease_id=%s\n' \
    "$FRONTEND_CONTRACT_DEPLOYMENT_ID"
  printf 'artifact_sha256=%s\ngit_revision=%s\ndatabase_engine=postgres\n' \
    "$FRONTEND_CONTRACT_FRONTEND_DIGEST" "$FRONTEND_CONTRACT_REVISION"
  printf 'core_sha256=%s\nbackend_sha256=%s\n' \
    "$FRONTEND_CONTRACT_CORE_SHA" "$FRONTEND_CONTRACT_BACKEND_SHA"
  printf 'service_state=active\nfrontend_release=old-release\n'
  for kind in application frontend configuration database; do
    suffix=archive
    [[ $encrypted == true && ( $kind == configuration || $kind == database ) ]] && suffix=age
    file="$destination/$kind.$suffix"
    printf '%s_file=%s.%s\n%s_size=%s\n%s_mode=600\n%s_mtime_utc=%s\n' \
      "$kind" "$kind" "$suffix" "$kind" "$(stat -c %s "$file")" "$kind" "$kind" "$created"
    [[ $kind == configuration || $kind == database ]] && \
      printf '%s_encrypted=%s\n' "$kind" "$encrypted"
  done
} >"$destination/manifest.env"
sha256sum "$destination/application.archive" "$destination/frontend.archive" \
  "$destination/configuration.$([[ $encrypted == true ]] && printf age || printf archive)" \
  "$destination/database.$([[ $encrypted == true ]] && printf age || printf archive)" | \
  sed "s|$destination/||" >"$destination/SHA256SUMS"
chmod 0600 "$destination/manifest.env" "$destination/SHA256SUMS"
EOF
chmod 0700 "$tmp/bin/pacman" "$tmp/bin/bsdtar" "$tmp/bin/ssh" "$tmp/bin/scp"
printf 'Host archczy\n  HostName 127.0.0.1\n' >"$tmp/ssh-config"
chmod 0600 "$tmp/ssh-config"
export PATH="$tmp/bin:$PATH" LMM_DEPLOY_TEST_MODE=1
export FRONTEND_CONTRACT_REVISION="$revision" FRONTEND_CONTRACT_DIST="$tmp/frontend/index"
export LMM_API_DEPLOY_SSH_CONFIG="$tmp/ssh-config"
export FRONTEND_CONTRACT_SSH_LOG="$tmp/ssh.log" FRONTEND_CONTRACT_SCP_LOG="$tmp/scp.log"

base=(deploy production --frontend-only --host ArchDmit --deployment-id frontend-contract --workspace "$tmp/work")
"$cli" "${base[@]}" --execute-remote --jump-host archczy preflight >/dev/null || \
  fail 'frontend-only remote preflight incorrectly required backend credentials or route evidence'
expect_fail "$cli" "${base[@]}" --backend rs preflight
grep -Fq -- '--frontend-only cannot be combined with --backend' "$tmp/err" || fail 'backend conflict did not fail closed'

"$cli" "${base[@]}" inspect >/dev/null
"$cli" "${base[@]}" build >/dev/null
"$cli" "${base[@]}" --core-package "$core" package >/dev/null
identity="$tmp/work/frontend-contract/frontend.identity"
grep -Fq 'core_package=lmm-api-git ' "$identity" || fail 'exact lmm-api-git identity was not recorded'
digest=$(sed -n 's/^frontend_digest=//p' "$identity")
[[ $digest =~ ^[0-9a-f]{64}$ ]] || fail 'frontend digest was not recorded'

wrong_name_base=(deploy production --frontend-only --host ArchDmit --deployment-id wrong-name \
  --workspace "$tmp/work-wrong-name")
"$cli" "${wrong_name_base[@]}" inspect >/dev/null
"$cli" "${wrong_name_base[@]}" build >/dev/null
export FRONTEND_CONTRACT_PACKAGE_NAME=lmm-api-rs-git
expect_fail "$cli" "${wrong_name_base[@]}" --core-package "$core" package
unset FRONTEND_CONTRACT_PACKAGE_NAME
grep -Fq 'frontend-only package must be exact lmm-api-bin or lmm-api-git' "$tmp/err" || \
  fail 'wrong core package name did not fail closed'

wrong_revision_base=(deploy production --frontend-only --host ArchDmit --deployment-id wrong-revision \
  --workspace "$tmp/work-wrong-revision")
"$cli" "${wrong_revision_base[@]}" inspect >/dev/null
"$cli" "${wrong_revision_base[@]}" build >/dev/null
export FRONTEND_CONTRACT_REVISION=deadbeef
expect_fail "$cli" "${wrong_revision_base[@]}" --core-package "$core" package
export FRONTEND_CONTRACT_REVISION=$revision
grep -Fq 'core package revision disagrees with the expected revision' "$tmp/err" || \
  fail 'wrong embedded revision did not fail closed'

tamper_base=(deploy production --frontend-only --host ArchDmit --deployment-id tampered-core \
  --workspace "$tmp/work-tampered")
"$cli" "${tamper_base[@]}" inspect >/dev/null
"$cli" "${tamper_base[@]}" build >/dev/null
"$cli" "${tamper_base[@]}" --core-package "$core" package >/dev/null
printf 'tamper\n' >>"$tmp/work-tampered/tampered-core/core.pkg"
expect_fail "$cli" "${tamper_base[@]}" backup
grep -Fq 'staged frontend identity changed after initial validation' "$tmp/err" || \
  fail 'changed core package digest did not fail closed'

backend_sha=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
core_sha=$(sha256sum "$tmp/work/frontend-contract/core.pkg" | awk '{print $1}')
for role in target controller off-host; do
  directory="$tmp/backups/$role"
  mkdir -p "$directory"
  printf 'application\n' >"$directory/application.archive"
  printf 'frontend\n' >"$directory/frontend.archive"
  if [[ $role == target ]]; then
    printf 'configuration\n' >"$directory/configuration.archive"
    printf 'database\n' >"$directory/database.archive"
    configuration=configuration.archive; database=database.archive; encrypted=false
  else
    printf 'encrypted-configuration\n' >"$directory/configuration.age"
    printf 'encrypted-database\n' >"$directory/database.age"
    configuration=configuration.age; database=database.age; encrypted=true
  fi
  {
    printf 'format=1\ndeployment_id=frontend-contract\ncopy_role=%s\ndeployment_role=production\n' "$role"
    printf 'verified_host=arch-dmit\nrelease_id=frontend-contract\ndatabase_engine=postgres\n'
    printf 'artifact_sha256=%s\ncore_sha256=%s\nbackend_sha256=%s\ngit_revision=%s\n' "$digest" "$core_sha" "$backend_sha" "$revision"
    printf 'configuration_encrypted=%s\ndatabase_encrypted=%s\n' "$encrypted" "$encrypted"
  } >"$directory/manifest.env"
  (cd "$directory" && sha256sum application.archive frontend.archive "$configuration" "$database" >SHA256SUMS)
done
backup_args=(--target-backup "$tmp/backups/target" --controller-backup "$tmp/backups/controller" --offhost-backup "$tmp/backups/off-host")
"$cli" "${base[@]}" "${backup_args[@]}" backup >/dev/null
"$cli" "${base[@]}" watchdog >/dev/null
embedded="$tmp/work/frontend-contract/frontend-activator"
bash -n "$embedded" || fail 'embedded target activator has syntax errors'
grep -Fqx 'Persistent=true' "$embedded" || fail 'embedded watchdog is not persistent'
# shellcheck disable=SC2016 # Match the literal embedded deadline expression.
grep -Fq '$(date +%s)+600' "$embedded" || fail 'embedded watchdog does not use a 600-second deadline'
grep -Fq 'AWAITING_CONFIRMATION' "$embedded" || fail 'frontend switch does not await manual confirmation'
grep -Fq 'frontend link or digest mismatch' "$embedded" || fail 'confirmation lacks exact frontend verification'
# shellcheck disable=SC2016 # Match the literal embedded package variable.
grep -Fq 'pacman -U --noconfirm "$core"' "$embedded" || \
  fail 'frontend switch does not install the validated core AUR package'
grep -Fq 'rollback-core.pkg' "$embedded" || fail 'frontend rollback does not capture the exact prior core package'
# shellcheck disable=SC2016 # Match the literal embedded frontend variable.
grep -Fq 'publish "$FRONTEND_SOURCE"' "$embedded" || \
  fail 'frontend identity is not published from the installed core package'
if grep -Eq 'systemctl[[:space:]]+restart[[:space:]]+(["$]*SERVICE|lmm-api)' "$embedded"; then
  fail 'embedded frontend activator restarts the Go backend'
fi
if grep -Eq 'resolve_deploy_helper|deploy/frontend-release|deploy/production' "$embedded"; then
  fail 'embedded frontend activator depends on a deploy-directory helper'
fi
if grep -Fq 'deploy/production/' "$launcher"; then
  fail 'launcher retains a source-tree deploy fallback'
fi
for pkgbuild in "$repo/packaging/aur/lmm-api-git/PKGBUILD" \
  "$repo/packaging/aur/lmm-api-bin/PKGBUILD"; do
  # shellcheck disable=SC2016 # Match the literal PKGBUILD destination expression.
  grep -Fq '/usr/bin/lmm-api' "$pkgbuild" || \
    fail "core package does not install the canonical CLI: $pkgbuild"
  if grep -Eq 'activate-rust-release|create-backup-copy|prepare-production-backup|promote-production-backups|frontend-release\.sh|inspect-state\.sh|verify-backup-set\.sh' \
    "$pkgbuild"; then
    fail "core package still ships a deployment helper payload: $pkgbuild"
  fi
done
frontend_remote=$(sed -n '/^execute_remote_frontend_switch()/,/^}/p' "$cli")
if grep -Eq 'resolve_deploy_helper|frontend-release\.sh|activate-frontend-release' <<<"$frontend_remote"; then
  fail 'frontend remote switch resolves a deploy-directory helper'
fi

frontend_backup=$(sed -n '/^create_and_promote_frontend_backups()/,/^}/p' "$cli")
if grep -Eq 'resolve_deploy_helper|prepare-production-backup|create-backup-copy|promote-production-backups' \
  <<<"$frontend_backup"; then
  fail 'frontend backup creation resolves or copies a deploy-directory helper'
fi

# The built-in backup path creates role-bound target/controller/off-host copies
# and verifies package, revision, backend, encryption, and digest identities.
created_id=frontend-created
created_work="$tmp/work-created"
created_controller="$tmp/created-backups/controller"
created_target="$tmp/created-backups/target"
created_offhost="$tmp/created-backups/off-host"
created_base=(deploy production --frontend-only --host ArchDmit --deployment-id "$created_id" \
  --workspace "$created_work")
"$cli" "${created_base[@]}" inspect >/dev/null
"$cli" "${created_base[@]}" build >/dev/null
"$cli" "${created_base[@]}" --core-package "$core" package >/dev/null
created_identity="$created_work/$created_id/frontend.identity"
export FRONTEND_CONTRACT_DEPLOYMENT_ID=$created_id
export FRONTEND_CONTRACT_FRONTEND_DIGEST
FRONTEND_CONTRACT_FRONTEND_DIGEST=$(sed -n 's/^frontend_digest=//p' "$created_identity")
export FRONTEND_CONTRACT_CORE_SHA
FRONTEND_CONTRACT_CORE_SHA=$(sha256sum "$created_work/$created_id/core.pkg" | awk '{print $1}')
export FRONTEND_CONTRACT_BACKEND_SHA=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
export LMM_DEPLOY_TEST_FRONTEND_BACKEND_SHA256=$FRONTEND_CONTRACT_BACKEND_SHA
export FRONTEND_CONTRACT_CONTROLLER_OUTPUT=$created_controller
printf 'age1contractrecipient\n' >"$tmp/age-recipient"
chmod 0600 "$tmp/age-recipient"
: >"$FRONTEND_CONTRACT_SSH_LOG"
: >"$FRONTEND_CONTRACT_SCP_LOG"
"$cli" "${created_base[@]}" --jump-host archczy --create-backups \
  --age-recipient-file "$tmp/age-recipient" --target-backup "$created_target" \
  --controller-backup "$created_controller" --offhost-backup "$created_offhost" backup >/dev/null
for pair in "controller:$created_controller" "off-host:$created_work/$created_id/staging/backup-off-host"; do
  role=${pair%%:*}; directory=${pair#*:}
  grep -Fqx "copy_role=$role" "$directory/manifest.env" || fail "created $role role marker is missing"
  (cd "$directory" && sha256sum -c SHA256SUMS >/dev/null) || fail "created $role checksum failed"
done
[[ -f $created_controller/configuration.age && -f $created_controller/database.age ]] || \
  fail 'created controller copy did not encrypt secrets'
[[ ! -e $created_work/$created_id/staging/backup-target ]] || \
  fail 'plaintext target backup was mirrored into the controller workspace'
if find "$created_work/$created_id" "$created_controller" -type f \
  \( -name configuration.archive -o -name database.archive \) -print -quit | grep -q .; then
  fail 'plaintext configuration or database archive escaped the target'
fi
grep -Fq -- '-J archczy -p 222 root@45.59.187.63' "$FRONTEND_CONTRACT_SSH_LOG" || \
  fail 'built-in backup did not use the controlled target transport'
if grep -Eq 'deploy/production|frontend-release\.sh' "$FRONTEND_CONTRACT_SCP_LOG"; then
  fail 'built-in backup copied a source-tree deployment helper'
fi
if grep -Eq '/deploy-backups/|backup-target' "$FRONTEND_CONTRACT_SCP_LOG"; then
  fail 'target plaintext backup was transferred through scp'
fi

# Execute the embedded canonical runtime through its rendered watchdog command.
# This keeps lifecycle coverage attached to the shipped CLI rather than a
# source-tree activation helper.
runtime_bin="$tmp/runtime-bin"
runtime_root="$tmp/runtime-work"
runtime_frontend="$tmp/runtime-frontend"
runtime_backups="$tmp/runtime-backups"
runtime_systemd="$tmp/runtime-systemd"
runtime_cache="$tmp/runtime-cache"
runtime_lock="$tmp/runtime-transaction.lock"
runtime_cli="$tmp/runtime-installed-lmm-api"
mkdir -p "$runtime_bin" "$runtime_root" "$runtime_frontend/releases/old" \
  "$runtime_backups" "$runtime_systemd" "$runtime_cache"
cp -- "$cli" "$runtime_cli"
chmod 0700 "$runtime_cli"
printf '<!doctype html><p>old</p>\n' >"$runtime_frontend/releases/old/index.html"
ln -s releases/old "$runtime_frontend/current"
printf 'old-backend\n' >"$tmp/runtime-go-backend"
printf 'LMM_API_BACKEND=go\n' >"$tmp/runtime-backend.conf"
printf 'SQL_DSN=postgresql://runtime-fixture\n' >"$tmp/runtime-lmm-api.env"
printf 'old-core\n' >"$runtime_cache/lmm-api-bin-0.1.1-1-any.pkg.tar.zst"

cat >"$runtime_bin/pacman" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
state=${FRONTEND_RUNTIME_STATE:?}
record_for_archive() {
  case ${1##*/} in
    core.pkg) printf 'lmm-api-git 0.1.2.r1.gcontract-1\n' ;;
    lmm-api-bin-0.1.1-1-any.pkg.tar.zst|rollback-core.pkg) printf 'lmm-api-bin 0.1.1-1\n' ;;
    *) exit 1 ;;
  esac
}
case $1 in
  -Qp) record_for_archive "$2" ;;
  -Qip) printf 'Architecture : any\n' ;;
  -Qqo)
    path=$2; [[ $path == -- ]] && path=$3
    case $path in
      "$FRONTEND_RUNTIME_CLI") printf 'lmm-api-bin\n' ;;
      "$FRONTEND_RUNTIME_BACKEND") printf 'lmm-api-go-bin\n' ;;
      *) exit 1 ;;
    esac
    ;;
  -Q)
    case $2 in
      lmm-api-bin|lmm-api-git) cat "$state.core" ;;
      lmm-api-go-bin) printf 'lmm-api-go-bin 0.1.1-1\n' ;;
      *) exit 1 ;;
    esac
    ;;
  -Qi) printf 'Name : %s\nArchitecture : any\n' "$2" ;;
  -Qkk) [[ ${FRONTEND_RUNTIME_QKK_FAIL:-0} == 0 ]] ;;
  -U)
    if [[ -f $state.fail-next ]]; then rm -f -- "$state.fail-next"; exit 93; fi
    archive=${*: -1}
    record_for_archive "$archive" >"$state.core"
    printf '%s\n' "$archive" >>"$state.installs"
    ;;
  *) exit 2 ;;
esac
EOF
cat >"$runtime_bin/bsdtar" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
[[ $1 == -xOf ]] || exit 2
case ${3:-} in
  usr/bin/lmm-api)
    printf 'readonly LMM_API_DEPLOY_PROTOCOL_MIN=%s\nreadonly LMM_API_DEPLOY_PROTOCOL_MAX=%s\n' \
      "${FRONTEND_RUNTIME_PROTOCOL_MIN:-1}" "${FRONTEND_RUNTIME_PROTOCOL_MAX:-1}"
    ;;
  usr/share/doc/lmm-api-git/REVISION) printf '%s\n' "${FRONTEND_RUNTIME_REVISION:?}" ;;
  *) exit 2 ;;
esac
EOF
cat >"$runtime_bin/systemctl" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
state=${FRONTEND_RUNTIME_SYSTEMCTL_STATE:?}
printf '%s\n' "$*" >>"$state.log"
case $1 in
  enable) : >"$state.enabled"; : >"$state.active" ;;
  disable) rm -f -- "$state.enabled" "$state.active" ;;
  is-enabled) [[ ${FRONTEND_RUNTIME_TIMER_FAIL:-0} == 0 && -f $state.enabled ]] ;;
  is-active)
    if [[ $* == *rollback-* ]]; then [[ -f $state.active ]]; else exit 0; fi
    ;;
  show) printf '4242\n' ;;
  daemon-reload) exit 0 ;;
  *) exit 0 ;;
esac
EOF
chmod 0700 "$runtime_bin"/*
printf 'lmm-api-bin 0.1.1-1\n' >"$tmp/runtime-pacman.core"
: >"$tmp/runtime-pacman.installs"

runtime_env=(env PATH="$runtime_bin:$PATH" LMM_DEPLOY_TEST_MODE=1 LMM_DEPLOY_OBSERVED_HOST=arch-dmit \
  LMM_DEPLOY_TEST_INSTALLED_CLI="$runtime_cli" LMM_API_DEPLOY_WORKSPACE_ROOT="$runtime_root" \
  LMM_DEPLOY_TEST_FRONTEND_ROOT="$runtime_frontend" LMM_DEPLOY_TEST_FRONTEND_SOURCE="$tmp/frontend/index" \
  LMM_DEPLOY_TEST_BACKEND_CONFIG="$tmp/runtime-backend.conf" LMM_DEPLOY_TEST_ENV_CONFIG="$tmp/runtime-lmm-api.env" \
  LMM_DEPLOY_TEST_GO_BACKEND_PATH="$tmp/runtime-go-backend" LMM_DEPLOY_TEST_PACMAN_CACHE="$runtime_cache" \
  LMM_DEPLOY_TEST_STAGING_ROOT="$runtime_root" LMM_DEPLOY_TEST_BACKUP_ROOT="$runtime_backups" \
  LMM_DEPLOY_TEST_TRANSACTION_LOCK="$runtime_lock" LMM_DEPLOY_TEST_SYSTEMD_UNIT_DIR="$runtime_systemd" \
  FRONTEND_RUNTIME_STATE="$tmp/runtime-pacman" FRONTEND_RUNTIME_CLI="$runtime_cli" \
  FRONTEND_RUNTIME_BACKEND="$tmp/runtime-go-backend" FRONTEND_RUNTIME_REVISION="$revision" \
  FRONTEND_RUNTIME_SYSTEMCTL_STATE="$tmp/runtime-systemctl")

unsafe_cli="$tmp/runtime unsafe cli"
cp -- "$runtime_cli" "$unsafe_cli"
chmod 0700 "$unsafe_cli"
expect_fail env LMM_DEPLOY_TEST_MODE=1 LMM_DEPLOY_TEST_INSTALLED_CLI="$unsafe_cli" "$embedded" prepare
grep -Fq 'test installed CLI path is unsafe' "$tmp/err" || fail 'unsafe test CLI path was not rejected'
ln -s "$runtime_cli" "$tmp/runtime-cli-link"
expect_fail env LMM_DEPLOY_TEST_MODE=1 LMM_DEPLOY_TEST_INSTALLED_CLI="$tmp/runtime-cli-link" "$embedded" prepare
grep -Fq 'test installed CLI path is unsafe' "$tmp/err" || fail 'symlinked test CLI path was not rejected'
writable_cli="$tmp/runtime-writable-cli"
cp -- "$runtime_cli" "$writable_cli"
chmod 0722 "$writable_cli"
expect_fail env LMM_DEPLOY_TEST_MODE=1 LMM_DEPLOY_TEST_INSTALLED_CLI="$writable_cli" "$embedded" prepare
grep -Fq 'test installed CLI path is group/world writable' "$tmp/err" || \
  fail 'group/world-writable test CLI was not rejected'

setup_runtime_transaction() {
  runtime_id=$1
  runtime_release=$2
  runtime_workspace="$runtime_root/$runtime_id"
  runtime_backup="$runtime_backups/$runtime_id"
  mkdir -p "$runtime_workspace/state" "$runtime_workspace/staging" "$runtime_backup" "$tmp/runtime-config/lmm-api"
  chmod 0700 "$runtime_root" "$runtime_workspace" "$runtime_workspace/state" "$runtime_workspace/staging"
  cp -- "$embedded" "$runtime_workspace/staging/frontend-activator"
  chmod 0700 "$runtime_workspace/staging/frontend-activator"
  printf 'runtime-core\n' >"$runtime_workspace/staging/core.pkg"
  runtime_core_sha=$(sha256sum "$runtime_workspace/staging/core.pkg" | awk '{print $1}')
  printf 'format=1\ndeployment_id=%s\nrole=target\nworkspace=%s\n' "$runtime_id" "$runtime_workspace" \
    >"$runtime_workspace/.lmm-deploy-workspace"
  chmod 0600 "$runtime_workspace/.lmm-deploy-workspace"
  cp -- "$tmp/runtime-backend.conf" "$tmp/runtime-config/lmm-api/backend.conf"
  cp -- "$tmp/runtime-lmm-api.env" "$tmp/runtime-config/lmm-api/lmm-api.env"
  tar -cf "$runtime_backup/configuration.tar" -C "$tmp/runtime-config" lmm-api
  printf 'application\n' >"$runtime_backup/application.archive"
  {
    printf 'copy_role=target\ndatabase_engine=postgres\nconfiguration_file=configuration.tar\n'
    printf 'artifact_sha256=%s\ncore_sha256=%s\nbackend_sha256=%s\n' \
      "$digest" "$runtime_core_sha" "$(sha256sum "$tmp/runtime-go-backend" | awk '{print $1}')"
  } >"$runtime_backup/manifest.env"
  (cd "$runtime_backup" && sha256sum configuration.tar application.archive >SHA256SUMS)
  runtime_guard="$runtime_workspace/state/rollback.guard"
  runtime_status="$runtime_workspace/staging/status"
  runtime_args=(--workspace "$runtime_workspace" --guard "$runtime_guard" --target-backup "$runtime_backup" \
    --core-package "$runtime_workspace/staging/core.pkg" --core-sha256 "$runtime_core_sha" \
    --expected-release "$runtime_release" --expected-revision "$revision" --frontend-digest "$digest" \
    --status-file "$runtime_status")
}

setup_runtime_transaction protocol-fail protocol-fail
expect_fail "${runtime_env[@]}" FRONTEND_RUNTIME_PROTOCOL_MIN=2 FRONTEND_RUNTIME_PROTOCOL_MAX=2 \
  "$runtime_workspace/staging/frontend-activator" prepare "${runtime_args[@]}"
grep -Fq 'deployment protocols are incompatible' "$tmp/err" || fail 'incompatible deploy protocols were accepted'
[[ ! -e $runtime_lock && ! -e $runtime_guard ]] || fail 'protocol failure retained deployment ownership'

setup_runtime_transaction prepare-cleanup prepare-cleanup
expect_fail "${runtime_env[@]}" FRONTEND_RUNTIME_QKK_FAIL=1 \
  "$runtime_workspace/staging/frontend-activator" prepare "${runtime_args[@]}"
[[ ! -e $runtime_lock && ! -e $runtime_guard && ! -e $runtime_status ]] || \
  fail 'failed prepare retained ownership or state'

"${runtime_env[@]}" "$runtime_workspace/staging/frontend-activator" prepare "${runtime_args[@]}"
[[ $(sed -n 's/^status=//p' "$runtime_guard") == PREPARED ]] || fail 'prepare did not persist PREPARED'
runtime_sha=$(sha256sum "$runtime_workspace/staging/frontend-activator" | awk '{print $1}')
grep -Fqx "watchdog_runtime_sha256=$runtime_sha" "$runtime_guard" || fail 'guard omitted exact watchdog checksum'
expect_fail "${runtime_env[@]}" FRONTEND_RUNTIME_TIMER_FAIL=1 \
  "$runtime_workspace/staging/frontend-activator" switch "${runtime_args[@]}"
[[ ! -e $runtime_lock && ! -e $runtime_guard && ! -e $runtime_status ]] || \
  fail 'failed PREPARED switch did not clean transaction state'

"${runtime_env[@]}" "$runtime_workspace/staging/frontend-activator" prepare "${runtime_args[@]}"
"${runtime_env[@]}" "$runtime_workspace/staging/frontend-activator" switch "${runtime_args[@]}"
[[ $(<"$runtime_status") == AWAITING_CONFIRMATION\ * ]] || fail 'switch did not await confirmation'
start=$(sed -n 's/^ExecStart=//p' "$runtime_systemd/lmm-api-frontend-rollback-$runtime_id.service")
[[ $start == "$runtime_cli deploy internal watchdog --deployment-id $runtime_id" ]] || \
  fail 'watchdog ExecStart did not use the validated installed CLI'
cp -- "$runtime_workspace/staging/frontend-activator" "$tmp/runtime-activator-clean"
printf '# tampered\n' >>"$runtime_workspace/staging/frontend-activator"
expect_fail "${runtime_env[@]}" "$runtime_cli" deploy internal watchdog --deployment-id "$runtime_id"
grep -Fq 'watchdog runtime checksum mismatch' "$tmp/err" || fail 'watchdog accepted a changed runtime'
cp -- "$tmp/runtime-activator-clean" "$runtime_workspace/staging/frontend-activator"
chmod 0700 "$runtime_workspace/staging/frontend-activator"

: >"$tmp/runtime-pacman.fail-next"
expect_fail "${runtime_env[@]}" "$runtime_cli" deploy internal watchdog --deployment-id "$runtime_id"
[[ $(sed -n 's/^status=//p' "$runtime_guard") == ROLLING_BACK && -d $runtime_lock ]] || \
  fail 'failed rollback did not retain retryable ownership'
"${runtime_env[@]}" "$runtime_cli" deploy internal watchdog --deployment-id "$runtime_id"
[[ $(sed -n 's/^status=//p' "$runtime_guard") == ROLLED_BACK && ! -e $runtime_lock ]] || \
  fail 'watchdog retry did not finish rollback'
[[ $(readlink "$runtime_frontend/current") == releases/old ]] || fail 'rollback did not restore frontend identity'

setup_runtime_transaction confirmation-race confirmed-release
"${runtime_env[@]}" "$runtime_workspace/staging/frontend-activator" prepare "${runtime_args[@]}"
"${runtime_env[@]}" "$runtime_workspace/staging/frontend-activator" switch "${runtime_args[@]}"
hold="$tmp/runtime-confirm.hold"; ready="$tmp/runtime-confirm.ready"; waiting="$tmp/runtime-rollback.waiting"
: >"$hold"
"${runtime_env[@]}" LMM_DEPLOY_TEST_CONFIRM_HOLD_FILE="$hold" LMM_DEPLOY_TEST_CONFIRM_READY_FILE="$ready" \
  "$runtime_workspace/staging/frontend-activator" confirm "${runtime_args[@]}" >"$tmp/runtime-confirm.out" 2>"$tmp/runtime-confirm.err" &
confirm_pid=$!
for _ in {1..200}; do [[ -e $ready ]] && break; sleep 0.01; done
[[ -e $ready ]] || fail 'confirmation did not hold the shared mutex'
"${runtime_env[@]}" LMM_DEPLOY_TEST_MUTEX_WAITING_FILE="$waiting" \
  "$runtime_cli" deploy internal watchdog --deployment-id "$runtime_id" >"$tmp/runtime-race.out" 2>"$tmp/runtime-race.err" &
rollback_pid=$!
for _ in {1..200}; do [[ -e $waiting ]] && break; sleep 0.01; done
[[ -e $waiting ]] || fail 'watchdog did not queue on the shared mutex'
installs_before=$(wc -l <"$tmp/runtime-pacman.installs")
rm -f -- "$hold"
wait "$confirm_pid" || fail 'confirmation lost the deterministic race'
wait "$rollback_pid" || fail 'queued watchdog did not no-op after confirmation'
[[ $(sed -n 's/^status=//p' "$runtime_guard") == CONFIRMED && ! -e $runtime_lock ]] || \
  fail 'confirmation race did not finish in CONFIRMED without ownership'
[[ $(wc -l <"$tmp/runtime-pacman.installs") == "$installs_before" ]] || \
  fail 'queued watchdog changed packages after confirmation'
[[ $(readlink "$runtime_frontend/current") == releases/confirmed-release ]] || \
  fail 'queued watchdog changed the confirmed frontend'

# A pre-existing controller destination is never claimed or cleaned.
existing_id=frontend-existing
existing_work="$tmp/work-existing"
existing_controller="$tmp/created-backups/existing-controller"
existing_base=(deploy production --frontend-only --host ArchDmit --deployment-id "$existing_id" \
  --workspace "$existing_work")
"$cli" "${existing_base[@]}" inspect >/dev/null
"$cli" "${existing_base[@]}" build >/dev/null
"$cli" "${existing_base[@]}" --core-package "$core" package >/dev/null
mkdir -m0700 "$existing_controller"
printf 'preserve\n' >"$existing_controller/owner-marker"
expect_fail "$cli" "${existing_base[@]}" --jump-host archczy --create-backups \
  --age-recipient-file "$tmp/age-recipient" --target-backup "$tmp/created-backups/existing-target" \
  --controller-backup "$existing_controller" --offhost-backup "$tmp/created-backups/existing-offhost" backup
grep -Fqx preserve "$existing_controller/owner-marker" || fail 'pre-existing controller output was modified'

printf 'frontend-only deploy contract verified\n'
