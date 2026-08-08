#!/usr/bin/env bash
set -Eeuo pipefail

here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
cli="$here/lmm-api-launcher"
service="$here/lmm-api.service"
repo=$(cd -- "$here/../../.." && pwd -P)
fail() { printf 'cli-contract: %s\n' "$*" >&2; exit 1; }

tmp=$(mktemp -d "${TMPDIR:-/tmp}/lmm-api-cli-contract.XXXXXXXX")
cleanup() { rm -rf -- "$tmp"; }
trap cleanup EXIT
mkdir -p "$tmp/backends/go" "$tmp/backends/rs" "$tmp/etc"

cat >"$tmp/provider" <<'PROVIDER'
#!/usr/bin/env bash
set -Eeuo pipefail
printf 'pid=%s\n' "$$" >"${LMM_TEST_STATE:?}/provider.state"
printf '%s\n' "$@" >"${LMM_TEST_STATE:?}/provider.args"
if [[ ${LMM_TEST_EXIT:-} =~ ^[0-9]+$ ]]; then exit "$LMM_TEST_EXIT"; fi
trap 'printf TERM >"$LMM_TEST_STATE/provider.signal"; exit 23' TERM
while :; do sleep 0.05; done
PROVIDER
chmod 0755 "$tmp/provider"
cp "$tmp/provider" "$tmp/backends/go/lmm-api"
cp "$tmp/provider" "$tmp/backends/rs/lmm-api-rs"
printf 'LMM_API_BACKEND=auto\n' >"$tmp/etc/backend.conf"

common_env=(env LMM_API_BACKEND_ROOT="$tmp/backends" LMM_API_BACKEND_CONFIG="$tmp/etc/backend.conf" LMM_TEST_STATE="$tmp")

set +e
LMM_TEST_EXIT=42 "${common_env[@]}" "$cli" serve alpha 'two words'
rc=$?
set -e
[[ $rc == 42 ]] || fail "provider exit status was not preserved: $rc"
mapfile -t args <"$tmp/provider.args"
[[ ${args[*]} == 'alpha two words' ]] || fail 'serve did not forward provider arguments exactly'

rm -f -- "$tmp/provider.state" "$tmp/provider.signal"
"${common_env[@]}" "$cli" serve signal-check &
launcher_pid=$!
for _ in {1..100}; do [[ -s $tmp/provider.state ]] && break; sleep 0.01; done
[[ $(sed -n 's/^pid=//p' "$tmp/provider.state") == "$launcher_pid" ]] || fail 'serve retained an intermediate launcher process'
kill -TERM "$launcher_pid"
set +e
wait "$launcher_pid"
rc=$?
set -e
[[ $rc == 23 && $(<"$tmp/provider.signal") == TERM ]] || fail 'serve did not propagate TERM/provider status'

"${common_env[@]}" "$cli" select rs >/dev/null
grep -Fqx 'LMM_API_BACKEND=rs' "$tmp/etc/backend.conf" || fail 'select rs did not persist the canonical configuration'
status=$("${common_env[@]}" "$cli" select status)
grep -Fqx 'configured=rs' <<<"$status" || fail 'select status omitted configured backend'
grep -Fqx 'resolved=rs' <<<"$status" || fail 'select status omitted resolved backend'

protocol=$("${common_env[@]}" "$cli" deploy internal protocol)
[[ $protocol == $'min=1\nmax=1' ]] || fail 'deployment protocol report is not stable'
help=$("${common_env[@]}" "$cli" help)
for command_name in serve select deploy; do
  grep -Fq "lmm-api $command_name" <<<"$help" || fail "help omits $command_name"
done
"${common_env[@]}" "$cli" deploy production --help >/dev/null
if "${common_env[@]}" "$cli" unknown >/dev/null 2>&1; then fail 'unknown command was accepted as a runtime entry'; fi

