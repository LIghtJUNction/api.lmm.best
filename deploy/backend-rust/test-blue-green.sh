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
grep -Fq 'DRY_RUN active=blue inactive=green' <<<"$output"

# A plan is usable on a not-yet-installed host without synthesizing any of the
# deployment roots. Keep all four write targets absent as explicit sentinels.
zero_write_root="$TMP/dry-zero/root"
zero_write_run="$TMP/dry-zero/run"
zero_write_audit="$TMP/dry-zero/audit"
zero_write_lock="$TMP/dry-zero/lock/deploy.lock"
zero_write_output=$(LMM_TEST_MODE=1 LMM_RS_ROOT="$zero_write_root" LMM_RS_ETC_ROOT="$TMP/etc" \
    LMM_RS_RUN_ROOT="$zero_write_run" LMM_RS_AUDIT_ROOT="$zero_write_audit" \
    LMM_RS_DEPLOY_LOCK="$zero_write_lock" LMM_RS_NGINX_UPSTREAM="$TMP/nginx/upstream.conf" \
    "$HERE/deploy-lmm-api-rs.sh" --artifact "$TMP/artifact" --sha256 "$sha" \
    --revision abcdef119 --dry-run)
grep -Fq 'DRY_RUN active=blue inactive=green' <<<"$zero_write_output"
[[ ! -e $zero_write_root && ! -e $zero_write_run && ! -e $zero_write_audit && ! -e ${zero_write_lock%/*} ]] || {
    echo 'dry-run created an empty-host deployment root' >&2
    exit 1
}

make_command_poison() {
    command_name=$1 poison_dir=$2 marker=$3
    mkdir -p "$poison_dir"
    cat >"$poison_dir/$command_name" <<EOF
#!/usr/bin/env bash
printf '%s\\n' "\$0" >>'$marker'
exit 97
EOF
    chmod +x "$poison_dir/$command_name"
}

# A dry-run is a true zero-write plan: it must not create audit/run/root/lock
# state, repair a PREPARED journal, or invoke any side-effect command.
dry_poison_root="$TMP/dry-poison/root"
dry_poison_dir="$TMP/dry-poison/bin"
dry_poison_marker="$TMP/dry-poison/commands-called"
mkdir -p "$dry_poison_root" "$TMP/dry-poison/etc"
cp "$TMP/etc/common.env" "$TMP/dry-poison/etc/common.env"
cp "$TMP/etc/blue.env" "$TMP/dry-poison/etc/blue.env"
cp "$TMP/etc/green.env" "$TMP/dry-poison/etc/green.env"
printf 'transaction=stale phase=PREPARED\n' >"$dry_poison_root/deploy-journal"
cp "$dry_poison_root/deploy-journal" "$TMP/dry-poison/journal.expected"
for command_name in mkdir chmod tee flock systemctl nginx curl cp; do
    make_command_poison "$command_name" "$dry_poison_dir" "$dry_poison_marker"
done
dry_output=$(PATH="$dry_poison_dir:$PATH" LMM_TEST_MODE=1 LMM_RS_ROOT="$dry_poison_root" \
    LMM_RS_ETC_ROOT="$TMP/dry-poison/etc" LMM_RS_RUN_ROOT="$TMP/dry-poison/run" \
    LMM_RS_AUDIT_ROOT="$TMP/dry-poison/audit" \
    LMM_RS_DEPLOY_LOCK="$TMP/dry-poison/lock/deploy.lock" \
    LMM_RS_NGINX_UPSTREAM="$TMP/nginx/upstream.conf" \
    "$HERE/deploy-lmm-api-rs.sh" --artifact "$TMP/artifact" --sha256 "$sha" \
    --revision abcdef120 --dry-run)
grep -Fq 'DRY_RUN active=blue inactive=green' <<<"$dry_output"
[[ ! -e $dry_poison_marker ]] || {
    echo 'dry-run invoked a reconcile/restart/reload/switch command' >&2
    exit 1
}
cmp "$TMP/dry-poison/journal.expected" "$dry_poison_root/deploy-journal"
[[ ! -e $dry_poison_root/active-slot ]] || {
    echo 'dry-run reconciled active-slot state' >&2
    exit 1
}
[[ ! -e $TMP/dry-poison/run && ! -e $TMP/dry-poison/audit && ! -e $TMP/dry-poison/lock ]] || {
    echo 'dry-run created run, audit, or lock state' >&2
    exit 1
}

# The production interlock fails before it creates deployment state, touches
# the managed upstream, starts a slot, or invokes nginx/systemd.  The normal
# local harness bypasses it only so the historical fault matrix can remain
# focused on rollback mechanics; this explicit mode exercises the real guard.
original_upstream="$TMP/nginx/upstream.conf"
for interlock_case in missing wrong; do
    interlock_root="$TMP/interlock-$interlock_case/root"
    interlock_run="$TMP/interlock-$interlock_case/run"
    interlock_audit="$TMP/interlock-$interlock_case/audit"
    interlock_args=()
    interlock_env=()
    if [[ $interlock_case == wrong ]]; then
        interlock_args=(--approve-cutover --cutover-target internal-probes --cutover-revision abcdef121)
        interlock_env=(LMM_RS_CUTOVER_APPROVAL=wrong-approval)
    fi
    if env LMM_TEST_MODE=1 LMM_TEST_ENFORCE_CUTOVER_INTERLOCK=1 "${interlock_env[@]}" \
        LMM_RS_ROOT="$interlock_root" LMM_RS_ETC_ROOT="$TMP/etc" \
        LMM_RS_RUN_ROOT="$interlock_run" LMM_RS_AUDIT_ROOT="$interlock_audit" \
        LMM_RS_NGINX_UPSTREAM="$original_upstream" "$HERE/deploy-lmm-api-rs.sh" \
        --artifact "$TMP/artifact" --sha256 "$sha" --revision abcdef121 "${interlock_args[@]}" \
        >/dev/null 2>&1; then
        echo "cutover interlock $interlock_case approval unexpectedly succeeded" >&2
        exit 1
    fi
    [[ ! -e $interlock_root && ! -e $interlock_run && ! -e $interlock_audit ]] || {
        echo "cutover interlock $interlock_case mutated deployment state" >&2
        exit 1
    }
    grep -Fq '127.0.0.1:3100' "$original_upstream"
done

# A syntactically correct approval is not enough: a mismatched revision must
# stop before mkdir/audit/lock creation or any nginx/systemd path is reached.
# Poison each command that would begin those side effects and use absent roots
# as sentinels, including the lock parent (the shell would create it only after
# the approval guard has returned).
revision_poison_dir="$TMP/interlock-wrong-revision/bin"
revision_poison_marker="$TMP/interlock-wrong-revision/commands-called"
for command_name in mkdir tee flock nginx systemctl systemd-run; do
    make_command_poison "$command_name" "$revision_poison_dir" "$revision_poison_marker"
done
revision_root="$TMP/interlock-wrong-revision/root"
revision_run="$TMP/interlock-wrong-revision/run"
revision_audit="$TMP/interlock-wrong-revision/audit"
revision_lock="$TMP/interlock-wrong-revision/lock/deploy.lock"
if PATH="$revision_poison_dir:$PATH" LMM_TEST_MODE=1 LMM_TEST_ENFORCE_CUTOVER_INTERLOCK=1 \
    LMM_RS_CUTOVER_APPROVAL=GO_FREEZE_OVERRIDE_INTERNAL_PROBES \
    LMM_RS_ROOT="$revision_root" LMM_RS_ETC_ROOT="$TMP/etc" \
    LMM_RS_RUN_ROOT="$revision_run" LMM_RS_AUDIT_ROOT="$revision_audit" \
    LMM_RS_DEPLOY_LOCK="$revision_lock" LMM_RS_NGINX_UPSTREAM="$original_upstream" \
    "$HERE/deploy-lmm-api-rs.sh" --artifact "$TMP/artifact" --sha256 "$sha" \
    --revision abcdef121 --approve-cutover --cutover-target internal-probes \
    --cutover-revision abcdef122 >/dev/null 2>&1; then
    echo 'cutover interlock accepted a wrong revision confirmation' >&2
    exit 1
fi
[[ ! -e $revision_poison_marker ]] || {
    echo 'wrong revision reached a deployment side-effect command' >&2
    exit 1
}
[[ ! -e $revision_root && ! -e $revision_run && ! -e $revision_audit && ! -e ${revision_lock%/*} ]] || {
    echo 'wrong revision created deployment, audit, run, or lock state' >&2
    exit 1
}
grep -Fq '127.0.0.1:3100' "$original_upstream"

# Empty-machine bootstrap uses disabled port 9 and deterministically selects blue.
sed -i 's/3100/9/' "$TMP/nginx/upstream.conf"
printf 'none\n' >"$TMP/root/active-slot"
run_dry abcdef122 >/dev/null
run_dry_output=$(run_dry abcdef122)
grep -Fq 'DRY_RUN active=none inactive=blue' <<<"$run_dry_output"
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

# The production-routing marker is checked before every mutating/reconcile
# path.  Neither a normal deploy nor a PREPARED recovery may create state or
# invoke routing/runtime commands while it exists.
marker_poison_dir="$TMP/marker-poison/bin"
marker_poison_marker="$TMP/marker-poison/commands-called"
for command_name in mkdir curl systemctl nginx flock; do
    make_command_poison "$command_name" "$marker_poison_dir" "$marker_poison_marker"
done
marker_root="$TMP/marker-poison/ordinary-root"
marker_run="$TMP/marker-poison/ordinary-run"
marker_audit="$TMP/marker-poison/ordinary-audit"
marker_lock="$TMP/marker-poison/ordinary-lock/deploy.lock"
if PATH="$marker_poison_dir:$PATH" LMM_TEST_MODE=1 LMM_RS_ROOT="$marker_root" LMM_RS_ETC_ROOT="$TMP/etc" \
    LMM_RS_RUN_ROOT="$marker_run" LMM_RS_AUDIT_ROOT="$marker_audit" LMM_RS_DEPLOY_LOCK="$marker_lock" \
    LMM_RS_NGINX_UPSTREAM="$TMP/nginx/upstream.conf" "$HERE/deploy-lmm-api-rs.sh" \
    --artifact "$TMP/artifact" --sha256 "$sha" --revision abcdef125 >/dev/null 2>&1; then
    echo 'production-routing marker allowed an ordinary deploy' >&2
    exit 1
fi
[[ ! -e $marker_poison_marker && ! -e $marker_root && ! -e $marker_run && ! -e $marker_audit && ! -e ${marker_lock%/*} ]] || {
    echo 'production-routing marker allowed ordinary deploy side effects' >&2
    exit 1
}
marker_reconcile_root="$TMP/marker-poison/reconcile-root"
mkdir -p "$marker_reconcile_root"
printf 'transaction=blocked phase=PREPARED old=blue new=green revision=abcdef125 backup=/not/used upstream_sha=%064d\n' 0 >"$marker_reconcile_root/deploy-journal"
cp "$marker_reconcile_root/deploy-journal" "$marker_reconcile_root/deploy-journal.expected"
marker_reconcile_run="$TMP/marker-poison/reconcile-run"
marker_reconcile_audit="$TMP/marker-poison/reconcile-audit"
marker_reconcile_lock="$TMP/marker-poison/reconcile-lock/deploy.lock"
if PATH="$marker_poison_dir:$PATH" LMM_TEST_MODE=1 LMM_RS_ROOT="$marker_reconcile_root" LMM_RS_ETC_ROOT="$TMP/etc" \
    LMM_RS_RUN_ROOT="$marker_reconcile_run" LMM_RS_AUDIT_ROOT="$marker_reconcile_audit" LMM_RS_DEPLOY_LOCK="$marker_reconcile_lock" \
    LMM_RS_NGINX_UPSTREAM="$TMP/nginx/upstream.conf" "$HERE/deploy-lmm-api-rs.sh" \
    --revision abcdef125 --reconcile-only >/dev/null 2>&1; then
    echo 'production-routing marker allowed PREPARED reconciliation' >&2
    exit 1
fi
cmp "$marker_reconcile_root/deploy-journal.expected" "$marker_reconcile_root/deploy-journal"
[[ ! -e $marker_poison_marker && ! -e $marker_reconcile_run && ! -e $marker_reconcile_audit && ! -e ${marker_reconcile_lock%/*} ]] || {
    echo 'production-routing marker allowed reconcile side effects' >&2
    exit 1
}

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

# Detached deployment must pass the one-shot approval through systemd exactly;
# this fake captures argv and never executes the child transaction.
systemd_capture="$TMP/systemd-run.args"
cat >"$TMP/bin/systemd-run" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$@" >"${LMM_TEST_SYSTEMD_CAPTURE:?}"
EOF
chmod +x "$TMP/bin/systemd-run"
PATH="$TMP/bin:$PATH" LMM_TEST_MODE=1 LMM_TEST_ENFORCE_CUTOVER_INTERLOCK=1 \
    LMM_RS_CUTOVER_APPROVAL=GO_FREEZE_OVERRIDE_INTERNAL_PROBES LMM_TEST_SYSTEMD_CAPTURE="$systemd_capture" \
    LMM_RS_ARTIFACT_ROOT="$TMP/transient-artifacts" \
    "$HERE/deploy-lmm-api-rs.sh" --artifact "$TMP/artifact" --sha256 "$sha" --revision abcdef152 \
    --systemd-run --approve-cutover --cutover-target internal-probes --cutover-revision abcdef152 >/dev/null
grep -Fxq -- '--setenv=LMM_RS_CUTOVER_APPROVAL=GO_FREEZE_OVERRIDE_INTERNAL_PROBES' "$systemd_capture"
grep -Fxq "$HERE/deploy-lmm-api-rs.sh" "$systemd_capture"
grep -Fxq -- '--approve-cutover' "$systemd_capture"
grep -Fxq -- '--cutover-target' "$systemd_capture"
grep -Fxq 'internal-probes' "$systemd_capture"
grep -Fxq -- '--cutover-revision' "$systemd_capture"
grep -Fxq 'abcdef152' "$systemd_capture"

# The full contract also remains executable in the isolated harness when all
# four confirmations are present. Restore blue afterwards so the legacy fault
# matrix below retains its deterministic starting point.
PATH="$TMP/bin:$PATH" LMM_TEST_MODE=1 LMM_TEST_ENFORCE_CUTOVER_INTERLOCK=1 \
    LMM_RS_CUTOVER_APPROVAL=GO_FREEZE_OVERRIDE_INTERNAL_PROBES LMM_TEST_REVISION=abcdef151 \
    LMM_RS_ROOT="$TMP/root" LMM_RS_ETC_ROOT="$TMP/etc" LMM_RS_RUN_ROOT="$TMP/run" \
    LMM_RS_AUDIT_ROOT="$TMP/audit" LMM_RS_NGINX_UPSTREAM="$TMP/nginx/upstream.conf" \
    "$HERE/deploy-lmm-api-rs.sh" --artifact "$TMP/artifact" --sha256 "$sha" \
    --revision abcdef151 --approve-cutover --cutover-target internal-probes \
    --cutover-revision abcdef151 >/dev/null
grep -Fxq green "$TMP/root/active-slot"
cp "$TMP/nginx/upstream.expected" "$TMP/nginx/upstream.conf"
printf 'blue\n' >"$TMP/root/active-slot"
rm -f "$TMP/root/deploy-journal"

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
        if PATH="$TMP/bin:$PATH" LMM_TEST_MODE=1 LMM_TEST_REVISION="abcdef15${atomic_tool:0:1}" \
            LMM_RS_ROOT="$TMP/root" LMM_RS_ETC_ROOT="$TMP/etc" LMM_RS_RUN_ROOT="$TMP/run" \
            LMM_RS_AUDIT_ROOT="$TMP/audit" LMM_RS_NGINX_UPSTREAM="$TMP/nginx/upstream.conf" \
            "$HERE/deploy-lmm-api-rs.sh" --artifact "$TMP/artifact" --sha256 "$sha" \
            --revision "abcdef15${atomic_tool:0:1}" >/dev/null 2>&1; then
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
for warmed in status.warm.json notice.warm.json about.warm.json home-page.warm.json; do
    find "$TMP/audit" -name "$warmed" -type f -print -quit | grep -q . || {
        echo "candidate warm-up artifact missing: $warmed" >&2
        exit 1
    }
done

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
if PATH="$TMP/bin:$PATH" LMM_TEST_MODE=1 LMM_TEST_REVISION=abcdef128 \
    LMM_RS_ROOT="$TMP/root" LMM_RS_ETC_ROOT="$TMP/etc" LMM_RS_RUN_ROOT="$TMP/run" \
    LMM_RS_AUDIT_ROOT="$TMP/audit" LMM_RS_NGINX_UPSTREAM="$TMP/nginx/upstream.conf" \
    "$HERE/deploy-lmm-api-rs.sh" --artifact "$TMP/artifact" --sha256 "$sha" \
    --revision abcdef128 >/dev/null 2>&1; then
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
# Recovery is revision-pinned: an approval for a different release cannot
# reconcile a stale PREPARED transaction or alter its upstream/journal.
cp "$TMP/root/deploy-journal" "$TMP/root/deploy-journal.expected"
cp "$TMP/nginx/upstream.conf" "$TMP/nginx/upstream.expected"
if PATH="$TMP/bin:$PATH" LMM_TEST_MODE=1 LMM_TEST_REVISION=abcdef130 LMM_RS_ROOT="$TMP/root" LMM_RS_ETC_ROOT="$TMP/etc" \
    LMM_RS_RUN_ROOT="$TMP/run" LMM_RS_AUDIT_ROOT="$TMP/audit" \
    LMM_RS_NGINX_UPSTREAM="$TMP/nginx/upstream.conf" "$HERE/deploy-lmm-api-rs.sh" \
    --revision abcdef131 --reconcile-only >/dev/null 2>&1; then
    echo 'reconcile accepted a revision different from PREPARED journal' >&2
    exit 1
fi
cmp "$TMP/root/deploy-journal.expected" "$TMP/root/deploy-journal"
cmp "$TMP/nginx/upstream.expected" "$TMP/nginx/upstream.conf"
PATH="$TMP/bin:$PATH" LMM_TEST_MODE=1 LMM_TEST_REVISION=abcdef130 LMM_RS_ROOT="$TMP/root" LMM_RS_ETC_ROOT="$TMP/etc" \
    LMM_RS_RUN_ROOT="$TMP/run" LMM_RS_AUDIT_ROOT="$TMP/audit" \
    LMM_RS_NGINX_UPSTREAM="$TMP/nginx/upstream.conf" "$HERE/deploy-lmm-api-rs.sh" \
    --revision abcdef130 --reconcile-only >/dev/null
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
    "$HERE/deploy-lmm-api-rs.sh" --revision abcdef130 --reconcile-only >/dev/null
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
