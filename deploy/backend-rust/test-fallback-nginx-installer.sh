#!/usr/bin/env bash
# Fully mocked fault tests for the isolated fallback Nginx transaction.
set -Eeuo pipefail

HERE=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
readonly HERE
readonly INSTALLER=$HERE/install-fallback-nginx.sh
readonly VHOST=$HERE/nginx/fallback.lmm.best.conf
WORK=$(mktemp -d)
readonly WORK
cleanup() { local status=$?; rm -rf -- "$WORK"; exit "$status"; }
trap cleanup EXIT

fail() { printf 'test-fallback-nginx-installer: %s\n' "$*" >&2; exit 1; }

make_mocks() {
  local root=$1
  mkdir -p "$root/mock-bin" "$root/state"
  cat >"$root/mock-bin/nginx" <<'EOF'
#!/usr/bin/env bash
set -eu
count_file=$MOCK_STATE/nginx-count
count=$(($(cat "$count_file" 2>/dev/null || echo 0) + 1))
printf '%s\n' "$count" >"$count_file"
case "$*" in
  *-t*) if [[ ${MOCK_NGINX_T_FAIL_ON:-} == "$count" ]]; then exit 71; fi ;;
  *-s\ reload*) if [[ ${MOCK_NGINX_RELOAD_FAIL_ON:-} == "$count" ]]; then exit 72; fi ;;
esac
exit 0
EOF
  cat >"$root/mock-bin/curl" <<'EOF'
#!/usr/bin/env bash
set -eu
count_file=$MOCK_STATE/curl-count
count=$(($(cat "$count_file" 2>/dev/null || echo 0) + 1))
printf '%s\n' "$count" >"$count_file"
case "$*" in
  */_internal/build*) exit 22 ;;
  */livez*) [[ ${MOCK_CURL_LIVE_FAIL_ON:-} != "$count" ]] || exit 73 ;;
  */readyz*) [[ ${MOCK_CURL_READY_FAIL_ON:-} != "$count" ]] || exit 74 ;;
esac
exit 0
EOF
  cat >"$root/mock-bin/openssl" <<'EOF'
#!/usr/bin/env bash
set -eu
case "${1:-}" in
  rand)
    count_file=$MOCK_STATE/rand-count
    count=$(($(cat "$count_file" 2>/dev/null || echo 0) + 1))
    printf '%s\n' "$count" >"$count_file"
    printf '%016x\n' "$count"
    ;;
  x509)
    [[ ${MOCK_CERT_FAIL:-0} != 1 ]] || exit 75
    case " $* " in *' -pubkey '*) printf 'mock-public-key\n' ;; esac
    ;;
  pkey) printf 'mock-public-key\n' ;;
  *) exit 76 ;;
