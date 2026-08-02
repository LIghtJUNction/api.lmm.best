#!/usr/bin/env bash
# Fault tests for the package-bound, single-instance fallback flow. Every
# privileged command is mocked; this file never invokes host services.
set -Eeuo pipefail

HERE=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
readonly HERE
readonly DEPLOY="$HERE/deploy-lmm-api-rs-single-instance.sh"
readonly SETUP="$HERE/install-lmm-api-rs-single-instance.sh"
readonly GUARD="$HERE/fallback-target-guard.sh"
readonly VHOST="$HERE/nginx/fallback.lmm.best.conf"

die() { printf 'test-single-instance: %s\n' "$*" >&2; exit 1; }

for file in "$DEPLOY" "$SETUP" "$GUARD" "$VHOST" "$HERE/test-instance.env.example"; do
  [[ -f $file && ! -L $file ]] || die "missing or unsafe asset: $file"
done
bash -n "$DEPLOY" "$SETUP" "$GUARD"
grep -Fq -- '--package /absolute/package.pkg.tar.zst --package-sha256' "$DEPLOY"
if grep -Eq -- '--artifact|--revision|--sha256' "$DEPLOY"; then die 'legacy deploy interface remains'; fi
grep -Fqx 'User=lmm-api-rs-fallback' "$HERE/lmm-api-rs-single.service"
grep -Fqx 'Group=lmm-api-rs-fallback' "$HERE/lmm-api-rs-single.service"
grep -Fqx 'Environment=LMM_RS_SLOT=single' "$HERE/lmm-api-rs-single.service"
grep -Fqx 'Environment=LMM_RS_LISTEN_ADDR=127.0.0.1:3100' "$HERE/lmm-api-rs-single.service"
grep -Fq 'lmm_test_runtime' "$HERE/test-instance.env.example"
grep -Fq ':6380/0' "$HERE/test-instance.env.example"
grep -Fq 'CRYPTO_SECRET=REPLACE_WITH_AT_LEAST_32_RANDOM_BYTES' "$HERE/test-instance.env.example"
grep -Fxq 'PASSWORD_LOGIN_ENABLED=true' "$HERE/test-instance.env.example"
grep -Eq '^[[:space:]]*server_name fallback\.lmm\.best;$' "$VHOST"
[[ $(grep -Ec '^[[:space:]]*server_name fallback\.lmm\.best;$' "$VHOST") -eq 2 ]]
if grep -Fq 'api.lmm.best' "$VHOST"; then die 'fallback vhost names the production host'; fi
[[ $(grep -Ec '^[[:space:]]*proxy_pass[[:space:]]+http://127\.0\.0\.1:3100;$' "$VHOST") -eq 1 ]]
grep -Fqx '    location = /_internal/build { return 404; }' "$VHOST"
grep -Fqx '    location = /livez { try_files /.__lmm_backend__ @fallback_lmm_api; }' "$VHOST"
grep -Fqx '    location = /readyz { try_files /.__lmm_backend__ @fallback_lmm_api; }' "$VHOST"

