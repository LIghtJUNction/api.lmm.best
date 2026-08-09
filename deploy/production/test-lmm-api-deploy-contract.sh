#!/usr/bin/env bash
set -Eeuo pipefail

here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
cli="$here/../../packaging/common/lmm-api/lmm-api-launcher"
core="$cli"
fail() { printf 'canonical-deploy-contract: %s\n' "$*" >&2; exit 1; }

bash -n "$cli" "$core" || fail 'CLI has shell syntax errors'

expect_fail() {
  if "$@" >"$tmp/out" 2>"$tmp/err"; then
    fail "expected failure: $*"
  fi
}

repo=$(cd -- "$here/../.." && pwd -P)
# shellcheck source=../../apps/api-rust/tests/scripts/route-gate-fixture-lib.sh
# shellcheck disable=SC1091 # Repository root is resolved at runtime.
source "$repo/apps/api-rust/tests/scripts/route-gate-fixture-lib.sh"
tmp=$(mktemp -d "$repo/.lmm-api-deploy-contract.XXXXXXXX")
trap 'rm -rf -- "$tmp"' EXIT
export LMM_DEPLOY_TEST_MODE=1
base=(deploy production --deployment-id contract-test --workspace "$tmp/base-workspace")
revision=$(git -C "$repo" rev-parse HEAD)
mkdir -p "$tmp/fake-bin" "$tmp/deploy-lib"
printf 'Host archczy\n  HostName 127.0.0.1\n' >"$tmp/ssh-config"
chmod 0600 "$tmp/ssh-config"
export LMM_API_DEPLOY_SSH_CONFIG="$tmp/ssh-config"
gate="$tmp/deploy-lib/migration-gate.tsv"
route_gate_fixture_create "$repo" "$tmp/deploy-lib" "$revision"
export LMM_API_DEPLOY_LIBDIR="$tmp/deploy-lib"
cat >"$tmp/fake-bin/pacman" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
case $1 in
  -Qp)
    if grep -Fq core-package "$2"; then printf 'lmm-api-bin 0.1.2-1\n'; else printf 'lmm-api-rs-bin 0.1.2-1\n'; fi
    ;;
  -Qip)
    if grep -Fq core-package "$2"; then printf 'Architecture : any\n'; else printf 'Architecture : x86_64\n'; fi
    ;;
  -Qqo)
    [[ ${FAKE_PACMAN_NO_OWNER:-0} == 0 ]] || exit 1
    printf '%s\n' "${FAKE_PACMAN_OWNER:-lmm-api-bin}"
    ;;
  -Q) printf 'lmm-api-bin 0.1.2-1\n' ;;
  -Qkk) [[ ${FAKE_PACMAN_QKK_FAIL:-0} == 0 ]] ;;
  *) exit 2 ;;
esac
EOF
cat >"$tmp/fake-bin/bsdtar" <<EOF
#!/usr/bin/env bash
if [[ \${*: -1} == usr/bin/lmm-api ]]; then
  printf 'readonly LMM_API_DEPLOY_PROTOCOL_MIN=1\nreadonly LMM_API_DEPLOY_PROTOCOL_MAX=1\n'
else
  printf '%s\n' "\${FAKE_EMBEDDED_REVISION:-$revision}"
fi
EOF
chmod 0700 "$tmp/fake-bin/pacman" "$tmp/fake-bin/bsdtar"

env_fixture="$tmp/lmm-api.env"
printf 'SQL_DSN=%s\n' 'postgresql://user:pass@127.0.0.1/db' >"$env_fixture"
"$here/prepare-production-backup.sh" --env-file "$env_fixture" --check-env-only >/dev/null
# shellcheck disable=SC2016
printf 'SQL_DSN=%s\n' '$(touch /tmp/lmm-api-env-parser-executed)' >"$env_fixture"
expect_fail "$here/prepare-production-backup.sh" --env-file "$env_fixture" --check-env-only
[[ ! -e /tmp/lmm-api-env-parser-executed ]] || fail 'malicious environment assignment executed'

expect_fail "$cli" "${base[@]}" --host ArchDmit
grep -Fq -- '--backend is required' "$tmp/err" || fail 'missing backend was not rejected'

expect_fail "$cli" "${base[@]}" --backend go --host wrong
grep -Fq -- 'unsupported target host/role' "$tmp/err" || fail 'host role mismatch was not rejected'

