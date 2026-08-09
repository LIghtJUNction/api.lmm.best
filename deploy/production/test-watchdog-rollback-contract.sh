#!/usr/bin/env bash
set -Eeuo pipefail

here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
repo=$(cd -- "$here/../.." && pwd -P)
# shellcheck source=../../apps/api-rust/tests/scripts/route-gate-fixture-lib.sh
# shellcheck disable=SC1091 # Repository root is resolved at runtime.
source "$repo/apps/api-rust/tests/scripts/route-gate-fixture-lib.sh"
fail() { printf 'watchdog-rollback-contract: %s\n' "$*" >&2; exit 1; }
expect_fail() {
  if "$@" >"$tmp/out" 2>"$tmp/err"; then
    fail "expected failure: $*"
  fi
}

tmp=$(mktemp -d "$repo/.lmm-api-watchdog-contract.XXXXXXXX")
trap 'rm -rf -- "$tmp"' EXIT
deployment_id=prod-watchdog
revision=0123456789abcdef0123456789abcdef01234567
workspace="$tmp/target-work/$deployment_id"
staging="$workspace/staging"
backup="$tmp/target-backup/$deployment_id"
frontend="$tmp/frontend"
frontend_source="$tmp/frontend-source"
backend_root="$tmp/backends"
systemd="$tmp/systemd"
pacman_cache="$tmp/pacman-cache"
transaction_lock="$tmp/deploy-transaction.lock"
bin="$tmp/bin"
mkdir -p "$staging" "$workspace/state" "$backup" "$frontend/releases/new" \
  "$frontend/releases/old" "$frontend_source" "$backend_root/go" "$systemd" \
  "$pacman_cache" "$bin"

printf '%s\n' '<!doctype html>' >"$frontend/releases/new/index.html"
printf '%s\n' '<!doctype html>' >"$frontend/releases/old/index.html"
printf '%s\n' '<!doctype html>' >"$frontend_source/index.html"
printf 'old-backend-bytes\n' >"$backend_root/go/lmm-api"
old_backend_sha=$(sha256sum "$backend_root/go/lmm-api" | awk '{print $1}')
ln -s releases/old "$frontend/current"
printf 'format=1\ndeployment_id=%s\nrole=target\nworkspace=%s\n' \
  "$deployment_id" "$workspace" >"$workspace/.lmm-deploy-workspace"
printf 'LMM_API_BACKEND=go\n' >"$tmp/backend.conf"
printf 'SQL_DSN=postgresql://old-fixture\n' >"$tmp/lmm-api.env"

mkdir -p "$tmp/config/lmm-api"
cp -- "$tmp/backend.conf" "$tmp/config/lmm-api/backend.conf"
cp -- "$tmp/lmm-api.env" "$tmp/config/lmm-api/lmm-api.env"
tar -cf "$backup/configuration.tar" -C "$tmp/config" lmm-api
for name in application frontend database; do
  printf '%s\n' "$name" >"$backup/$name.archive"
done

