#!/usr/bin/env bash
set -Eeuo pipefail

repo=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
installer=$repo/deploy/nginx/install-nginx-split.sh
work=$(mktemp -d)
trap 'rm -rf -- "$work"' EXIT

make_mocks() {
  local root=$1
  mkdir -p "$root/mock-bin" "$root/state"
  cat >"$root/mock-bin/nginx" <<'EOF'
#!/usr/bin/env bash
count_file=$MOCK_STATE/nginx-count
count=$(($(cat "$count_file" 2>/dev/null || echo 0) + 1))
printf '%s\n' "$count" >"$count_file"
case ",${MOCK_NGINX_FAIL_COUNTS:-}," in *,"$count",*) exit 42 ;; esac
exit 0
EOF
  cat >"$root/mock-bin/systemctl" <<'EOF'
#!/usr/bin/env bash
if [[ $1 == reload ]]; then
  count_file=$MOCK_STATE/reload-count
  count=$(($(cat "$count_file" 2>/dev/null || echo 0) + 1))
  printf '%s\n' "$count" >"$count_file"
  case ",${MOCK_RELOAD_FAIL_COUNTS:-}," in *,"$count",*) exit 43 ;; esac
fi
exit 0
EOF
  cat >"$root/mock-bin/mv" <<'EOF'
#!/usr/bin/env bash
count_file=$MOCK_STATE/mv-count
count=$(($(cat "$count_file" 2>/dev/null || echo 0) + 1))
printf '%s\n' "$count" >"$count_file"
case ",${MOCK_MV_FAIL_COUNTS:-}," in *,"$count",*) exit 44 ;; esac
exec /usr/bin/mv "$@"
EOF
  chmod +x "$root/mock-bin"/*
}

setup_case() {
  local name=$1 root
  root=$work/$name
  mkdir -p "$root/etc/nginx/conf.d" "$root/run/lock" "$root/var/lib"
  printf 'old locations\n' >"$root/etc/nginx/lmm-api-locations.conf"
  printf 'old server\n' >"$root/etc/nginx/conf.d/new-api.conf"
  chmod 0640 "$root/etc/nginx/lmm-api-locations.conf"
  chmod 0600 "$root/etc/nginx/conf.d/new-api.conf"
  make_mocks "$root"
  printf '%s\n' "$root"
}

snapshot() {
  local root=$1 target
  for target in \
    etc/nginx/lmm-api-mime.types \
    etc/nginx/lmm-api-http-map.conf \
    etc/nginx/lmm-api-locations.conf \
    etc/nginx/lmm-api-region-policy.conf \
    etc/nginx/conf.d/lmm-api-rs-active-upstream.conf \
    etc/nginx/snippets/lmm-api-rs-probe-locations.conf \
    etc/nginx/conf.d/new-api.conf; do
    if [[ -e $root/$target || -L $root/$target ]]; then
      stat -c "$target %F %a %u %g" "$root/$target"
      [[ -f $root/$target && ! -L $root/$target ]] && sha256sum "$root/$target"
    else
      printf '%s absent\n' "$target"
    fi
  done
}

run_failure() {
  local root=$1 output=$2
  shift 2
  if env PATH="$root/mock-bin:$PATH" MOCK_STATE="$root/state" \
    LMM_NGINX_TEST_MODE=1 LMM_NGINX_TEST_ROOT="$root" "$@" \
    "$installer" install >"$output" 2>&1; then
    printf 'expected installer failure\n' >&2
    return 1
  fi
}

# Failure during the second candidate rename restores content, modes, and
# targets which were originally absent.
root=$(setup_case mid-move)
before=$(snapshot "$root")
run_failure "$root" "$root/output" env MOCK_MV_FAIL_COUNTS=3
after=$(snapshot "$root")
[[ $before == "$after" ]]
grep -Fq 'candidate failed (44); previous nginx configuration restored and verified' "$root/output"

# Candidate syntax validation and reload failures both restore exactly.
for scenario in nginx-t reload; do
  root=$(setup_case "$scenario")
  before=$(snapshot "$root")
  if [[ $scenario == nginx-t ]]; then
    run_failure "$root" "$root/output" env MOCK_NGINX_FAIL_COUNTS=1
    grep -Fq 'candidate failed (42)' "$root/output"
  else
    run_failure "$root" "$root/output" env MOCK_RELOAD_FAIL_COUNTS=1
    grep -Fq 'candidate failed (43)' "$root/output"
  fi
  after=$(snapshot "$root")
  [[ $before == "$after" ]]
done

# A dangling symlink is unsafe existing state, never "absent".
root=$(setup_case dangling)
rm "$root/etc/nginx/lmm-api-locations.conf"
ln -s /missing/target "$root/etc/nginx/lmm-api-locations.conf"
before=$(snapshot "$root")
run_failure "$root" "$root/output" env
after=$(snapshot "$root")
[[ $before == "$after" ]]
grep -Fq 'unsafe existing target' "$root/output"

# Preserve the candidate's first error even if restoration independently fails.
root=$(setup_case double-failure)
run_failure "$root" "$root/output" env MOCK_RELOAD_FAIL_COUNTS=1 MOCK_NGINX_FAIL_COUNTS=2
grep -Fq 'candidate failed (43) and restore verification failed (42)' "$root/output"

# An active Rust upstream is transaction-owned and must survive a general nginx update.
root=$(setup_case active-rust-upstream)
cat >"$root/etc/nginx/conf.d/lmm-api-rs-active-upstream.conf" <<'EOF'
upstream lmm_api_rs_active { server 127.0.0.1:3101; }
EOF
active_hash=$(sha256sum "$root/etc/nginx/conf.d/lmm-api-rs-active-upstream.conf")
env PATH="$root/mock-bin:$PATH" MOCK_STATE="$root/state" \
  LMM_NGINX_TEST_MODE=1 LMM_NGINX_TEST_ROOT="$root" "$installer" install >/dev/null 2>&1
[[ $active_hash == "$(sha256sum "$root/etc/nginx/conf.d/lmm-api-rs-active-upstream.conf")" ]]

printf 'nginx installer failure-injection tests passed\n'
