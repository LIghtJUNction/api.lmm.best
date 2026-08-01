#!/usr/bin/env bash
set -Eeuo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
readonly HERE
TMP=$(mktemp -d)
readonly TMP
export LMM_RS_DEPLOY_LOCK="$TMP/run/deploy.lock"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP"/{bin,etc,root,run,audit,nginx}
printf 'DATABASE_URL=x\nVALKEY_URL=x\nLMM_SCHEMA_CONTRACT=1\n' >"$TMP/etc/common.env"
cp "$HERE/blue.env" "$TMP/etc/blue.env"
cp "$HERE/green.env" "$TMP/etc/green.env"
printf '#!/usr/bin/env bash\nexit 0\n' >"$TMP/artifact"
chmod +x "$TMP/artifact"
sha=$(sha256sum "$TMP/artifact" | awk '{print $1}')
cat >"$TMP/nginx/upstream.conf" <<'EOF'
upstream lmm_api_rs_active {
    server 127.0.0.1:3100;
}
EOF

run_dry() {
    revision=${1:-abcdef123}
    LMM_TEST_MODE=1 LMM_RS_ROOT="$TMP/root" LMM_RS_ETC_ROOT="$TMP/etc" \
        LMM_RS_RUN_ROOT="$TMP/run" LMM_RS_AUDIT_ROOT="$TMP/audit" \
        LMM_RS_NGINX_UPSTREAM="$TMP/nginx/upstream.conf" \
        "$HERE/deploy-lmm-api-rs.sh" --artifact "$TMP/artifact" --sha256 "$sha" \
        --revision "$revision" --dry-run
}

output=$(run_dry)
grep -Fq 'production route ownership remains unchanged' <<<"$output"
grep -Rq '^DRY_RUN active=' "$TMP/audit"

# Empty-machine bootstrap uses disabled port 9 and deterministically selects blue.
sed -i 's/3100/9/' "$TMP/nginx/upstream.conf"
printf 'none\n' >"$TMP/root/active-slot"
run_dry abcdef122 >/dev/null
grep -Rq '^DRY_RUN active=none inactive=blue$' "$TMP/audit"
sed -i 's/:9;/:3100;/' "$TMP/nginx/upstream.conf"
printf 'blue\n' >"$TMP/root/active-slot"

wrong_sha=$(printf '%064d' 0)
if LMM_TEST_MODE=1 LMM_RS_ROOT="$TMP/root" LMM_RS_ETC_ROOT="$TMP/etc" \
    LMM_RS_RUN_ROOT="$TMP/run" LMM_RS_AUDIT_ROOT="$TMP/audit" \
    "$HERE/deploy-lmm-api-rs.sh" --artifact "$TMP/artifact" --sha256 "$wrong_sha" \
    --revision abcdef124 --dry-run >/dev/null 2>&1; then
    echo 'checksum fault was not rejected' >&2
    exit 1
fi

touch "$TMP/etc/production-routing.enabled"
if run_dry abcdef125 >/dev/null 2>&1; then
    echo 'unsupported production-routing gate was not rejected' >&2
    exit 1
fi