integrity_cli="$tmp/installed-lmm-api"
integrity_bin="$tmp/integrity-bin"
mkdir -p "$integrity_bin"
cp -- "$cli" "$integrity_cli"
chmod 0755 "$integrity_cli"
printf '0123456789abcdef\n' >"$tmp/integrity-revision"
cat >"$integrity_bin/pacman" <<'PACMAN'
#!/usr/bin/env bash
case "$1 $2" in
  '-Qqo --') printf 'lmm-api-bin\n' ;;
  '-Q lmm-api-bin') printf 'lmm-api-bin 1.2.3\n' ;;
  '-Qkk --') exit 1 ;;
  *) exit 1 ;;
esac
PACMAN
chmod 0755 "$integrity_bin/pacman"
set +e
PATH="$integrity_bin:$PATH" LMM_DEPLOY_TEST_MODE=1 \
  LMM_API_DEPLOY_REVISION_PATH="$tmp/integrity-revision" \
  "$integrity_cli" deploy production --frontend-only --host ArchDmit \
  --deployment-id integrity-fail --workspace "$tmp/integrity-work" preflight \
  >"$tmp/integrity-out" 2>"$tmp/integrity-err"
rc=$?
set -e
[[ $rc != 0 ]] || fail 'source-less deploy accepted failed package integrity'
grep -Fq 'installed core package integrity check failed' "$tmp/integrity-err" || \
  fail 'failed package integrity rejection was ambiguous'

watch_root="$tmp/watch-root"
watch_id=watch-contract
watch_work="$watch_root/$watch_id"
mkdir -p "$watch_work/state" "$watch_work/staging" "$tmp/target-backup"
chmod 0700 "$watch_root" "$watch_work" "$watch_work/state" "$watch_work/staging"
cat >"$watch_work/staging/activate-rust-release.sh" <<'WATCHDOG'
#!/usr/bin/env bash
printf '%s\n' "$@" >"${LMM_TEST_STATE:?}/watchdog.args"
WATCHDOG
chmod 0700 "$watch_work/staging/activate-rust-release.sh"
watch_sha=$(sha256sum "$watch_work/staging/activate-rust-release.sh" | awk '{print $1}')
cat >"$watch_work/.lmm-deploy-workspace" <<EOF
format=1
deployment_id=$watch_id
role=target
workspace=$watch_work
created_at_utc=2026-08-07T00:00:00Z
EOF
chmod 0600 "$watch_work/.lmm-deploy-workspace"
cat >"$watch_work/state/rollback.guard" <<EOF
deployment_id=$watch_id
target_backup=$tmp/target-backup
watchdog_runtime=$watch_work/staging/activate-rust-release.sh
watchdog_runtime_sha256=$watch_sha
git_revision=0123456789abcdef
new_frontend=releases/watch-contract
frontend_digest=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
core_sha256=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
backend_sha256=cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc
EOF
chmod 0600 "$watch_work/state/rollback.guard"
env LMM_DEPLOY_TEST_MODE=1 LMM_API_DEPLOY_WORKSPACE_ROOT="$watch_root" LMM_TEST_STATE="$tmp" \
  "$cli" deploy internal watchdog --deployment-id "$watch_id"
grep -Fqx -- '--rollback-only' "$tmp/watchdog.args" || fail 'watchdog did not exec the transaction runtime'
ln -s -- "$watch_root" "$tmp/watch-root-link"
if env LMM_DEPLOY_TEST_MODE=1 LMM_API_DEPLOY_WORKSPACE_ROOT="$tmp/watch-root-link" LMM_TEST_STATE="$tmp" \
    "$cli" deploy internal watchdog --deployment-id "$watch_id" >"$tmp/out" 2>"$tmp/err"; then
  fail 'watchdog accepted a symlinked workspace root parent'