esac
EOF
  chmod +x "$root/mock-bin"/*
}

setup_case() {
  local name=$1
  local root=$WORK/$name
  mkdir -p "$root/assets/nginx" "$root/etc/nginx/conf.d" \
    "$root/etc/letsencrypt/live/fallback.lmm.best"
  cp -- "$VHOST" "$root/assets/nginx/fallback.lmm.best.conf"
  printf 'map old-safe\n' >"$root/assets/nginx/lmm-api-http-map.conf"
  printf 'types { text/plain txt; }\n' >"$root/assets/nginx/lmm-api-mime.types"
  printf 'certificate\n' >"$root/etc/letsencrypt/live/fallback.lmm.best/fullchain.pem"
  printf 'private-key\n' >"$root/etc/letsencrypt/live/fallback.lmm.best/privkey.pem"
  cat >"$root/guard" <<'EOF'
#!/usr/bin/env bash
[[ ${MOCK_GUARD_FAIL:-0} != 1 ]] || { printf 'machine-id mismatch\n' >&2; exit 69; }
printf '%s\n' "${HOSTNAME:-}" >>"${MOCK_STATE:?}/guard-hostnames"
EOF
  chmod +x "$root/guard"
  make_mocks "$root"
  printf 'old-map\n' >"$root/etc/nginx/lmm-api-http-map.conf"
  printf 'old-mime\n' >"$root/etc/nginx/lmm-api-mime.types"
  printf 'old-vhost\n' >"$root/etc/nginx/conf.d/fallback.lmm.best.conf"
  chmod 0640 "$root/etc/nginx/lmm-api-http-map.conf"
  chmod 0644 "$root/etc/nginx/lmm-api-mime.types"
  chmod 0600 "$root/etc/nginx/conf.d/fallback.lmm.best.conf"
  printf '%s\n' "$root"
}

run_installer() {
  local root=$1
  shift
  local -a overrides=()
  while (($#)) && [[ $1 == *=* ]]; do
    overrides+=("$1")
    shift
  done
  env PATH="$root/mock-bin:$PATH" MOCK_STATE="$root/state" LMM_RS_MOCK=1 \
    LMM_FALLBACK_NGINX_TEST_ROOT="$root" LMM_RS_ASSET_ROOT="$root/assets" \
    LMM_FALLBACK_TARGET_GUARD="$root/guard" "${overrides[@]}" "$INSTALLER" "$@"
}

snapshot() {
  local root=$1 relative target
  for relative in etc/nginx/lmm-api-http-map.conf etc/nginx/lmm-api-mime.types etc/nginx/conf.d/fallback.lmm.best.conf; do
    target=$root/$relative
    if [[ -e $target || -L $target ]]; then
      stat -c "$relative %F %a %u %g" "$target"
      [[ -f $target && ! -L $target ]] && sha256sum "$target"
    else
      printf '%s absent\n' "$relative"
    fi
  done
}

run_failure() {
  local root=$1 output=$2
  shift 2
  if run_installer "$root" "$@" install >"$output" 2>&1; then
    fail 'installer unexpectedly succeeded'
  fi
  return 0
}

# The config itself keeps internal release identity direct-loopback only.
grep -Fqx '    location = /_internal/build { return 404; }' "$VHOST"
[[ $(grep -Ec '^[[:space:]]*proxy_pass[[:space:]]+http://127\.0\.0\.1:3100;' "$VHOST") -eq 1 ]]
if grep -Fq 'api.lmm.best' "$VHOST"; then fail 'vhost mentions forbidden host'; fi
if grep -Fq 'systemctl' "$INSTALLER"; then fail 'nginx installer controls a service'; fi

# A machine-id rejection happens before the lock or backup roots are created.
root=$(setup_case machine-mismatch)
rm -rf -- "${root:?}/run" "${root:?}/var"
run_failure "$root" "$root/output" MOCK_GUARD_FAIL=1
[[ ! -e $root/run && ! -e $root/var ]]
grep -Fq 'machine-id mismatch' "$root/output" || { cat "$root/output" >&2; fail 'machine rejection diagnostic missing'; }

# Hostnames are data only: an arbitrary hostname succeeds when the guard does.
root=$(setup_case hostname-is-not-authority)
HOSTNAME=totally-unrelated run_installer "$root" install >/dev/null
grep -Fxq 'totally-unrelated' "$root/state/guard-hostnames"

# Existing symlinks are rejected before backup and candidate mutation.
root=$(setup_case symlink)
rm -- "$root/etc/nginx/lmm-api-http-map.conf"
ln -s /missing "$root/etc/nginx/lmm-api-http-map.conf"
before=$(snapshot "$root")
run_failure "$root" "$root/output"
[[ $before == "$(snapshot "$root")" ]]
grep -Fq 'unsafe existing target' "$root/output"

# Candidate host and TLS failures are rejected before any managed target moves.
for scenario in bad-server cert; do
  root=$(setup_case "$scenario")
  before=$(snapshot "$root")
  if [[ $scenario == bad-server ]]; then
    sed -i '0,/server_name fallback.lmm.best;/s//server_name not-fallback.example;/' "$root/assets/nginx/fallback.lmm.best.conf"
    run_failure "$root" "$root/output"
    grep -Fq 'server_name' "$root/output"
  else
    run_failure "$root" "$root/output" MOCK_CERT_FAIL=1
    grep -Fq 'certificate does not match' "$root/output"
  fi
  [[ $before == "$(snapshot "$root")" ]]
done

# Nginx syntax, reload, and SNI health failures restore content and metadata.
for scenario in nginx-t reload probe; do
  root=$(setup_case "$scenario")
  before=$(snapshot "$root")
  case $scenario in
    nginx-t) run_failure "$root" "$root/output" MOCK_NGINX_T_FAIL_ON=1 ;;
    reload) run_failure "$root" "$root/output" MOCK_NGINX_RELOAD_FAIL_ON=2 ;;
    probe) run_failure "$root" "$root/output" MOCK_CURL_LIVE_FAIL_ON=1 ;;
  esac
  [[ $before == "$(snapshot "$root")" ]] || fail "$scenario did not restore byte-identically"
  grep -Fq 'byte-identical previous configuration restored and verified' "$root/output"
done

# Rollback restores a retained manifest and never invokes a service manager.
root=$(setup_case rollback)
run_installer "$root" install >"$root/install-output" 2>&1
backup_id=$(sed -n 's/.*backup=\([-A-Za-z0-9._]*\).*/\1/p' "$root/install-output")
[[ -n $backup_id ]]
printf 'mutated\n' >"$root/etc/nginx/lmm-api-http-map.conf"
run_installer "$root" rollback "$backup_id" >/dev/null
grep -Fxq 'old-map' "$root/etc/nginx/lmm-api-http-map.conf"
before=$(snapshot "$root")
if run_installer "$root" rollback does-not-exist >"$root/unknown-output" 2>&1; then
  fail 'unknown rollback release unexpectedly succeeded'
fi
[[ $before == "$(snapshot "$root")" ]]
grep -Fq 'unknown or unsafe backup release' "$root/unknown-output"

printf 'fallback nginx installer fault tests passed\n'