new_case() {
  local name=$1 root=$2 manifest binary_hash migrator_hash
  mkdir -p "$root/mock-bin" "$root/etc" "$root/installed/usr/lib/lmm-api-rs/bin" \
    "$root/installed/usr/share/lmm-api-rs" "$root/state"
  printf 'test-machine\n' >"$root/machine-id"
  manifest=$(printf '%s' "$name-manifest" | sha256sum | awk '{print $1}')
  install -m 0755 /bin/true "$root/installed/usr/lib/lmm-api-rs/bin/lmm-api-rs"
  install -m 0755 /bin/false "$root/installed/usr/lib/lmm-api-rs/bin/lmm-db-migrate"
  binary_hash=$(sha256sum "$root/installed/usr/lib/lmm-api-rs/bin/lmm-api-rs" | awk '{print $1}')
  migrator_hash=$(sha256sum "$root/installed/usr/lib/lmm-api-rs/bin/lmm-db-migrate" | awk '{print $1}')
  printf '%s\n' "$manifest" >"$root/installed/usr/share/lmm-api-rs/revision"
  printf '%s  %s\n%s  %s\n%s  %s\n' \
    "$binary_hash" "$root/installed/usr/lib/lmm-api-rs/bin/lmm-api-rs" \
    "$migrator_hash" "$root/installed/usr/lib/lmm-api-rs/bin/lmm-db-migrate" \
    "$(sha256sum "$root/installed/usr/share/lmm-api-rs/revision" | awk '{print $1}')" \
    "$root/installed/usr/share/lmm-api-rs/revision" >"$root/installed/usr/share/lmm-api-rs/payload.sha256"
  printf '%s\n' "$manifest" >"$root/installed/usr/share/lmm-api-rs/source-manifest"
  printf 'placeholder=1\n' >"$root/etc/common.env"
  printf 'LMM_RS_SLOT=single\nLMM_RS_LISTEN_ADDR=127.0.0.1:3100\n' >"$root/etc/single.env"
  chmod 0600 "$root/etc/common.env" "$root/etc/single.env"
  printf 'package fixture %s\n' "$name" >"$root/package.pkg.tar.zst"

  cat >"$root/mock-bin/pacman" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
case "${1:-}" in
  -Qp) printf '%s\n' 'lmm-api-rs-bin 9.9.9-1' ;;
  -U) exit 0 ;;
  -Qkk) exit 0 ;;
  -Q)
    if [[ ${2:-} == lmm-api-rs-bin ]]; then printf '%s\n' 'lmm-api-rs-bin 9.9.9-1'; else exit 1; fi
    ;;
  -Qoq) printf '%s\n' "${MOCK_PACMAN_OWNER:-lmm-api-rs-bin}" ;;
  *) exit 1 ;;
esac
EOF
  cat >"$root/mock-bin/systemctl" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
printf '%s\n' "$*" >>"$MOCK_LOG"
case ${1:-} in restart|is-active) exit 0 ;; *) exit 1 ;; esac
EOF
  cat >"$root/mock-bin/curl" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
case "$*" in
  */_internal/build*) printf '{"revision":"%s","slot":"single"}\n' "$MOCK_MANIFEST" ;;
  */livez|*/readyz) printf 'ok\n' ;;
  *) exit 1 ;;