cat >"$tmp/fake-bin/ssh" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
printf '%s\n' "$*" >>"${FAKE_SSH_LOG:?}"
if [[ ${FAKE_SSH_REAL_SHELL:-0} == 1 && $* == *'bash -s -- confirm '* ]]; then
  args=("$@")
  for index in "${!args[@]}"; do
    if [[ ${args[$index]} == root@45.59.187.63 ]]; then
      remote=("${args[@]:index+1}")
      "${remote[@]}"
      exit
    fi
  done
  exit 65
fi
if [[ ${FAKE_CONFIRM_MODE:-0} == 1 ]]; then
  if [[ $* == *'--confirm-only'* ]]; then
    : >"${FAKE_CONFIRM_MARKER:?}"
    exit 0
  fi
  if [[ $* == *'/staging/status'* && $* == *' cat -- '* ]]; then
    [[ -f ${FAKE_CONFIRM_MARKER:?} ]] || exit 9
    printf 'CONFIRMED deployment=contract-test\n'
    exit 0
  fi
fi
if [[ $* == *'hostnamectl --static'* ]]; then printf 'arch-dmit\n'; exit 0; fi
printf 'role=production\nobserved_host=arch-dmit\nexpected_host=arch-dmit\nhost_match=true\ndb_engine=sqlite\n'
EOF
chmod 0700 "$tmp/fake-bin/ssh"
export PATH="$tmp/fake-bin:$PATH"
export FAKE_SSH_LOG="$tmp/ssh.log"
: >"$FAKE_SSH_LOG"
credential_side_effect_command="$tmp/credential-command-substitution"
credential_side_effect_backticks="$tmp/credential-backticks"
credential_side_effect_semicolon="$tmp/credential-semicolon"
malicious_credentials=(
  '/tmp/credential file'
  "/tmp/credential'quote"
  '/tmp/credential"quote'
  "/tmp/credential\$(touch $credential_side_effect_command)"
  "/tmp/credential\`touch $credential_side_effect_backticks\`"
  "/tmp/credential;touch $credential_side_effect_semicolon"
  $'/tmp/credential\nnewline'
  '/tmp/../credential'
  '/'
)
for malicious_credential in "${malicious_credentials[@]}"; do
  expect_fail env LMM_ACCEPTANCE_CREDENTIAL_FILE="$malicious_credential" \
    "$cli" "${base[@]}" --backend rs --host ArchDmit --jump-host archczy --execute-remote switch
  grep -Fq 'remote acceptance credential file path is unsafe' "$tmp/err" || \
    fail 'unsafe remote credential path did not fail at the controller boundary'
done
[[ ! -e $credential_side_effect_command && ! -e $credential_side_effect_backticks && \
  ! -e $credential_side_effect_semicolon ]] || fail 'unsafe credential path executed through a shell'
expect_fail env LMM_API_DEPLOY_TRANSACTION=db-disagreement \
  "$cli" "${base[@]}" --backend go --host ArchDmit --jump-host archczy --remote-inspect \
  --workspace "$tmp/db-workspace" inspect
grep -Fq -- 'database engine disagrees' "$tmp/err" || fail 'database disagreement was accepted'
grep -Fq -- "-F $tmp/ssh-config -J archczy -p 222 root@45.59.187.63" "$FAKE_SSH_LOG" || \
  fail 'controller SSH transport does not use the controlled config/jump/port/endpoint'
if grep -Eq 'StrictHostKeyChecking=no|UserKnownHostsFile=/dev/null|-F /dev/null' "$FAKE_SSH_LOG"; then
  fail 'controller SSH transport bypassed host-key or user configuration controls'
fi

expect_fail "$cli" "${base[@]}" --backend rs --host ArchDmit \
  --route-gate "$repo/apps/api-rust/tests/fixtures/routes/migration-gate.tsv"
grep -Fq -- 'Rust production routing gate rejected' "$tmp/err" || fail 'Rust internal-probes boundary was not enforced'
bad_gate="$tmp/route.gate"
cat >"$bad_gate" <<'EOF'
format=1
backend=rs
production_route=approved
migration=complete
route_parity=verified
database_engine=postgres
verified_host=arch-dmit
git_revision=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
EOF
expect_fail "$cli" "${base[@]}" --backend rs --host ArchDmit --route-gate "$bad_gate"

expect_fail "$cli" "${base[@]}" --backend go --host ArchDmit --confirm example.invalid
grep -Fq -- 'exact confirmation must be api.lmm.best' "$tmp/err" || fail 'confirmation naming was not exact'