printf 'core-new\n' >"$staging/core.pkg"
printf 'provider-new\n' >"$staging/backend.pkg"
printf 'core-old\n' >"$pacman_cache/lmm-api-bin-0.1.0-1-any.pkg.tar.zst"
printf 'provider-old\n' >"$pacman_cache/lmm-api-go-bin-0.1.0-1-x86_64.pkg.tar.zst"
core_sha=$(sha256sum "$staging/core.pkg" | awk '{print $1}')
backend_sha=$(sha256sum "$staging/backend.pkg" | awk '{print $1}')
cat >"$backup/manifest.env" <<EOF
copy_role=target
database_engine=postgres
configuration_file=configuration.tar
git_revision=$revision
core_sha256=$core_sha
backend_sha256=$backend_sha
EOF
sha256sum "$backup/configuration.tar" "$backup"/*.archive | \
  sed "s|$backup/||" >"$backup/SHA256SUMS"

cat >"$staging/frontend-release.sh" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
mode=$1
shift
root=''
release=''
source_dir=''
while (($#)); do
  case $1 in
    --root) root=$2; shift 2 ;;
    --release) release=$2; shift 2 ;;
    --source) source_dir=$2; shift 2 ;;
    --keep) shift 2 ;;
    *) exit 2 ;;
  esac
done
case $mode in
  publish)
    [[ -f $source_dir/index.html ]]
    mkdir -p "$root/releases/$release"
    cp -- "$source_dir/index.html" "$root/releases/$release/index.html"
    ;;
  rollback) [[ -f $root/releases/$release/index.html ]] ;;
  *) exit 2 ;;
esac
ln -sfn "releases/$release" "$root/current"
EOF
chmod 0700 "$staging/frontend-release.sh"
cp -- "$here/activate-rust-release.sh" "$staging/activate-rust-release.sh"
chmod 0700 "$staging/activate-rust-release.sh"

cat >"$staging/lmm-api-rollback.service" <<'EOF'
[Unit]
Description=Rollback an unconfirmed lmm-api deployment

[Service]
Type=oneshot
ExecCondition=/usr/bin/grep -Eq ^status=(ARMED|ROLLING_BACK)$ __LMM_GUARD__
ExecStart=__LMM_ACTIVATOR__ --rollback-only --workspace __LMM_WORKSPACE__ --guard __LMM_GUARD__ --target-backup __LMM_TARGET_BACKUP__ --rollback-core __LMM_ROLLBACK_CORE__ --rollback-backend __LMM_ROLLBACK_BACKEND__ --frontend-release-script __LMM_FRONTEND_SCRIPT__ --status-file __LMM_STATUS_FILE__
EOF
cat >"$staging/lmm-api-rollback.timer" <<'EOF'
[Unit]
Description=Rollback deadline for an unconfirmed lmm-api deployment

[Timer]
OnCalendar=@__LMM_ROLLBACK_DEADLINE_EPOCH__
Persistent=true
Unit=lmm-api-rollback.service

[Install]
WantedBy=timers.target
EOF
route_payload="$tmp/route-payload"
route_gate_fixture_create "$repo" "$route_payload" "$revision"
cp -- "$route_payload/migration-gate.tsv" "$staging/route-gate.tsv"
route_gate_sha=$(sha256sum "$staging/route-gate.tsv" | awk '{print $1}')

cat >"$bin/pacman" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
state=${LMM_TEST_PACMAN_STATE:?}
backend_path=${LMM_TEST_OLD_BACKEND_PATH:?}
record_for_archive() {
  case ${1##*/} in
    core.pkg) printf 'lmm-api-bin 0.1.1-1\n' ;;
    backend.pkg) printf 'lmm-api-rs-bin 0.1.1-1\n' ;;
    lmm-api-bin-0.1.0-1-any.pkg.tar.zst|rollback-core.pkg) printf 'lmm-api-bin 0.1.0-1\n' ;;
    lmm-api-go-bin-0.1.0-1-x86_64.pkg.tar.zst|rollback-backend.pkg) printf 'lmm-api-go-bin 0.1.0-1\n' ;;
    *) exit 1 ;;
  esac
}
arch_for_archive() {
  case ${1##*/} in
    core.pkg|lmm-api-bin-0.1.0-1-any.pkg.tar.zst|rollback-core.pkg) printf 'any\n' ;;
    *) printf 'x86_64\n' ;;
  esac
}
case $1 in
  -Qp) record_for_archive "$2" ;;
  -Qip) printf 'Architecture        : %s\n' "$(arch_for_archive "$2")" ;;
  -Qqo)
    query_path=$2
    [[ $query_path == -- ]] && query_path=$3
    [[ $query_path == /usr/bin/lmm-api ]] && printf 'lmm-api-bin\n' || {
      if [[ $query_path == "$backend_path" ]]; then
        printf 'lmm-api-go-bin\n'
      elif [[ $query_path == "${LMM_TEST_INSTALLED_DEPLOY_LIB:?}"/* || \
        $query_path == "${LMM_TEST_INSTALLED_REVISION:?}" ]]; then
        printf 'lmm-api-bin\n'
      else
        exit 1
      fi
    }
    ;;
  -Q)
    awk -v name="$2" '$1 == name { print; found=1 } END { exit !found }' "${state}.installed"
    ;;
  -Qi)
    case $2 in
      lmm-api-bin) printf 'Name : lmm-api-bin\nArchitecture        : any\n' ;;
      lmm-api-go-bin|lmm-api-rs-bin) printf 'Name : %s\nArchitecture        : x86_64\n' "$2" ;;
      *) exit 1 ;;
    esac
    ;;
  -Qkk) exit 0 ;;
  -U)
    printf '%s\n' "install $*" >>"$state"
    if [[ -f ${state}.fail-next ]]; then
      rm -f -- "${state}.fail-next"
      exit 93
    fi
    if [[ ${3##*/} == core.pkg && ${4##*/} == backend.pkg ]]; then
      printf 'lmm-api-bin 0.1.1-1\nlmm-api-rs-bin 0.1.1-1\n' >"${state}.installed"
    else
      printf 'lmm-api-bin 0.1.0-1\nlmm-api-go-bin 0.1.0-1\n' >"${state}.installed"
    fi
    ;;
  *) exit 2 ;;
esac
EOF
cat >"$bin/bsdtar" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
if [[ $1 == -xOf ]]; then
  [[ ${2##*/} == core.pkg || ${2##*/} == backend.pkg ]]
  if [[ ${3:-} == usr/lib/lmm-api/deploy/route-gate-assets.sha256 ]]; then
    cat -- "${LMM_TEST_ROUTE_PAYLOAD:?}/route-gate-assets.sha256"
  else
    printf '%s\n' "${LMM_TEST_NEW_REVISION:?}"
  fi
elif [[ $1 == -xf ]]; then
  destination=''
  while (($#)); do
    case $1 in
      -C) destination=$2; shift 2 ;;
      *) shift ;;
    esac
  done
  [[ -n $destination ]] || exit 2
  mkdir -p "$destination/usr/lib/lmm-api/deploy" "$destination/usr/share/doc/lmm-api-bin"
  cp -R -- "${LMM_TEST_ROUTE_PAYLOAD:?}/." "$destination/usr/lib/lmm-api/deploy/"
  printf '%s\n' "${LMM_TEST_NEW_REVISION:?}" >"$destination/usr/share/doc/lmm-api-bin/REVISION"
  exit 0
else
  exit 2
fi
EOF
cat >"$bin/systemctl" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
state=${LMM_TEST_SYSTEMCTL_STATE:?}
printf '%s\n' "$*" >>"$state"
case $1 in
  enable)
    [[ $2 == --now ]]
    : >"${state}.timer-enabled"
    : >"${state}.timer-active"
    ;;
  disable)
    rm -f -- "${state}.timer-enabled" "${state}.timer-active"
    ;;
  is-enabled)
    [[ $* == *lmm-api-rollback.timer* && -f ${state}.timer-enabled ]]
    ;;
  is-active)
    if [[ $* == *lmm-api-rollback.timer* ]]; then
      [[ -f ${state}.timer-active ]]
    elif [[ $* == *lmm-api-rollback.service* ]]; then
      exit 1
    else
      exit 0
    fi
    ;;
  daemon-reload|restart) exit 0 ;;
  *) exit 0 ;;