grep -Fq 'limit_except GET' "$HERE/nginx/lmm-api-rs-probe-locations.conf"
if grep -Eq 'proxy_next_upstream.*non_idempotent' "$HERE"/nginx/*.conf; then
    echo 'non-idempotent nginx retry is forbidden' >&2
    exit 1
fi

rm -f "$TMP/etc/production-routing.enabled"
mkdir -p "$TMP/root/slots/blue" "$TMP/root/slots/green"
printf 'blue\n' >"$TMP/root/active-slot"
cp "$TMP/nginx/upstream.conf" "$TMP/nginx/upstream.expected"
for command_name in nginx sleep; do
    if [[ $command_name == nginx ]]; then
        cat >"$TMP/bin/$command_name" <<'EOF'
#!/usr/bin/env bash
[[ ${1:-} != -T ]] || echo "location = /_internal/rust/readyz"
exit 0
EOF
    else
        printf '#!/usr/bin/env bash\nexit 0\n' >"$TMP/bin/$command_name"
    fi
    chmod +x "$TMP/bin/$command_name"
done
cat >"$TMP/bin/systemctl" <<'EOF'
#!/usr/bin/env bash
if [[ ${1:-} == is-active && ${3:-} != nginx ]]; then exit 3; fi
exit 0
EOF
chmod +x "$TMP/bin/systemctl"
cat >"$TMP/bin/curl" <<'EOF'
#!/usr/bin/env bash
url=${!#}
revision=${LMM_TEST_REVISION:-abcdef126}
if [[ $url == https://* && -n ${LMM_TEST_NGINX_SLOT:-} ]]; then
    slot=$LMM_TEST_NGINX_SLOT
elif [[ $url == *127.0.0.1:3100* ]]; then
    slot=blue
elif [[ $url == *127.0.0.1:3101* ]]; then
    slot=green
elif grep -q '127.0.0.1:3100' "${LMM_RS_NGINX_UPSTREAM:?}"; then
    slot=blue
else
    slot=green
fi
if [[ $url == https://*/build && ${LMM_TEST_STALE_CANARY_ONCE:-0} == 1 && \
    ! -e ${LMM_TEST_STALE_CANARY_MARKER:?} ]]; then
    touch "$LMM_TEST_STALE_CANARY_MARKER"
    [[ $slot == blue ]] && slot=green || slot=blue
fi
if [[ $url == */build ]]; then
    printf '{"version":"0.1.0","revision":"%s","slot":"%s"}\n' "$revision" "$slot"
else
    printf '{"status":"ok"}\n'
fi
EOF
chmod +x "$TMP/bin/curl"

# Atomic helper failures must abort cleanly; each mock fails exactly once.
for atomic_tool in cp sync mv; do
    cat >"$TMP/bin/$atomic_tool" <<EOF