grep -Fq '/usr/share/doc/lmm-api-bin/REVISION' "$core" || fail 'installed bin revision path is missing'
grep -Fq '/usr/share/doc/lmm-api-git/REVISION' "$core" || fail 'installed git revision path is missing'
if grep -Fq '/usr/share/doc/lmm-api/REVISION' "$core"; then
  fail 'stale generic installed revision path remains'
fi
installed_cli="$tmp/installed/usr/bin/lmm-api"
install -Dm0755 "$core" "$installed_cli"
installed_revision="$tmp/installed-REVISION"
printf '%s\n' "$revision" >"$installed_revision"
export LMM_API_DEPLOY_REVISION_PATH="$installed_revision"
installed_workspace="$tmp/installed-workspace"
expect_fail env FAKE_PACMAN_NO_OWNER=1 "$installed_cli" "${base[@]}" --frontend-only --host ArchDmit \
  --workspace "$installed_workspace" inspect
grep -Fq 'has no package owner' "$tmp/err" || fail 'source-less CLI accepted missing package ownership'
expect_fail env FAKE_PACMAN_OWNER=lmm-api-rs-bin "$installed_cli" "${base[@]}" --frontend-only --host ArchDmit \
  --workspace "$installed_workspace" inspect
grep -Fq 'owner is not an exact core package' "$tmp/err" || fail 'source-less CLI accepted the wrong package owner'
expect_fail env FAKE_PACMAN_QKK_FAIL=1 "$installed_cli" "${base[@]}" --frontend-only --host ArchDmit \
  --workspace "$installed_workspace" inspect
grep -Fq 'integrity check failed' "$tmp/err" || fail 'source-less CLI accepted failed pacman Qkk integrity'
"$installed_cli" "${base[@]}" --frontend-only --host ArchDmit \
  --workspace "$installed_workspace" inspect >/dev/null
expect_fail "$installed_cli" "${base[@]}" --frontend-only --host ArchDmit \
  --workspace "$installed_workspace" build
grep -Fq 'controller-source-only' "$tmp/err" || fail 'installed CLI did not refuse the source-only build'
if [[ ${LMM_DEPLOY_CONTRACT_STOP_AFTER_INSTALLED:-0} == 1 ]]; then
  printf 'canonical installed package authentication contract verified\n'
  exit 0
fi

workspace="$tmp/workspace"
flow=("${base[@]}" --backend rs --host ArchDmit --route-gate "$gate" --workspace "$workspace")
"$cli" "${flow[@]}" inspect >/dev/null
"$cli" "${flow[@]}" inspect >/dev/null
[[ $(<"$workspace/contract-test/state") == INSPECTED ]] || fail 'idempotent inspect changed state'
"$cli" "${flow[@]}" build >/dev/null
expect_fail "$cli" "${flow[@]}" inspect
grep -Fq 'phase requires exact state NEW; current state is BUILT' "$tmp/err" || \
  fail 'completed transaction regressed to inspection'
core_pkg="$tmp/lmm-api-bin-0.1.2-1.pkg.tar.zst"
backend_pkg="$tmp/lmm-api-rs-bin-0.1.2-1.pkg.tar.zst"
printf 'core-package-bytes\n' >"$core_pkg"
printf 'backend-package-bytes\n' >"$backend_pkg"
expect_fail env FAKE_EMBEDDED_REVISION=ffffffffffffffffffffffffffffffffffffffff \
  "$cli" "${flow[@]}" --core-package "$core_pkg" --backend-package "$backend_pkg" package
grep -Fq 'embedded package revisions disagree' "$tmp/err" || \
  fail 'embedded revision mismatch was accepted'
"$cli" "${flow[@]}" \
  --core-package "$core_pkg" --backend-package "$backend_pkg" package >/dev/null