esac
EOF
cat >"$bin/curl" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
printf '%s\n' "$*" >>"${LMM_TEST_CURL_STATE:?}"
jq -cn --arg revision "${LMM_TEST_HEALTH_REVISION:-old-revision}" \
  '{success:true,ready:true,data:{revision:$revision}}'
EOF
chmod 0700 "$bin"/*

: >"$tmp/pacman.log"
printf 'lmm-api-bin 0.1.0-1\nlmm-api-go-bin 0.1.0-1\n' >"$tmp/pacman.log.installed"
: >"$tmp/systemctl.log"
: >"$tmp/curl.log"
export LMM_DEPLOY_TEST_MODE=1 LMM_DEPLOY_OBSERVED_HOST=arch-dmit
export LMM_DEPLOY_TEST_BACKEND_CONFIG="$tmp/backend.conf"
export LMM_DEPLOY_TEST_ENV_CONFIG="$tmp/lmm-api.env"
export LMM_DEPLOY_TEST_FRONTEND_ROOT="$frontend"
export LMM_DEPLOY_TEST_FRONTEND_SOURCE="$frontend_source"
export LMM_DEPLOY_TEST_BACKEND_ROOT="$backend_root"
export LMM_DEPLOY_TEST_STAGING_ROOT="$tmp/target-work"
export LMM_DEPLOY_TEST_BACKUP_ROOT="$tmp/target-backup"
export LMM_DEPLOY_TEST_TRANSACTION_LOCK="$transaction_lock"
export LMM_DEPLOY_TEST_SYSTEMD_UNIT_DIR="$systemd"
export LMM_DEPLOY_TEST_PACMAN_CACHE="$pacman_cache"
export LMM_TEST_PACMAN_STATE="$tmp/pacman.log"
export LMM_TEST_SYSTEMCTL_STATE="$tmp/systemctl.log"
export LMM_TEST_CURL_STATE="$tmp/curl.log"
export LMM_TEST_OLD_BACKEND_PATH="$backend_root/go/lmm-api"
export LMM_TEST_NEW_REVISION="$revision"
export LMM_TEST_ROUTE_PAYLOAD="$route_payload"
installed_deploy="$tmp/installed-deploy"
mkdir -p "$installed_deploy"
cp -R -- "$route_payload/." "$installed_deploy/"
installed_revision="$tmp/installed-REVISION"
printf '%s\n' "$revision" >"$installed_revision"
export LMM_DEPLOY_TEST_DEPLOY_LIBDIR="$installed_deploy"
export LMM_DEPLOY_TEST_REVISION_PATH="$installed_revision"
export LMM_TEST_INSTALLED_DEPLOY_LIB="$installed_deploy"
export LMM_TEST_INSTALLED_REVISION="$installed_revision"
acceptance_runner="$tmp/production-acceptance.mjs"
acceptance_lib="$tmp/production-acceptance-lib.mjs"
printf '%s\n' 'acceptance-library-fixture' >"$acceptance_lib"
cat >"$acceptance_runner" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
mode=$1
deployment_id=''
backend_revision=''
frontend_release=''
frontend_digest=''
deadline_epoch=''
watchdog_deadline_epoch=''
while (($#)); do
  case $1 in
    --deployment-id) deployment_id=$2; shift 2 ;;
    --backend-revision) backend_revision=$2; shift 2 ;;
    --frontend-release) frontend_release=$2; shift 2 ;;
    --frontend-digest) frontend_digest=$2; shift 2 ;;
    --deadline-epoch) deadline_epoch=$2; shift 2 ;;
    --watchdog-deadline-epoch) watchdog_deadline_epoch=$2; shift 2 ;;
    --baseline-file) shift 2 ;;
    *) shift ;;
  esac
done
if [[ $mode == baseline ]]; then
  jq -n --arg id "$deployment_id" --arg rev "$backend_revision" --arg rel "$frontend_release" \
    --arg digest "$frontend_digest" --argjson deadline "$deadline_epoch" --argjson watchdog "$watchdog_deadline_epoch" \
    '{schema_version:2,mode:"baseline",target:"https://api.lmm.best",bindings:{deployment_id:$id,backend_revision:$rev,frontend_release:$rel,frontend_digest:$digest,deadline_epoch:$deadline,watchdog_deadline_epoch:$watchdog},success:true,checks:{enabled_channel_count:1,root_logout_refresh:true,root_role:true},channels:[],enabled_channels:[{id:1,type:1}],failures:[],cleanup:{attempts:{token_delete:false,test_user_logout:false,user_delete:false,root_logout:true},token_deleted:false,user_deleted:false,retained_test_identity:null,retained_token:null}}'
else
  jq -n --arg id "$deployment_id" --arg rev "$backend_revision" --arg rel "$frontend_release" \
    --arg digest "$frontend_digest" --argjson deadline "$deadline_epoch" --argjson watchdog "$watchdog_deadline_epoch" \
    '{schema_version:2,mode:"verify",target:"https://api.lmm.best",bindings:{deployment_id:$id,backend_revision:$rev,frontend_release:$rel,frontend_digest:$digest,deadline_epoch:$deadline,watchdog_deadline_epoch:$watchdog},success:true,checks:{enabled_channels_tested:1,enabled_channels_passed:1},channels:[{id:1,type:1,enabled:true,passed:true}],failures:[],cleanup:{attempts:{token_delete:true,test_user_logout:true,user_delete:true,root_logout:true},token_deleted:true,user_deleted:true,retained_test_identity:null,retained_token:null}}'
fi
EOF
chmod 0755 "$acceptance_runner"
chmod 0644 "$acceptance_lib"
printf '%s\n' '{}' >"$tmp/acceptance-credentials.json"
chmod 0600 "$tmp/acceptance-credentials.json"
export LMM_DEPLOY_TEST_ACCEPTANCE_RUNNER="$acceptance_runner"
export LMM_DEPLOY_TEST_ACCEPTANCE_LIB="$acceptance_lib"
export LMM_DEPLOY_TEST_FRONTEND_DIGEST=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
export LMM_ACCEPTANCE_CREDENTIAL_FILE="$tmp/acceptance-credentials.json"

common_args=(
  --core-package "$staging/core.pkg" --core-sha256 "$core_sha"
  --backend-package "$staging/backend.pkg" --backend-sha256 "$backend_sha"
  --frontend-release-script "$staging/frontend-release.sh"
  --expected-release new --expected-revision "$revision"
  --route-gate "$staging/route-gate.tsv" --route-gate-sha256 "$route_gate_sha"
  --status-file "$staging/status" --workspace "$workspace"
  --target-backup "$backup" --guard "$workspace/state/rollback.guard"
)

tampered_route_payload="$tmp/tampered-route-payload"
cp -R -- "$route_payload" "$tampered_route_payload"
cat >"$tampered_route_payload/validate-route-gate" <<'EOF'
#!/usr/bin/env bash
: >"${LMM_ROUTE_GATE_VALIDATOR_SIDE_EFFECT:?}"
exit 0
EOF
chmod 0755 "$tampered_route_payload/validate-route-gate"
tampered_workspace="$tmp/target-work/tampered-route"
mkdir -p "$tampered_workspace/staging" "$tampered_workspace/state"
printf 'format=1\ndeployment_id=tampered-route\nrole=target\nworkspace=%s\n' "$tampered_workspace" \
  >"$tampered_workspace/.lmm-deploy-workspace"
cp -- "$staging/core.pkg" "$staging/backend.pkg" "$staging/frontend-release.sh" \
  "$staging/route-gate.tsv" "$staging/lmm-api-rollback.service" "$staging/lmm-api-rollback.timer" \
  "$tampered_workspace/staging/"
tampered_backup="$tmp/target-backup/tampered-route"
cp -R -- "$backup" "$tampered_backup"
sed -i 's/deployment_id=prod-watchdog/deployment_id=tampered-route/' "$tampered_backup/manifest.env"
tampered_side_effect="$tmp/tampered-validator.executed"
expect_fail env PATH="$bin:$PATH" LMM_TEST_ROUTE_PAYLOAD="$tampered_route_payload" \
  LMM_ROUTE_GATE_VALIDATOR_SIDE_EFFECT="$tampered_side_effect" \
  "$staging/activate-rust-release.sh" --prepare-only "${common_args[@]}" \
  --workspace "$tampered_workspace" --status-file "$tampered_workspace/staging/status" \
  --guard "$tampered_workspace/state/rollback.guard" --target-backup "$tampered_backup" \
  --core-package "$tampered_workspace/staging/core.pkg" \
  --backend-package "$tampered_workspace/staging/backend.pkg" \
  --frontend-release-script "$tampered_workspace/staging/frontend-release.sh" \
  --route-gate "$tampered_workspace/staging/route-gate.tsv"
grep -Fq 'validator changed after authentication' "$tmp/err" || \
  fail 'tampered package validator did not fail authentication'
[[ ! -e $tampered_side_effect ]] || fail 'tampered package validator executed before authentication'

one_row_gate="$staging/one-row-route-gate.tsv"
sed -n '1,2p' "$staging/route-gate.tsv" >"$one_row_gate"
one_row_sha=$(sha256sum "$one_row_gate" | awk '{print $1}')
expect_fail env PATH="$bin:$PATH" "$staging/activate-rust-release.sh" --prepare-only \
  "${common_args[@]}" --route-gate "$one_row_gate" --route-gate-sha256 "$one_row_sha"
grep -Fq 'transferred-preinstall route-gate validation failed' "$tmp/err" || \
  fail 'one-row transferred gate was not independently rejected'
[[ ! -s $tmp/pacman.log ]] || fail 'one-row gate rejection mutated packages'

self_substituted_gate="$staging/self-substituted-route-gate.tsv"
awk -F '\t' 'BEGIN { OFS=FS } NR == 2 { $2="/self-substituted" } { print }' \
  "$staging/route-gate.tsv" >"$self_substituted_gate"
self_substituted_sha=$(sha256sum "$self_substituted_gate" | awk '{print $1}')
expect_fail env PATH="$bin:$PATH" "$staging/activate-rust-release.sh" --prepare-only \
  "${common_args[@]}" --route-gate "$self_substituted_gate" --route-gate-sha256 "$self_substituted_sha"
grep -Fq 'transferred-preinstall route-gate validation failed' "$tmp/err" || \
  fail 'self-substituted transferred gate was not independently rejected'
[[ ! -s $tmp/pacman.log ]] || fail 'self-substituted gate rejection mutated packages'

PATH="$bin:$PATH" "$staging/activate-rust-release.sh" --prepare-only "${common_args[@]}"
guard="$workspace/state/rollback.guard"
[[ $(sed -n 's/^status=//p' "$guard") == PREPARED ]] || fail 'real prepare path did not persist PREPARED'
[[ -d $transaction_lock ]] || fail 'prepare did not retain the deployment lock'
grep -Fqx 'Persistent=true' "$systemd/lmm-api-rollback.timer" || fail 'installed timer is not persistent'
deadline=$(sed -n 's/^OnCalendar=@//p' "$systemd/lmm-api-rollback.timer")
[[ $deadline =~ ^[0-9]+$ && $deadline -gt $(date +%s) ]] || fail 'installed timer deadline is invalid'

expect_fail env PATH="$bin:$PATH" LMM_DEPLOY_TEST_CRASH_AFTER_ARM=1 \
  "$staging/activate-rust-release.sh" \
  --rollback-core "$staging/rollback-core.pkg" --rollback-backend "$staging/rollback-backend.pkg" \
  "${common_args[@]}"
[[ $(sed -n 's/^status=//p' "$guard") == ARMED ]] || fail 'crash injection did not leave an ARMED guard'
[[ -d $transaction_lock ]] || fail 'crash after arming released the deployment lock'
[[ ! -s $tmp/pacman.log ]] || fail 'crash after arming mutated packages'

# Reboot preserves the enabled persistent timer. At expiry systemd evaluates the
# installed unit, so execute its rendered condition and command rather than a
# hand-built rollback invocation.
rm -f -- "$tmp/systemctl.log.timer-active"
[[ -f $tmp/systemctl.log.timer-enabled ]] || fail 'reboot lost the persistent timer enablement'
: >"$tmp/systemctl.log.timer-active"
condition=${LMM_TEST_UNIT_CONDITION:-$(sed -n 's/^ExecCondition=//p' "$systemd/lmm-api-rollback.service")}
start=${LMM_TEST_UNIT_START:-$(sed -n 's/^ExecStart=//p' "$systemd/lmm-api-rollback.service")}
read -r -a condition_command <<<"$condition"
read -r -a start_command <<<"$start"
"${condition_command[@]}" || fail 'rendered watchdog condition rejected an ARMED guard'
rollback_env=(env -u LMM_ACCEPTANCE_CREDENTIAL_FILE -u LMM_ACCEPTANCE_CREDENTIAL_FD PATH="$bin:$PATH")

: >"$tmp/pacman.log.fail-next"
expect_fail "${rollback_env[@]}" "${start_command[@]}"
grep -Fq 'rollback package installation failed' "$tmp/err" || fail 'rollback install failure was not surfaced'
[[ $(sed -n 's/^status=//p' "$guard") == ROLLING_BACK ]] || fail 'failed rollback did not retain its durable in-progress state'
[[ -d $transaction_lock ]] || fail 'failed rollback released the deployment lock'

"${rollback_env[@]}" "${start_command[@]}"
[[ $(sed -n 's/^status=//p' "$guard") == ROLLED_BACK ]] || fail 'watchdog retry did not reach ROLLED_BACK'
[[ ! -e $transaction_lock ]] || fail 'successful rollback retained the deployment lock'
[[ $(readlink "$frontend/current") == releases/old ]] || fail 'rollback did not restore frontend identity'
grep -Fqx 'LMM_API_BACKEND=go' "$tmp/backend.conf" || fail 'rollback did not restore backend config'
grep -Fqx 'SQL_DSN=postgresql://old-fixture' "$tmp/lmm-api.env" || fail 'rollback did not restore environment'
grep -Fqx 'lmm-api-bin 0.1.0-1' "$tmp/pacman.log.installed" || fail 'rollback did not restore core package'
grep -Fqx 'lmm-api-go-bin 0.1.0-1' "$tmp/pacman.log.installed" || fail 'rollback did not restore provider package'
[[ $(sha256sum "$backend_root/go/lmm-api" | awk '{print $1}') == "$old_backend_sha" ]] || \
  fail 'rollback backend checksum changed'
grep -Fq 'is-active --quiet lmm-api.service' "$tmp/systemctl.log" || fail 'rollback did not verify service state'
[[ -s $tmp/curl.log ]] || fail 'rollback health identity was not checked'

before=$(wc -l <"$tmp/pacman.log")
"${rollback_env[@]}" "${start_command[@]}"
[[ $(wc -l <"$tmp/pacman.log") == "$before" ]] || fail 'idempotent rollback reinstalled packages'

sed -i 's/^status=ROLLED_BACK$/status=CONFIRMED/' "$guard"
"${rollback_env[@]}" "${start_command[@]}"
[[ $(wc -l <"$tmp/pacman.log") == "$before" ]] || fail 'confirmed rollback no-op mutated packages'
[[ ! -e $transaction_lock ]] || fail 'confirmed rollback refusal recreated the transaction lock'

# Deterministic confirm/rollback race: confirmation owns the mutex while the
# rollback process has passed ExecCondition and queues for that same mutex.
# Confirmation wins ARMED -> CONFIRMED; the queued rollback then no-ops.
sed -i 's/^status=CONFIRMED$/status=ARMED/' "$guard"
printf 'AWAITING_CONFIRMATION release=new revision=%s frontend=new\n' "$revision" >"$staging/status"
printf 'lmm-api-bin 0.1.1-1\nlmm-api-rs-bin 0.1.1-1\n' >"$tmp/pacman.log.installed"
printf '# Managed by lmm-api deployment.\nLMM_API_BACKEND=rs\n' >"$tmp/backend.conf"
ln -sfn releases/new "$frontend/current"
mkdir -m0700 "$transaction_lock"
printf 'format=1\ndeployment_id=%s\nstatus=ACTIVE\n' "$deployment_id" >"$transaction_lock/deployment.env"
chmod 0600 "$transaction_lock/deployment.env"
: >"$tmp/systemctl.log.timer-enabled"
: >"$tmp/systemctl.log.timer-active"
baseline="$workspace/state/acceptance-baseline.json"
verify="$workspace/state/acceptance-verify.json"
"$acceptance_runner" verify --deployment-id "$deployment_id" --backend-revision "$revision" \
  --frontend-release new --frontend-digest "$LMM_DEPLOY_TEST_FRONTEND_DIGEST" \
  --deadline-epoch "$(sed -n 's/^acceptance_deadline_epoch=//p' "$guard")" \
  --watchdog-deadline-epoch "$(sed -n 's/^acceptance_watchdog_deadline_epoch=//p' "$guard")" \
  --baseline-file "$baseline" >"$verify"
chmod 0600 "$verify"

hold="$tmp/confirm.hold"
ready="$tmp/confirm.ready"
waiting="$tmp/rollback.waiting"
: >"$hold"
env PATH="$bin:$PATH" LMM_TEST_HEALTH_REVISION="$revision" \
  LMM_DEPLOY_TEST_CONFIRM_HOLD_FILE="$hold" LMM_DEPLOY_TEST_CONFIRM_READY_FILE="$ready" \
  "$staging/activate-rust-release.sh" --confirm-only "${common_args[@]}" \
  >"$tmp/confirm.out" 2>"$tmp/confirm.err" &
confirm_pid=$!
for _ in {1..200}; do [[ -e $ready ]] && break; sleep 0.01; done
[[ -e $ready ]] || fail 'confirmation did not acquire and hold the shared mutex'
"${condition_command[@]}" || fail 'race rollback did not pass the rendered ExecCondition'
env -u LMM_ACCEPTANCE_CREDENTIAL_FILE -u LMM_ACCEPTANCE_CREDENTIAL_FD PATH="$bin:$PATH" \
  LMM_DEPLOY_TEST_MUTEX_WAITING_FILE="$waiting" "${start_command[@]}" \
  >"$tmp/race-rollback.out" 2>"$tmp/race-rollback.err" &
rollback_pid=$!
for _ in {1..200}; do [[ -e $waiting ]] && break; sleep 0.01; done
[[ -e $waiting ]] || fail 'rollback did not queue for the shared mutex'
race_installs=$(wc -l <"$tmp/pacman.log")
rm -f -- "$hold"
wait "$confirm_pid" || { cat "$tmp/confirm.err" >&2; fail 'confirmation lost the deterministic race'; }
wait "$rollback_pid" || { cat "$tmp/race-rollback.err" >&2; fail 'queued rollback did not no-op after confirmation'; }
[[ $(sed -n 's/^status=//p' "$guard") == CONFIRMED ]] || fail 'race target guard is not CONFIRMED'
[[ $(<"$staging/status") == "CONFIRMED deployment=$deployment_id" ]] || fail 'race target status is not CONFIRMED'
[[ $(wc -l <"$tmp/pacman.log") == "$race_installs" ]] || fail 'queued rollback changed packages after confirmation'
grep -Fqx 'LMM_API_BACKEND=rs' "$tmp/backend.conf" || fail 'queued rollback changed confirmed backend config'
[[ $(readlink "$frontend/current") == releases/new ]] || fail 'queued rollback changed confirmed frontend'
[[ ! -e $transaction_lock ]] || fail 'confirmation did not release durable ownership last'
[[ ! -e $tmp/systemctl.log.timer-active ]] || fail 'confirmation left rollback timer active'

# A terminal prepare retry must fail before touching global ownership. A fresh
# deployment must still be able to acquire that global lock afterward.
expect_fail env PATH="$bin:$PATH" "$staging/activate-rust-release.sh" --prepare-only "${common_args[@]}"
grep -Fq 'prepare refused for terminal deployment' "$tmp/err" || fail 'terminal prepare retry was not rejected idempotently'
[[ ! -e $transaction_lock ]] || fail 'terminal prepare retry recreated global ownership'

fresh_id=prod-fresh
fresh_workspace="$tmp/target-work/$fresh_id"
fresh_staging="$fresh_workspace/staging"
fresh_backup="$tmp/target-backup/$fresh_id"
mkdir -p "$fresh_staging" "$fresh_workspace/state"
for file in core.pkg backend.pkg route-gate.tsv lmm-api-rollback.service lmm-api-rollback.timer \
  activate-rust-release.sh frontend-release.sh; do
  cp -- "$staging/$file" "$fresh_staging/$file"
done
printf 'format=1\ndeployment_id=%s\nrole=target\nworkspace=%s\n' "$fresh_id" "$fresh_workspace" \
  >"$fresh_workspace/.lmm-deploy-workspace"
cp -a -- "$backup" "$fresh_backup"
fresh_core_sha=$(sha256sum "$fresh_staging/core.pkg" | awk '{print $1}')
fresh_backend_sha=$(sha256sum "$fresh_staging/backend.pkg" | awk '{print $1}')
{
  printf 'copy_role=target\ndatabase_engine=postgres\nconfiguration_file=configuration.tar\n'
  printf 'git_revision=%s\ncore_sha256=%s\nbackend_sha256=%s\n' "$revision" "$fresh_core_sha" "$fresh_backend_sha"
} >"$fresh_backup/manifest.env"
printf 'lmm-api-bin 0.1.0-1\nlmm-api-go-bin 0.1.0-1\n' >"$tmp/pacman.log.installed"
printf 'LMM_API_BACKEND=go\n' >"$tmp/backend.conf"
ln -sfn releases/old "$frontend/current"
fresh_args=(
  --core-package "$fresh_staging/core.pkg" --core-sha256 "$fresh_core_sha"
  --backend-package "$fresh_staging/backend.pkg" --backend-sha256 "$fresh_backend_sha"
  --frontend-release-script "$fresh_staging/frontend-release.sh"
  --expected-release "$fresh_id" --expected-revision "$revision"
  --route-gate "$fresh_staging/route-gate.tsv" --route-gate-sha256 "$route_gate_sha"
  --status-file "$fresh_staging/status" --workspace "$fresh_workspace"
  --target-backup "$fresh_backup" --guard "$fresh_workspace/state/rollback.guard"
)
PATH="$bin:$PATH" "$fresh_staging/activate-rust-release.sh" --prepare-only "${fresh_args[@]}"
[[ -d $transaction_lock ]] || fail 'fresh deployment could not acquire the released global lock'
grep -Fqx "deployment_id=$fresh_id" "$transaction_lock/deployment.env" || \
  fail 'fresh deployment acquired a lock for the wrong deployment'

printf '%s\n' 'watchdog rollback contract verified'