#!/usr/bin/env bash
marker='$TMP/state-failed-$atomic_tool'
if [[ ! -e \"\$marker\" ]]; then touch \"\$marker\"; exit 75; fi
exec /usr/bin/$atomic_tool "\$@"
EOF
    chmod +x "$TMP/bin/$atomic_tool"
    if [[ $atomic_tool == cp ]]; then
        if PATH="$TMP/bin:$PATH" LMM_TEST_MODE=1 LMM_TEST_REVISION=abcdef150 \
            LMM_RS_ROOT="$TMP/root" LMM_RS_ETC_ROOT="$TMP/etc" LMM_RS_RUN_ROOT="$TMP/run" \
            LMM_RS_AUDIT_ROOT="$TMP/audit" LMM_RS_NGINX_UPSTREAM="$TMP/nginx/upstream.conf" \
            "$HERE/deploy-lmm-api-rs.sh" --artifact "$TMP/artifact" --sha256 "$sha" \
            --revision abcdef150 >/dev/null 2>&1; then
            echo 'atomic cp failure unexpectedly succeeded' >&2; exit 1
        fi
    else
        if PATH="$TMP/bin:$PATH" run_dry "abcdef15${atomic_tool:0:1}" >/dev/null 2>&1; then
            echo "atomic $atomic_tool failure unexpectedly succeeded" >&2; exit 1
        fi
    fi
    rm -f "$TMP/bin/$atomic_tool"
done

if PATH="$TMP/bin:$PATH" LMM_TEST_MODE=1 LMM_TEST_REVISION=abcdef126 LMM_DEPLOY_FAIL_AT=switch \
    LMM_RS_ROOT="$TMP/root" LMM_RS_ETC_ROOT="$TMP/etc" LMM_RS_RUN_ROOT="$TMP/run" \
    LMM_RS_AUDIT_ROOT="$TMP/audit" LMM_RS_NGINX_UPSTREAM="$TMP/nginx/upstream.conf" \
    "$HERE/deploy-lmm-api-rs.sh" --artifact "$TMP/artifact" --sha256 "$sha" \
    --revision abcdef126 >/dev/null 2>&1; then
    echo 'switch fault injection unexpectedly succeeded' >&2
    exit 1
fi
cmp "$TMP/nginx/upstream.expected" "$TMP/nginx/upstream.conf"
grep -Rq '^FAILED status=' "$TMP/audit"

# nginx reload is asynchronous: an old worker may answer the first TLS build
# canary. Deployment must retry until revision + slot converge.
rm -f "$TMP/state-stale-canary"
PATH="$TMP/bin:$PATH" LMM_TEST_MODE=1 LMM_TEST_REVISION=abcdef126 \
    LMM_TEST_STALE_CANARY_ONCE=1 LMM_TEST_STALE_CANARY_MARKER="$TMP/state-stale-canary" \
    LMM_RS_ROOT="$TMP/root" LMM_RS_ETC_ROOT="$TMP/etc" LMM_RS_RUN_ROOT="$TMP/run" \
    LMM_RS_AUDIT_ROOT="$TMP/audit" LMM_RS_NGINX_UPSTREAM="$TMP/nginx/upstream.conf" \
    "$HERE/deploy-lmm-api-rs.sh" --artifact "$TMP/artifact" --sha256 "$sha" \
    --revision abcdef126 >/dev/null
test -e "$TMP/state-stale-canary"
grep -Fxq green "$TMP/root/active-slot"

# An immutable revision may be reused only when its installed artifact hash matches.
mkdir -p "$TMP/root/releases/abcdef127"
printf 'different artifact\n' >"$TMP/root/releases/abcdef127/lmm-api-rs"
chmod +x "$TMP/root/releases/abcdef127/lmm-api-rs"
if PATH="$TMP/bin:$PATH" LMM_TEST_MODE=1 LMM_RS_ROOT="$TMP/root" LMM_RS_ETC_ROOT="$TMP/etc" \
    LMM_RS_RUN_ROOT="$TMP/run" LMM_RS_AUDIT_ROOT="$TMP/audit" \
    LMM_RS_NGINX_UPSTREAM="$TMP/nginx/upstream.conf" "$HERE/deploy-lmm-api-rs.sh" \
    --artifact "$TMP/artifact" --sha256 "$sha" --revision abcdef127 >/dev/null 2>&1; then
    echo 'immutable release overwrite was not rejected' >&2
    exit 1
fi

# A competing transaction must lose the shared deploy/routing lock.
/usr/bin/flock "$TMP/run/deploy.lock" /usr/bin/sleep 2 & lock_pid=$!
/usr/bin/sleep 0.1
if run_dry abcdef128 >/dev/null 2>&1; then
    echo 'concurrent deployment unexpectedly acquired the lock' >&2
    kill "$lock_pid" 2>/dev/null || true
    exit 1
fi
wait "$lock_pid"

# Model power loss after nginx reload: nginx is authoritative and reconcile repairs stale state.
sed -i 's/3100/3101/' "$TMP/nginx/upstream.conf"
printf 'blue\n' >"$TMP/root/active-slot"
printf 'old upstream backup\n' >"$TMP/audit/manual-backup"
manual_sha=$(sha256sum "$TMP/audit/manual-backup" | awk '{print $1}')
printf 'transaction=dead phase=PREPARED old=blue new=green revision=abcdef129 backup=%s upstream_sha=%s\n' \
    "$TMP/audit/manual-backup" "$manual_sha" >"$TMP/root/deploy-journal"
PATH="$TMP/bin:$PATH" LMM_TEST_MODE=1 LMM_TEST_REVISION=abcdef129 LMM_RS_ROOT="$TMP/root" LMM_RS_ETC_ROOT="$TMP/etc" \
    LMM_RS_RUN_ROOT="$TMP/run" LMM_RS_AUDIT_ROOT="$TMP/audit" \
    LMM_RS_NGINX_UPSTREAM="$TMP/nginx/upstream.conf" "$HERE/deploy-lmm-api-rs.sh" \
    --revision abcdef129 --reconcile-only >/dev/null
grep -Fxq green "$TMP/root/active-slot"
grep -Fq 'phase=COMMITTED slot=green' "$TMP/root/deploy-journal"
grep -Fq 'revision=abcdef129' "$TMP/root/deploy-journal"

# SIGKILL immediately after reload leaves stale state; the next transaction derives blue from nginx.
if PATH="$TMP/bin:$PATH" LMM_TEST_MODE=1 LMM_TEST_REVISION=abcdef130 LMM_DEPLOY_FAIL_AT=kill-after-reload \
    LMM_RS_ROOT="$TMP/root" LMM_RS_ETC_ROOT="$TMP/etc" LMM_RS_RUN_ROOT="$TMP/run" \
    LMM_RS_AUDIT_ROOT="$TMP/audit" LMM_RS_NGINX_UPSTREAM="$TMP/nginx/upstream.conf" \
    "$HERE/deploy-lmm-api-rs.sh" --artifact "$TMP/artifact" --sha256 "$sha" \
    --revision abcdef130 >/dev/null 2>&1; then
    echo 'SIGKILL injection unexpectedly completed' >&2
    exit 1
fi
grep -Fq '127.0.0.1:3100' "$TMP/nginx/upstream.conf"
grep -Fxq green "$TMP/root/active-slot"
PATH="$TMP/bin:$PATH" LMM_TEST_MODE=1 LMM_TEST_REVISION=abcdef130 LMM_RS_ROOT="$TMP/root" LMM_RS_ETC_ROOT="$TMP/etc" \
    LMM_RS_RUN_ROOT="$TMP/run" LMM_RS_AUDIT_ROOT="$TMP/audit" \
    LMM_RS_NGINX_UPSTREAM="$TMP/nginx/upstream.conf" "$HERE/deploy-lmm-api-rs.sh" \
    --revision abcdef131 --reconcile-only >/dev/null
grep -Fxq blue "$TMP/root/active-slot"

# SIGKILL before reload leaves a PREPARED journal and new file on disk; old runtime wins.
if PATH="$TMP/bin:$PATH" LMM_TEST_MODE=1 LMM_TEST_REVISION=abcdef130 LMM_TEST_NGINX_SLOT=blue \
    LMM_DEPLOY_FAIL_AT=kill-before-reload \
    LMM_RS_ROOT="$TMP/root" LMM_RS_ETC_ROOT="$TMP/etc" LMM_RS_RUN_ROOT="$TMP/run" \
    LMM_RS_AUDIT_ROOT="$TMP/audit" LMM_RS_NGINX_UPSTREAM="$TMP/nginx/upstream.conf" \
    "$HERE/deploy-lmm-api-rs.sh" --artifact "$TMP/artifact" --sha256 "$sha" \
    --revision abcdef130 >/dev/null 2>&1; then
    echo 'pre-reload SIGKILL injection unexpectedly completed' >&2
    exit 1
fi
grep -Fq '127.0.0.1:3101' "$TMP/nginx/upstream.conf"
PATH="$TMP/bin:$PATH" LMM_TEST_MODE=1 LMM_TEST_REVISION=abcdef130 LMM_TEST_NGINX_SLOT=blue \
    LMM_RS_ROOT="$TMP/root" LMM_RS_ETC_ROOT="$TMP/etc" LMM_RS_RUN_ROOT="$TMP/run" \
    LMM_RS_AUDIT_ROOT="$TMP/audit" LMM_RS_NGINX_UPSTREAM="$TMP/nginx/upstream.conf" \
    "$HERE/deploy-lmm-api-rs.sh" --revision abcdef133 --reconcile-only >/dev/null
grep -Fq '127.0.0.1:3100' "$TMP/nginx/upstream.conf"
grep -Fxq blue "$TMP/root/active-slot"

# Every failed old-route gate must restore and verify the new route, even at the same revision.
for rollback_fault in old-start old-reload old-canary; do
    cat >"$TMP/nginx/upstream.conf" <<'EOF'
upstream lmm_api_rs_active {
    server 127.0.0.1:3100;
}
EOF
    printf 'blue\n' >"$TMP/root/active-slot"
    rm -f "$TMP/root/deploy-journal"
    if PATH="$TMP/bin:$PATH" LMM_TEST_MODE=1 LMM_TEST_REVISION=abcdef140 \
        LMM_DEPLOY_FAIL_AT=switch LMM_ROLLBACK_FAIL_AT="$rollback_fault" \
        LMM_RS_ROOT="$TMP/root" LMM_RS_ETC_ROOT="$TMP/etc" LMM_RS_RUN_ROOT="$TMP/run" \
        LMM_RS_AUDIT_ROOT="$TMP/audit" LMM_RS_NGINX_UPSTREAM="$TMP/nginx/upstream.conf" \
        "$HERE/deploy-lmm-api-rs.sh" --artifact "$TMP/artifact" --sha256 "$sha" \
        --revision abcdef140 >/dev/null 2>&1; then
        echo "rollback fault $rollback_fault unexpectedly succeeded" >&2
        exit 1
    fi
    grep -Fq '127.0.0.1:3101' "$TMP/nginx/upstream.conf"
    grep -Fxq green "$TMP/root/active-slot"
    grep -Rq '^FAILED_RETAINED_NEW status=' "$TMP/audit"
done

# nginx-t failure during first installation restores both managed includes.
printf 'old upstream\n' >"$TMP/nginx/install-upstream.conf"
printf 'old locations\n' >"$TMP/nginx/install-locations.conf"
cp "$TMP/nginx/install-upstream.conf" "$TMP/nginx/install-upstream.expected"
cp "$TMP/nginx/install-locations.conf" "$TMP/nginx/install-locations.expected"
if PATH="$TMP/bin:$PATH" LMM_TEST_MODE=1 LMM_INSTALL_FAIL_AT=locations LMM_RS_ASSET_ROOT="$HERE" \
    LMM_RS_NGINX_SERVER_TEMPLATE="$HERE/../nginx/new-api.conf" LMM_RS_ROOT="$TMP/root" \
    LMM_RS_RUN_ROOT="$TMP/run" LMM_RS_NGINX_UPSTREAM="$TMP/nginx/install-upstream.conf" \
    LMM_RS_NGINX_LOCATIONS="$TMP/nginx/install-locations.conf" \
    "$HERE/install-nginx-rust-routing.sh" >/dev/null 2>&1; then
    echo 'second managed-file failure unexpectedly succeeded' >&2
    exit 1
fi
cmp "$TMP/nginx/install-upstream.expected" "$TMP/nginx/install-upstream.conf"
cmp "$TMP/nginx/install-locations.expected" "$TMP/nginx/install-locations.conf"
cat >"$TMP/bin/nginx" <<EOF
#!/usr/bin/env bash
count_file='$TMP/nginx/count'
count=0
[[ ! -f \"\$count_file\" ]] || read -r count <\"\$count_file\"
count=\$((count + 1)); printf '%s\n' \"\$count\" >\"\$count_file\"
((count > 1))
EOF
chmod +x "$TMP/bin/nginx"
if PATH="$TMP/bin:$PATH" LMM_TEST_MODE=1 LMM_RS_ASSET_ROOT="$HERE" \
    LMM_RS_NGINX_SERVER_TEMPLATE="$HERE/../nginx/new-api.conf" \
    LMM_RS_ROOT="$TMP/root" LMM_RS_RUN_ROOT="$TMP/run" \
    LMM_RS_NGINX_UPSTREAM="$TMP/nginx/install-upstream.conf" \
    LMM_RS_NGINX_LOCATIONS="$TMP/nginx/install-locations.conf" \
    "$HERE/install-nginx-rust-routing.sh" >/dev/null 2>&1; then
    echo 'nginx installer fault unexpectedly succeeded' >&2
    exit 1
fi
cmp "$TMP/nginx/install-upstream.expected" "$TMP/nginx/install-upstream.conf"
cmp "$TMP/nginx/install-locations.expected" "$TMP/nginx/install-locations.conf"
if find "$TMP/audit" -type f -name result ! -perm 0600 -print -quit | grep -q .; then
    echo 'audit result permissions are not 0600' >&2
    exit 1
fi
echo 'blue-green safety tests passed'