make_backup_copy() {
  local role=$1 directory encrypted=false file kind size mode mtime configuration_file database_file
  directory="$tmp/backup-$role"
  [[ $role == controller || $role == off-host ]] && encrypted=true
  mkdir -m0700 "$directory"
  for kind in application frontend configuration database; do
    suffix=archive
    [[ $encrypted == true && ( $kind == configuration || $kind == database ) ]] && suffix=age
    file="$directory/$kind.$suffix"
    printf '%s-%s-backup\n' "$role" "$kind" >"$file"
    chmod 0600 "$file"
  done
  {
    printf 'format=1\ncreated_at_utc=%s\ndeployment_id=contract-test\n' "$(date -u +%FT%TZ)"
    printf 'copy_role=%s\ndeployment_role=production\nverified_host=arch-dmit\n' "$role"
    printf 'release_id=contract-test\nartifact_sha256=%s\ngit_revision=%s\n' \
      "$(sha256sum "$backend_pkg" | awk '{print $1}')" "$(git -C "$repo" rev-parse HEAD)"
    printf 'core_sha256=%s\nbackend_sha256=%s\n' \
      "$(sha256sum "$core_pkg" | awk '{print $1}')" "$(sha256sum "$backend_pkg" | awk '{print $1}')"
    printf 'database_engine=postgres\nservice_state=active\nfrontend_release=0.1.2\n'
    for kind in application frontend configuration database; do
      suffix=archive
      [[ $encrypted == true && ( $kind == configuration || $kind == database ) ]] && suffix=age
      file="$directory/$kind.$suffix"
      size=$(stat -c '%s' "$file")
      mode=$(stat -c '%a' "$file")
      mtime=$(date -u -d "@$(stat -c '%Y' "$file")" +%FT%TZ)
      printf '%s_file=%s.%s\n%s_size=%s\n%s_mode=%s\n%s_mtime_utc=%s\n' \
        "$kind" "$kind" "$suffix" "$kind" "$size" "$kind" "$mode" "$kind" "$mtime"
      if [[ $kind == configuration || $kind == database ]]; then
        printf '%s_encrypted=%s\n' "$kind" "$encrypted"
      fi
    done
  } >"$directory/manifest.env"
  configuration_file="$directory/configuration.$([[ $encrypted == true ]] && printf age || printf archive)"
  database_file="$directory/database.$([[ $encrypted == true ]] && printf age || printf archive)"
  sha256sum "$directory/application.archive" "$directory/frontend.archive" \
    "$configuration_file" "$database_file" | sed "s|$directory/||" >"$directory/SHA256SUMS"
}
make_backup_copy target
make_backup_copy controller
make_backup_copy off-host
printf 'corrupt\n' >>"$tmp/backup-controller/application.archive"
expect_fail "$cli" "${flow[@]}" \
  --target-backup "$tmp/backup-target" --controller-backup "$tmp/backup-controller" \
  --offhost-backup "$tmp/backup-off-host" backup
grep -Fq -- 'backup checksum verification failed: controller' "$tmp/err" || fail 'corrupt backup copy was accepted'
printf 'controller-application-backup\n' >"$tmp/backup-controller/application.archive"
touch -d "$(sed -n 's/^application_mtime_utc=//p' "$tmp/backup-controller/manifest.env")" \
  "$tmp/backup-controller/application.archive"
sha256sum "$tmp/backup-controller/application.archive" "$tmp/backup-controller/frontend.archive" \
  "$tmp/backup-controller/configuration.age" "$tmp/backup-controller/database.age" | \
  sed "s|$tmp/backup-controller/||" >"$tmp/backup-controller/SHA256SUMS"
"$cli" "${flow[@]}" \
  --target-backup "$tmp/backup-target" \
  --controller-backup "$tmp/backup-controller" \
  --offhost-backup "$tmp/backup-off-host" backup >/dev/null
printf 'substituted-after-backup\n' >>"$workspace/contract-test/core.pkg"
expect_fail "$cli" "${flow[@]}" watchdog
grep -Eq 'staged package identity changed|staged package bytes changed' "$tmp/err" || \
  fail 'post-backup package substitution was accepted'
printf 'core-package-bytes\n' >"$workspace/contract-test/core.pkg"
"$cli" "${flow[@]}" watchdog >/dev/null
embedded_activator="$workspace/contract-test/activate-rust-release.sh"
embedded_frontend="$workspace/contract-test/frontend-release.sh"
[[ -x $embedded_activator && -x $embedded_frontend ]] || fail 'canonical CLI did not extract its embedded target runtime'
bash -n "$embedded_activator" "$embedded_frontend" || fail 'embedded target runtime has syntax errors'
if grep -Eq 'resolve_deploy_helper|deploy/production/' "$embedded_activator" "$embedded_frontend"; then
  fail 'embedded target runtime retains a source-tree helper dependency'
fi
grep -Fq 'OnCalendar=@__LMM_ROLLBACK_DEADLINE_EPOCH__' "$workspace/contract-test/lmm-api-rollback.timer" || \
  fail 'watchdog does not use a switch-time absolute deadline'