fi
grep -Fq 'watchdog workspace path contains a symlink' "$tmp/err" || fail 'symlinked workspace root rejection was ambiguous'
mkdir -p "$tmp/watch-external/state" "$tmp/watch-external/staging"
ln -s -- "$tmp/watch-external" "$watch_root/escape-id"
if env LMM_DEPLOY_TEST_MODE=1 LMM_API_DEPLOY_WORKSPACE_ROOT="$watch_root" LMM_TEST_STATE="$tmp" \
    "$cli" deploy internal watchdog --deployment-id escape-id >"$tmp/out" 2>"$tmp/err"; then
  fail 'watchdog accepted a symlinked deployment directory'
fi
grep -Fq 'watchdog deployment path contains a symlink' "$tmp/err" || fail 'symlinked deployment rejection was ambiguous'
if env LMM_DEPLOY_TEST_MODE=1 LMM_API_DEPLOY_WORKSPACE_ROOT="$watch_root" LMM_TEST_STATE="$tmp" \
    "$cli" deploy internal watchdog --deployment-id "$watch_id" --workspace "$tmp" >"$tmp/out" 2>"$tmp/err"; then
  fail 'watchdog accepted an arbitrary workspace path'
fi
grep -Fq 'unknown internal deploy argument: --workspace' "$tmp/err" || fail 'watchdog path rejection was ambiguous'
printf '# tampered\n' >>"$watch_work/staging/activate-rust-release.sh"
if env LMM_DEPLOY_TEST_MODE=1 LMM_API_DEPLOY_WORKSPACE_ROOT="$watch_root" LMM_TEST_STATE="$tmp" \
    "$cli" deploy internal watchdog --deployment-id "$watch_id" >"$tmp/out" 2>"$tmp/err"; then
  fail 'watchdog accepted a tampered runtime'
fi
grep -Fq 'watchdog runtime checksum mismatch' "$tmp/err" || fail 'watchdog tamper rejection was ambiguous'
sed -i "s|^watchdog_runtime=.*|watchdog_runtime=$tmp/provider|" "$watch_work/state/rollback.guard"
if env LMM_DEPLOY_TEST_MODE=1 LMM_API_DEPLOY_WORKSPACE_ROOT="$watch_root" LMM_TEST_STATE="$tmp" \
    "$cli" deploy internal watchdog --deployment-id "$watch_id" >"$tmp/out" 2>"$tmp/err"; then
  fail 'watchdog accepted a runtime outside its transaction'
fi
grep -Fq 'watchdog runtime path is invalid' "$tmp/err" || fail 'watchdog runtime path rejection was ambiguous'

grep -Fqx 'ExecStart=/usr/bin/lmm-api serve' "$service" || fail 'systemd does not use the sole runtime entry'
for pkgbuild in "$repo/packaging/aur/lmm-api-bin/PKGBUILD" "$repo/packaging/aur/lmm-api-git/PKGBUILD"; do
  grep -Fq 'usr/bin/lmm-api"' "$pkgbuild" || fail "core package omits canonical CLI: $pkgbuild"
  if grep -Eq 'usr/bin/lmm-api-(deploy|select)' "$pkgbuild"; then fail "core package publishes a second CLI: $pkgbuild"; fi
done
if grep -Eq 'command -v lmm-api-(deploy|select)|deploy/production/lmm-api-deploy' "$cli"; then
  fail 'canonical CLI retains a public or source-tree fallback'
fi
grep -Fqx 'CORE_LAUNCHER=/usr/bin/lmm-api' "$cli" || fail 'embedded activation default is not the canonical CLI'
grep -Fq 'ExecStart=$CORE_LAUNCHER deploy internal watchdog --deployment-id' "$cli" || \
  fail 'embedded frontend watchdog does not use the authenticated CLI path'
grep -Fq 'ExecStart=__LMM_CLI__ deploy internal watchdog --deployment-id' "$cli" || \
  fail 'embedded backend watchdog template lacks the authenticated CLI placeholder'

printf 'canonical CLI contract verified\n'