esac
EOF
  chmod 0755 "$root/mock-bin"/*
  printf '%s\n' "$manifest" >"$root/manifest"
  printf '%s\n' "$binary_hash" >"$root/binary-hash"
}

run_deploy() {
  local root=$1
  shift
  local package="$root/package.pkg.tar.zst" package_hash
  package_hash=$(sha256sum "$package" | awk '{print $1}')
  env PATH="$root/mock-bin:$PATH" \
    LMM_RS_MOCK=1 LMM_RS_TEST_INSTANCE=1 \
    LMM_RS_GUARD_EXPECTED_MACHINE_ID_SHA256="${MOCK_EXPECTED_MACHINE_HASH:-$(sha256sum "$root/machine-id" | awk '{print $1}')}" \
    LMM_RS_GUARD_MACHINE_ID_FILE="$root/machine-id" \
    LMM_RS_SINGLE_ROOT="$root/release-root" LMM_RS_SINGLE_ETC_ROOT="$root/etc" \
    LMM_RS_SINGLE_STATE_ROOT="$root/state" \
    LMM_RS_INSTALLED_BINARY="$root/installed/usr/lib/lmm-api-rs/bin/lmm-api-rs" \
    LMM_RS_INSTALLED_MIGRATOR="$root/installed/usr/lib/lmm-api-rs/bin/lmm-db-migrate" \
    LMM_RS_INSTALLED_REVISION="$root/installed/usr/share/lmm-api-rs/revision" \
    LMM_RS_PAYLOAD_MANIFEST="$root/installed/usr/share/lmm-api-rs/payload.sha256" \
    LMM_RS_SOURCE_MANIFEST="$root/installed/usr/share/lmm-api-rs/source-manifest" \
    MOCK_LOG="$root/systemctl.log" MOCK_MANIFEST="$(<"$root/manifest")" \
    "$DEPLOY" --package "$package" --package-sha256 "$package_hash" "$@"
}

snapshot_current() {
  local root=$1
  if [[ -L $root/release-root/current ]]; then readlink "$root/release-root/current"; else printf 'absent\n'; fi
}

# Guard mismatch must happen before any release-root/state mutation.
root=$(mktemp -d "${TMPDIR:-/tmp}/lmm-single-guard.XXXXXX")
cleanup() { chmod -R u+w -- "$root" 2>/dev/null || true; rm -rf -- "$root"; }
trap cleanup EXIT
new_case guard "$root"
expected_machine_hash=$(sha256sum "$root/machine-id" | awk '{print $1}')
rm -f "$root/machine-id"
printf 'wrong-machine\n' >"$root/machine-id"
if MOCK_EXPECTED_MACHINE_HASH="$expected_machine_hash" run_deploy "$root" >/dev/null 2>&1; then die 'machine mismatch unexpectedly succeeded'; fi
[[ ! -e $root/release-root ]] || die 'guard mismatch mutated release state'

# An arbitrary hostname is irrelevant; the machine guard decides authorization.
printf 'test-machine\n' >"$root/machine-id"
HOSTNAME=attacker-controlled-name run_deploy "$root" >/dev/null
[[ $(snapshot_current "$root") == releases/$(<"$root/manifest") ]] || die 'prepare did not select current'

# Legacy interfaces are rejected, and a bad archive hash cannot change current.
before=$(snapshot_current "$root")
if env LMM_RS_TEST_INSTANCE=1 LMM_RS_MOCK=1 \
  LMM_RS_GUARD_EXPECTED_MACHINE_ID_SHA256="$(sha256sum "$root/machine-id" | awk '{print $1}')" \
  LMM_RS_GUARD_MACHINE_ID_FILE="$root/machine-id" "$DEPLOY" \
  --artifact /tmp/nope --sha256 deadbeef --revision old >/dev/null 2>&1; then
  die 'legacy arguments were accepted'
fi
bad_hash=0000000000000000000000000000000000000000000000000000000000000000
if env LMM_RS_TEST_INSTANCE=1 LMM_RS_MOCK=1 \
  LMM_RS_GUARD_EXPECTED_MACHINE_ID_SHA256="$(sha256sum "$root/machine-id" | awk '{print $1}')" \
  LMM_RS_GUARD_MACHINE_ID_FILE="$root/machine-id" LMM_RS_SINGLE_ROOT="$root/release-root" \
  LMM_RS_SINGLE_ETC_ROOT="$root/etc" "$DEPLOY" --package "$root/package.pkg.tar.zst" \
  --package-sha256 "$bad_hash" >/dev/null 2>&1; then
  die 'bad archive hash unexpectedly succeeded'
fi
[[ $(snapshot_current "$root") == "$before" ]] || die 'archive failure changed current'

# A package database ownership lie is rejected before the release pointer moves.
if MOCK_PACMAN_OWNER=unexpected-owner run_deploy "$root" >/dev/null 2>&1; then
  die 'ownership failure unexpectedly succeeded'
fi
[[ $(snapshot_current "$root") == "$before" ]] || die 'ownership failure changed current'

# Payload and source-manifest failures both leave current untouched.
for failure in payload manifest; do
  root2=$(mktemp -d "${TMPDIR:-/tmp}/lmm-single-$failure.XXXXXX")
  new_case "$failure" "$root2"
  run_deploy "$root2" >/dev/null
  before=$(snapshot_current "$root2")
  if [[ $failure == payload ]]; then
    printf '%064d  /usr/lib/lmm-api-rs/bin/lmm-api-rs\n' 0 >"$root2/installed/usr/share/lmm-api-rs/payload.sha256"
  else
    printf '%064d\n' 1 >"$root2/installed/usr/share/lmm-api-rs/source-manifest"
  fi
if run_deploy "$root2" >/dev/null 2>&1; then die "$failure failure unexpectedly succeeded"; fi
  [[ $(snapshot_current "$root2") == "$before" ]] || die "$failure failure changed current"
  chmod -R u+w -- "$root2" 2>/dev/null || true
  rm -rf -- "$root2"
done

# Activation is limited to the single service and never nginx.
: >"$root/systemctl.log"
run_deploy "$root" --activate >/dev/null
grep -Fqx 'restart lmm-api-rs-single.service' "$root/systemctl.log"
grep -Fqx 'is-active --quiet lmm-api-rs-single.service' "$root/systemctl.log"
if grep -Eiq 'nginx|blue|green' "$root/systemctl.log"; then die 'activation touched a non-singleton service'; fi

# Rollback may select only the metadata-recorded prior release and restarts the
# same one service; it never reloads nginx.
second_manifest=$(printf 'second-manifest' | sha256sum | awk '{print $1}')
install -m 0755 /bin/false "$root/installed/usr/lib/lmm-api-rs/bin/lmm-api-rs"
printf '%s\n' "$second_manifest" >"$root/installed/usr/share/lmm-api-rs/revision"
printf '%s\n' "$second_manifest" >"$root/installed/usr/share/lmm-api-rs/source-manifest"
printf '%s  %s\n%s  %s\n%s  %s\n' \
  "$(sha256sum "$root/installed/usr/lib/lmm-api-rs/bin/lmm-api-rs" | awk '{print $1}')" "$root/installed/usr/lib/lmm-api-rs/bin/lmm-api-rs" \
  "$(sha256sum "$root/installed/usr/lib/lmm-api-rs/bin/lmm-db-migrate" | awk '{print $1}')" "$root/installed/usr/lib/lmm-api-rs/bin/lmm-db-migrate" \
  "$(sha256sum "$root/installed/usr/share/lmm-api-rs/revision" | awk '{print $1}')" "$root/installed/usr/share/lmm-api-rs/revision" \
  >"$root/installed/usr/share/lmm-api-rs/payload.sha256"
run_deploy "$root" >/dev/null
[[ $(snapshot_current "$root") == "releases/$second_manifest" ]] || die 'second prepared release was not selected'
: >"$root/systemctl.log"
env PATH="$root/mock-bin:$PATH" LMM_RS_MOCK=1 LMM_RS_TEST_INSTANCE=1 \
  LMM_RS_GUARD_EXPECTED_MACHINE_ID_SHA256="$(sha256sum "$root/machine-id" | awk '{print $1}')" \
  LMM_RS_GUARD_MACHINE_ID_FILE="$root/machine-id" LMM_RS_SINGLE_ROOT="$root/release-root" \
  LMM_RS_SINGLE_ETC_ROOT="$root/etc" LMM_RS_SINGLE_STATE_ROOT="$root/state" MOCK_LOG="$root/systemctl.log" \
  MOCK_MANIFEST="$(<"$root/manifest")" \
  "$SETUP" rollback "$(<"$root/manifest")" >/dev/null
[[ $(snapshot_current "$root") == releases/$(<"$root/manifest") ]] || die 'verified rollback did not restore the prior release'
grep -Fqx 'restart lmm-api-rs-single.service' "$root/systemctl.log"
if grep -Eiq 'nginx|blue|green' "$root/systemctl.log"; then die 'rollback touched a non-singleton service'; fi

printf 'single-instance package/guard fault tests passed\n'