grep -Fq 'Persistent=true' "$workspace/contract-test/lmm-api-rollback.timer" || fail 'watchdog is not persistent'
if grep -Eq 'OnBootSec|OnActiveSec' "$workspace/contract-test/lmm-api-rollback.timer"; then
  fail 'watchdog retains elapsed boot/activation timer semantics'
fi
grep -Fq 'replace_guard_field status ARMED ROLLING_BACK' "$embedded_activator" || \
  fail 'rollback does not CAS into an in-progress terminal state'
grep -Fq 'replace_guard_field status ROLLING_BACK ROLLED_BACK' "$embedded_activator" || \
  fail 'rollback does not durably complete its exact CAS transition'
grep -Fq 'acquire_terminal_mutex' "$embedded_activator" || \
  fail 'target terminal operations do not share a process mutex'
grep -Fq -- '--confirm-only' "$core" || fail 'controller confirmation does not use the target activator'
if grep -Eq -- '--login-smoke-test-script|LMM_LOGIN_TOKEN_(FILE|FD)|smoke-test.passed' "$core"; then
  fail 'legacy confirmation smoke-test contract remains'
fi
grep -Fq 'verify_rollback_state' "$embedded_activator" || \
  fail 'rollback does not verify terminal state'
grep -Fq 'ExecCondition=/usr/bin/grep -Eq ^status=(ARMED|ROLLING_BACK)$' "$core" || \
  fail 'rollback service lacks the resumable CAS state condition'
grep -Fq 'status=PREPARED' "$embedded_activator" || fail 'target guard is not prepared before switch'
grep -Fq 'systemctl enable --now lmm-api-rollback.timer' "$embedded_activator" || \
  fail 'persistent rollback timer is not enabled before target activation'
grep -Fq 'replace_guard_field status PREPARED ARMED' "$embedded_activator" || \
  fail 'switch does not arm the guard before mutation'
grep -Fq 'prepare_switch_watchdog' "$embedded_activator" || \
  fail 'switch does not refresh the persistent watchdog before arming'
grep -Fq '[.data.revision?, .data.version?]' "$embedded_activator" || \
  fail 'old rollback identity is not captured from live health'
# shellcheck disable=SC2016 # Match literal deployment variables in the CLI source.
if grep -Fq 'staging/backup-target' "$core"; then
  fail 'canonical CLI still mirrors the plaintext target backup into the controller workspace'
fi
# shellcheck disable=SC2016 # Match literal deployment variables in the CLI source.
grep -Fq '"$HOME/backup/lmm-api/arch-dmit/$transaction_id"' "$core" || \
  fail 'authoritative controller backup root is not enforced'
# shellcheck disable=SC2016 # Match literal deployment variables in the CLI source.
grep -Fq '"/var/backups/lmm-api/$transaction_id"' "$core" || \
  fail 'authoritative off-host backup root is not enforced'
reset_line=$(grep -n '^reset_watchdog_deadline$' "$embedded_activator" | tail -n1 | cut -d: -f1)
awaiting_line=$(grep -n 'write_status "AWAITING_CONFIRMATION' "$embedded_activator" | cut -d: -f1)
prepare_line=$(grep -n '^prepare_switch_watchdog$' "$embedded_activator" | cut -d: -f1)
baseline_line=$(grep -n '^  prepare_acceptance_baseline$' "$embedded_activator" | tail -n1 | cut -d: -f1)
verify_line=$(grep -n '^run_acceptance verify ' "$embedded_activator" | cut -d: -f1)
# shellcheck disable=SC2016 # Match the literal package variable in the activator source.
pacman_line=$(grep -n 'pacman -U --noconfirm "$CORE_PACKAGE"' "$embedded_activator" | cut -d: -f1)
preinstall_route_line=$(grep -n '^validate_preinstall_route_payloads$' "$embedded_activator" | cut -d: -f1)
postinstall_route_line=$(grep -n '^validate_installed_route_payload$' "$embedded_activator" | cut -d: -f1)
backend_config_line=$(grep -n "^printf '# Managed by lmm-api deployment" "$embedded_activator" | cut -d: -f1)
[[ $reset_line =~ ^[0-9]+$ && $awaiting_line =~ ^[0-9]+$ && $prepare_line =~ ^[0-9]+$ && \
  $baseline_line =~ ^[0-9]+$ && $verify_line =~ ^[0-9]+$ && \
  $pacman_line =~ ^[0-9]+$ && $preinstall_route_line =~ ^[0-9]+$ && \
  $postinstall_route_line =~ ^[0-9]+$ && $backend_config_line =~ ^[0-9]+$ && \
  $preinstall_route_line -lt $prepare_line && $pacman_line -gt $prepare_line && \
  $postinstall_route_line -gt $pacman_line && $backend_config_line -gt $postinstall_route_line && \
  $baseline_line -lt $prepare_line && $verify_line -gt $pacman_line && \
  $reset_line -gt $verify_line && $awaiting_line -gt $reset_line ]] || \
  fail 'acceptance/watchdog/switch ordering is invalid'
grep -Fq 'core-package-root' "$embedded_activator" || \
  fail 'target does not extract the SHA-pinned core package before installation'
grep -Fq 'canonical-preinstall' "$embedded_activator" || \
  fail 'target does not independently validate extracted canonical route assets'
grep -Fq 'installed-postinstall' "$embedded_activator" || \
  fail 'target does not rerun the installed route validator'
"$cli" "${flow[@]}" switch >/dev/null
expect_fail "$cli" "${flow[@]}" \
  --confirm wrong confirm
grep -Fq -- 'exact confirmation must be api.lmm.best' "$tmp/err" || fail 'confirm phase accepted a non-exact name'
expect_fail "$cli" "${flow[@]}" --confirm api.lmm.best confirm
grep -Fq 'real remote-switched transaction' "$tmp/err" || fail 'fake local confirmation was accepted'

printf 'target=arch-dmit\ndeployment_id=contract-test\n' >"$workspace/contract-test/remote-switched"
fake_remote_root="$tmp/fake-remote"
fake_remote_staging="$fake_remote_root/contract-test/staging"
mkdir -p "$fake_remote_staging"
cat >"$fake_remote_staging/activate-rust-release.sh" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
target_backup=
confirm_only=0
while (($#)); do
  case $1 in
    --confirm-only) confirm_only=1; shift ;;
    --target-backup) target_backup=$2; shift 2 ;;
    *) shift ;;
  esac
done
((confirm_only == 1))
printf '%s' "$target_backup" >"${FAKE_REMOTE_TARGET_BACKUP_LOG:?}"
: >"${FAKE_CONFIRM_MARKER:?}"
EOF
chmod 0700 "$fake_remote_staging/activate-rust-release.sh"
remote_command_side_effect="$tmp/remote-command-substitution"
remote_backtick_side_effect="$tmp/remote-backtick-substitution"
remote_semicolon_side_effect="$tmp/remote-semicolon"
remote_injection="/tmp/remote backup 'quoted' \"double\" \$(touch $remote_command_side_effect) \`touch $remote_backtick_side_effect\`;touch $remote_semicolon_side_effect"$'\n''still-one-argument'
export FAKE_CONFIRM_MODE=1 FAKE_CONFIRM_MARKER="$tmp/target-confirmed"
export FAKE_SSH_REAL_SHELL=1 FAKE_REMOTE_TARGET_BACKUP_LOG="$tmp/remote-target-backup.log"
export LMM_DEPLOY_TEST_REMOTE_ROOT="$fake_remote_root"
"$cli" "${flow[@]}" --execute-remote --jump-host archczy --confirm api.lmm.best \
  --target-backup "$remote_injection" confirm >/dev/null
[[ -f $FAKE_CONFIRM_MARKER ]] || fail 'controller advanced before target confirmation returned'
[[ $(<"$FAKE_REMOTE_TARGET_BACKUP_LOG") == "$remote_injection" ]] || \
  fail 'encoded remote value did not survive real remote-shell parsing exactly'
[[ ! -e $remote_command_side_effect && ! -e $remote_backtick_side_effect && \
  ! -e $remote_semicolon_side_effect ]] || fail 'encoded remote value executed through the remote shell'
[[ $(<"$workspace/contract-test/state") == CONFIRMED ]] || fail 'controller did not CAS after target confirmation'
expect_fail "$cli" "${flow[@]}" inspect
grep -Fq 'current state is CONFIRMED' "$tmp/err" || fail 'terminal state was allowed to regress'
[[ $(<"$workspace/contract-test/state") == CONFIRMED ]] || fail 'terminal state changed after rejected regression'

printf 'canonical deploy contract verified\n'
