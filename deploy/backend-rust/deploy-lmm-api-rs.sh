#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

readonly SCRIPT_NAME=${0##*/}
ARTIFACT=
EXPECTED_SHA256=
REVISION=
DRY_RUN=0
RUN_AS_TRANSIENT=0
RECONCILE_ONLY=0

usage() {
    cat <<'EOF'
Usage: deploy-lmm-api-rs.sh --artifact PATH --sha256 HEX --revision ID [--dry-run] [--systemd-run]
       deploy-lmm-api-rs.sh --revision ID --reconcile-only

Only the loopback GET/HEAD internal Rust probe upstream is switched. Production API
route ownership remains disabled until PostgreSQL migration and route parity.
EOF
}
die() { printf '%s: %s\n' "$SCRIPT_NAME" "$*" >&2; exit 1; }
log() { printf '%s\n' "$*"; }

while (($#)); do
    case $1 in
        --artifact) ARTIFACT=${2:?}; shift 2 ;;
        --sha256) EXPECTED_SHA256=${2:?}; shift 2 ;;
        --revision) REVISION=${2:?}; shift 2 ;;
        --dry-run) DRY_RUN=1; shift ;;
        --systemd-run) RUN_AS_TRANSIENT=1; shift ;;
        --reconcile-only) RECONCILE_ONLY=1; shift ;;
        --help|-h) usage; exit 0 ;;
        *) die "unknown argument: $1" ;;
    esac
done

[[ $REVISION =~ ^[A-Za-z0-9._-]{7,128}$ ]] || die "revision contains unsafe characters"
SELF=$(readlink -f -- "$0")
[[ $SELF == /* && -f $SELF && ! -L $SELF ]] || die "deployment entrypoint must resolve to an absolute regular file"
readonly SELF

if ((RUN_AS_TRANSIENT)); then
    ((DRY_RUN == 0 && RECONCILE_ONLY == 0)) || die "--systemd-run cannot be combined with dry-run/reconcile-only"
    [[ $EUID -eq 0 ]] || die "--systemd-run staging requires root"
    [[ $ARTIFACT == /* && -f $ARTIFACT && ! -L $ARTIFACT ]] || die "artifact must be an absolute non-symlink regular file"
    [[ $EXPECTED_SHA256 =~ ^[[:xdigit:]]{64}$ ]] || die "sha256 must be 64 hexadecimal characters"
    incoming_dir=/var/lib/lmm-api-rs/artifacts
    mkdir -p "$incoming_dir"
    durable_artifact="$incoming_dir/${REVISION}-${EXPECTED_SHA256}"
    if [[ ! -e $durable_artifact ]]; then
        durable_temp="$incoming_dir/.${REVISION}-${EXPECTED_SHA256}.$$.tmp"
        install -m 0700 -o root -g root "$ARTIFACT" "$durable_temp"
        [[ $(sha256sum "$durable_temp" | awk '{print $1}') == "$EXPECTED_SHA256" ]] || die "artifact changed while staging"
        sync -f "$durable_temp"; mv -T "$durable_temp" "$durable_artifact"; sync -f "$incoming_dir"
    fi
    [[ -f $durable_artifact && ! -L $durable_artifact && $(stat -c %u "$durable_artifact") == 0 ]] || die "durable artifact is unsafe"
    [[ $(sha256sum "$durable_artifact" | awk '{print $1}') == "$EXPECTED_SHA256" ]] || die "durable artifact checksum mismatch"
    command -v systemd-run >/dev/null || die "systemd-run is required"
    exec systemd-run --unit="lmm-api-rs-deploy-${REVISION}" --collect --property=Type=oneshot \
        --property=TimeoutStartSec=15min -- "$SELF" --artifact "$durable_artifact" \
        --sha256 "$EXPECTED_SHA256" --revision "$REVISION"
fi
if [[ ${LMM_TEST_MODE:-0} != 1 && $EUID -ne 0 ]]; then die "must run as root"; fi

readonly ROOT=${LMM_RS_ROOT:-/opt/lmm-api-rs}
readonly ETC_ROOT=${LMM_RS_ETC_ROOT:-/etc/lmm-api-rs}
readonly RUN_ROOT=${LMM_RS_RUN_ROOT:-/run/lmm-api-rs}
readonly AUDIT_ROOT=${LMM_RS_AUDIT_ROOT:-/var/log/lmm-api-rs/deployments}
readonly NGINX_UPSTREAM=${LMM_RS_NGINX_UPSTREAM:-/etc/nginx/conf.d/lmm-api-rs-active-upstream.conf}
readonly ACTIVE_FILE="$ROOT/active-slot"
readonly JOURNAL_FILE="$ROOT/deploy-journal"
readonly LOCK_FILE=${LMM_RS_DEPLOY_LOCK:-/run/lock/lmm-api-nginx-deploy.lock}
safe_revision=${REVISION//[^A-Za-z0-9._-]/_}
[[ -n $safe_revision ]] || safe_revision=preflight
TRANSACTION_ID="$(date -u +%Y%m%dT%H%M%SZ)-${safe_revision}-$$"
readonly TRANSACTION_ID
readonly AUDIT_DIR="$AUDIT_ROOT/$TRANSACTION_ID"

mkdir -p "$RUN_ROOT" "$AUDIT_DIR" "$ROOT" "${LOCK_FILE%/*}"
chmod 0700 "$AUDIT_DIR"
exec > >(tee -a "$AUDIT_DIR/transaction.log") 2>&1

atomic_from_file() {
    source_file=$1 target_file=$2 mode=$3
    target_dir=${target_file%/*}; target_base=${target_file##*/}
    mkdir -p "$target_dir" || return
    temp_file="$target_dir/.${target_base}.${TRANSACTION_ID}.tmp"
    cp -- "$source_file" "$temp_file" || return
    chmod "$mode" "$temp_file" || return
    sync -f "$temp_file" || return
    mv -Tf "$temp_file" "$target_file" || return
    sync -f "$target_dir" || return
}
atomic_text() {
    target_file=$1 mode=$2 content=$3
    target_dir=${target_file%/*}; target_base=${target_file##*/}
    mkdir -p "$target_dir" || return
    temp_file="$target_dir/.${target_base}.${TRANSACTION_ID}.tmp"
    printf '%s\n' "$content" >"$temp_file" || return
    chmod "$mode" "$temp_file" || return
    sync -f "$temp_file" || return
    mv -Tf "$temp_file" "$target_file" || return
    sync -f "$target_dir" || return
}
write_result() { atomic_text "$AUDIT_DIR/result" 0600 "$1"; }
write_journal() {
    phase=$1 slot=${2:-none}
    line="transaction=$TRANSACTION_ID phase=$phase slot=$slot revision=$safe_revision"
    atomic_text "$JOURNAL_FILE" 0600 "$line"
    atomic_text "$AUDIT_DIR/journal" 0600 "$line"
}
CANARY_ORIGIN=https://api.lmm.best
CANARY_RESOLVE=api.lmm.best:443:127.0.0.1
CANARY_CA=/etc/ssl/certs/ca-certificates.crt
if [[ -r $ETC_ROOT/deploy.conf ]]; then
    # shellcheck disable=SC1090,SC1091
    source "$ETC_ROOT/deploy.conf"
fi
curl_nginx() {
    path=$1 output=$2
    curl --fail --silent --show-error --max-time 5 --resolve "$CANARY_RESOLVE" \
        --cacert "$CANARY_CA" "$CANARY_ORIGIN$path" >"$output"
}
slot_from_upstream() {
    [[ -s $NGINX_UPSTREAM ]] || return 1
    selected_port=$(sed -nE 's/^[[:space:]]*server[[:space:]]+127\.0\.0\.1:(3100|3101);.*/\1/p' "$NGINX_UPSTREAM" | head -n1)
    case $selected_port in 3100) printf blue ;; 3101) printf green ;; *)
        grep -Eq 'server[[:space:]]+127\.0\.0\.1:9;' "$NGINX_UPSTREAM" && printf none || return 1 ;;
    esac
}
reconcile_state() {
    if [[ -s $JOURNAL_FILE ]] && grep -Fq 'phase=PREPARED' "$JOURNAL_FILE"; then
        pending_revision=$(sed -nE 's/.* revision=([^ ]+).*/\1/p' "$JOURNAL_FILE")
        pending_old=$(sed -nE 's/.* old=([^ ]+).*/\1/p' "$JOURNAL_FILE")
        pending_new=$(sed -nE 's/.* new=([^ ]+).*/\1/p' "$JOURNAL_FILE")
        pending_backup=$(sed -nE 's/.* backup=([^ ]+).*/\1/p' "$JOURNAL_FILE")
        pending_sha=$(sed -nE 's/.* upstream_sha=([^ ]+).*/\1/p' "$JOURNAL_FILE")
        [[ $pending_old == none || $pending_old == blue || $pending_old == green ]] || die "PREPARED old slot is invalid"
        [[ $pending_new == blue || $pending_new == green ]] || die "PREPARED new slot is invalid"
        [[ $pending_backup == "$AUDIT_ROOT"/* && -f $pending_backup && ! -L $pending_backup ]] || die "PREPARED backup path is unsafe"
        [[ $pending_sha =~ ^[[:xdigit:]]{64}$ ]] || die "PREPARED upstream hash is invalid"
        [[ $(sha256sum "$pending_backup" | awk '{print $1}') == "$pending_sha" ]] || die "PREPARED upstream backup hash mismatch"
        canary_file="$AUDIT_DIR/reconcile-build.json"
        if curl_nginx /_internal/rust/build "$canary_file" && \
            grep -Fq "\"revision\":\"$pending_revision\"" "$canary_file" && \
            grep -Fq "\"slot\":\"$pending_new\"" "$canary_file"; then
            atomic_text "$ACTIVE_FILE" 0600 "$pending_new"
            write_journal COMMITTED "$pending_new"
            printf '%s' "$pending_new"
            return
        fi
        if [[ $pending_old != none ]]; then
            systemctl start "lmm-api-rs@${pending_old}.service"
            recovery_port=$([[ $pending_old == blue ]] && printf 3100 || printf 3101)
            curl --fail --silent --max-time 3 "http://127.0.0.1:${recovery_port}/readyz" >/dev/null
        fi
        atomic_from_file "$pending_backup" "$NGINX_UPSTREAM" 0644
        nginx -t; systemctl reload nginx; systemctl is-active --quiet nginx
        atomic_text "$ACTIVE_FILE" 0600 "$pending_old"
        write_journal ROLLED_BACK "$pending_old"
        printf '%s' "$pending_old"
        return
    fi
    actual_slot=$(slot_from_upstream) || die "cannot derive active slot from managed nginx upstream"
    atomic_text "$ACTIVE_FILE" 0600 "$actual_slot"
    write_journal RECONCILED "$actual_slot"
    printf '%s' "$actual_slot"
}

inactive=
active=
upstream_replaced=0
nginx_reloaded=0
old_upstream="$AUDIT_DIR/upstream.before"
rollback() {
    status=$?
    trap - ERR EXIT
    if ((status != 0)); then
        log "deployment failed; restoring managed state"
        rollback_failed=0
        if ((upstream_replaced)) && [[ -s $old_upstream ]]; then
            old_gate_failed=0
            if ((nginx_reloaded)); then
                if [[ $active != none ]]; then
                    if ! systemctl start "lmm-api-rs@${active}.service"; then old_gate_failed=1; fi
                    if [[ ${LMM_ROLLBACK_FAIL_AT:-} == old-start ]]; then old_gate_failed=1; fi
                    old_port=$([[ $active == blue ]] && printf 3100 || printf 3101)
                    if ! curl --fail --silent --max-time 3 "http://127.0.0.1:${old_port}/readyz" >/dev/null; then old_gate_failed=1; fi
                    if ! curl --fail --silent --max-time 3 "http://127.0.0.1:${old_port}/_internal/build" >"$AUDIT_DIR/build.rollback-direct.json"; then old_gate_failed=1; fi
                fi
            fi
            if ((old_gate_failed == 0)); then
                if ! atomic_from_file "$old_upstream" "$NGINX_UPSTREAM" 0644; then rollback_failed=1; fi
                if ! nginx -t; then rollback_failed=1; fi
                if ! systemctl reload nginx; then rollback_failed=1; fi
                if [[ ${LMM_ROLLBACK_FAIL_AT:-} == old-reload ]]; then rollback_failed=1; fi
                if ! systemctl is-active --quiet nginx; then rollback_failed=1; fi
                if ((nginx_reloaded)) && [[ $active != none ]]; then
                    if ! curl_nginx /_internal/rust/readyz "$AUDIT_DIR/readyz.rollback-nginx.json"; then rollback_failed=1; fi
                    if ! curl_nginx /_internal/rust/build "$AUDIT_DIR/build.rollback-nginx.json"; then rollback_failed=1; fi
                    if [[ ${LMM_ROLLBACK_FAIL_AT:-} == old-canary ]]; then rollback_failed=1; fi
                    old_revision=$(sed -nE 's/.*"revision":"([^"]+)".*/\1/p' "$AUDIT_DIR/build.rollback-direct.json")
                    if [[ -z $old_revision ]] || ! grep -Fq "\"revision\":\"$old_revision\"" "$AUDIT_DIR/build.rollback-nginx.json" || \
                        ! grep -Fq "\"slot\":\"$active\"" "$AUDIT_DIR/build.rollback-nginx.json"; then rollback_failed=1; fi
                fi
            else
                rollback_failed=1
            fi
        fi
        if ((rollback_failed)); then
            retain_failed=0
            if [[ -n ${next_upstream:-} && -s ${next_upstream:-} && -n $inactive ]]; then
                if ! systemctl start "lmm-api-rs@${inactive}.service"; then retain_failed=1; fi
                if ! atomic_from_file "$next_upstream" "$NGINX_UPSTREAM" 0644; then retain_failed=1; fi
                if ! nginx -t; then retain_failed=1; fi
                if ! systemctl reload nginx; then retain_failed=1; fi
                if ! systemctl is-active --quiet nginx; then retain_failed=1; fi
                if ! curl_nginx /_internal/rust/readyz "$AUDIT_DIR/readyz.retained-new.json"; then retain_failed=1; fi
                if ! curl_nginx /_internal/rust/build "$AUDIT_DIR/build.retained-new.json"; then retain_failed=1; fi
                if ! grep -Fq "\"revision\":\"$REVISION\"" "$AUDIT_DIR/build.retained-new.json" || \
                    ! grep -Fq "\"slot\":\"$inactive\"" "$AUDIT_DIR/build.retained-new.json"; then retain_failed=1; fi
            else
                retain_failed=1
            fi
            if ((retain_failed)); then
                atomic_text "$AUDIT_DIR/NEEDS_ATTENTION" 0600 "both old rollback and new-route retention failed"
                write_result "NEEDS_ATTENTION status=$status"
            else
                atomic_text "$ACTIVE_FILE" 0600 "$inactive"
                write_journal RETAINED_NEW "$inactive"
                write_result "FAILED_RETAINED_NEW status=$status"
            fi
            exit "$status"
        fi
        if [[ -n $active ]]; then atomic_text "$ACTIVE_FILE" 0600 "$active"; write_journal ROLLED_BACK "$active"; fi
        if [[ -n $inactive ]] && ! systemctl stop "lmm-api-rs@${inactive}.service"; then
            atomic_text "$AUDIT_DIR/NEEDS_ATTENTION" 0600 "rollback succeeded but new slot could not be stopped"
            write_result "NEEDS_ATTENTION status=$status"
            exit "$status"
        fi
        write_result "FAILED status=$status"
    fi
    exit "$status"
}
trap rollback ERR EXIT

exec 9>"$LOCK_FILE"
flock -n 9 || die "another Rust backend deployment is running"
[[ -s $NGINX_UPSTREAM ]] || die "managed nginx upstream is absent"
active=$(reconcile_state)
if ((RECONCILE_ONLY)); then write_result "RECONCILED active=$active"; trap - ERR EXIT; exit 0; fi

[[ -n $ARTIFACT && -n $EXPECTED_SHA256 ]] || die "artifact and sha256 are required"
[[ $ARTIFACT == /* ]] || die "artifact path must be absolute"
[[ $EXPECTED_SHA256 =~ ^[[:xdigit:]]{64}$ ]] || die "sha256 must be 64 hexadecimal characters"
[[ -f $ARTIFACT && ! -L $ARTIFACT && -x $ARTIFACT ]] || die "artifact must be an executable, non-symlink regular file"
if [[ ${LMM_TEST_MODE:-0} != 1 ]]; then
    [[ $(stat -c %u "$ARTIFACT") == 0 ]] || die "artifact must be root-owned"
fi
for required in "$ETC_ROOT/common.env" "$ETC_ROOT/blue.env" "$ETC_ROOT/green.env"; do
    [[ -s $required && ! -L $required ]] || die "required configuration is absent or unsafe: $required"
done
[[ ! -e $ETC_ROOT/production-routing.enabled ]] || die "production routing is unsupported before PG migration and route parity approval"

actual_sha256=$(sha256sum "$ARTIFACT" | awk '{print $1}')
[[ $actual_sha256 == "$EXPECTED_SHA256" ]] || die "artifact checksum mismatch"
atomic_text "$AUDIT_DIR/manifest" 0600 "revision=$REVISION sha256=$actual_sha256 started_at=$(date -u +%FT%TZ)"
case $active in blue) inactive=green; port=3101 ;; green) inactive=blue; port=3100 ;; none) inactive=blue; port=3100 ;; esac
if ((DRY_RUN)); then
    write_result "DRY_RUN active=$active inactive=$inactive"
    trap - ERR EXIT
    log "dry-run: production route ownership remains unchanged"
    exit 0
fi

readonly RELEASE_DIR="$ROOT/releases/$REVISION"
if [[ -e $RELEASE_DIR ]]; then
    [[ -d $RELEASE_DIR && ! -L $RELEASE_DIR && -f $RELEASE_DIR/lmm-api-rs && ! -L $RELEASE_DIR/lmm-api-rs ]] || die "immutable release path has unsafe contents"
    installed_sha=$(sha256sum "$RELEASE_DIR/lmm-api-rs" | awk '{print $1}')
    [[ $installed_sha == "$EXPECTED_SHA256" ]] || die "immutable revision already exists with a different artifact"
else
    stage_dir="$ROOT/releases/.stage-${TRANSACTION_ID}"
    install -d -m 0755 "$stage_dir"
    install -m 0755 "$ARTIFACT" "$stage_dir/lmm-api-rs"
    staged_sha=$(sha256sum "$stage_dir/lmm-api-rs" | awk '{print $1}')
    [[ $staged_sha == "$EXPECTED_SHA256" ]] || die "artifact changed while being staged"
    printf '%s  lmm-api-rs\n' "$staged_sha" >"$stage_dir/SHA256SUMS"
    sync -f "$stage_dir/lmm-api-rs"; sync -f "$stage_dir/SHA256SUMS"
    mv -T "$stage_dir" "$RELEASE_DIR"
    sync -f "$ROOT/releases"
fi
install -d -m 0755 "$ROOT/slots/$inactive"
ln -s "$RELEASE_DIR" "$ROOT/slots/$inactive/.current-${TRANSACTION_ID}"
mv -Tf "$ROOT/slots/$inactive/.current-${TRANSACTION_ID}" "$ROOT/slots/$inactive/current"
sync -f "$ROOT/slots/$inactive"
write_journal INSTALLED "$inactive"
[[ ${LMM_DEPLOY_FAIL_AT:-} != install ]] || die "injected failure at install"

systemctl daemon-reload
systemctl restart "lmm-api-rs@${inactive}.service"
for _attempt in {1..30}; do
    curl --fail --silent --max-time 2 "http://127.0.0.1:${port}/livez" >/dev/null && \
        curl --fail --silent --max-time 3 "http://127.0.0.1:${port}/readyz" >/dev/null && break
    sleep 1
done
curl --fail --silent --show-error --max-time 3 "http://127.0.0.1:${port}/readyz" >"$AUDIT_DIR/readyz.direct.json"
curl --fail --silent --show-error --max-time 3 "http://127.0.0.1:${port}/_internal/build" >"$AUDIT_DIR/build.direct.json"
grep -Fq "\"revision\":\"$REVISION\"" "$AUDIT_DIR/build.direct.json" || die "direct build revision mismatch"
grep -Fq "\"slot\":\"$inactive\"" "$AUDIT_DIR/build.direct.json" || die "direct build slot mismatch"
[[ ${LMM_DEPLOY_FAIL_AT:-} != ready ]] || die "injected failure at ready"

atomic_from_file "$NGINX_UPSTREAM" "$old_upstream" 0600
old_upstream_sha=$(sha256sum "$old_upstream" | awk '{print $1}')
atomic_text "$JOURNAL_FILE" 0600 "transaction=$TRANSACTION_ID phase=PREPARED old=$active new=$inactive revision=$REVISION backup=$old_upstream upstream_sha=$old_upstream_sha"
atomic_text "$AUDIT_DIR/journal" 0600 "transaction=$TRANSACTION_ID phase=PREPARED old=$active new=$inactive revision=$REVISION backup=$old_upstream upstream_sha=$old_upstream_sha"
next_upstream="$AUDIT_DIR/upstream.next"
printf '# Managed transaction %s\nupstream lmm_api_rs_active {\n    server 127.0.0.1:%s;\n    keepalive 32;\n}\n' "$TRANSACTION_ID" "$port" >"$next_upstream"
atomic_from_file "$next_upstream" "$NGINX_UPSTREAM" 0644
upstream_replaced=1
if [[ ${LMM_DEPLOY_FAIL_AT:-} == kill-before-reload ]]; then kill -KILL $$; fi
nginx -t
[[ ${LMM_DEPLOY_FAIL_AT:-} != nginx-test ]] || die "injected failure at nginx-test"
systemctl reload nginx
systemctl is-active --quiet nginx
nginx_reloaded=1
if [[ ${LMM_DEPLOY_FAIL_AT:-} == kill-after-reload ]]; then kill -KILL $$; fi
write_journal COMMITTED "$inactive"
atomic_text "$ACTIVE_FILE" 0600 "$inactive"

curl_nginx /_internal/rust/readyz "$AUDIT_DIR/readyz.nginx.json"
curl_nginx /_internal/rust/build "$AUDIT_DIR/build.nginx.json"
grep -Fq "\"revision\":\"$REVISION\"" "$AUDIT_DIR/build.nginx.json" || die "post-reload nginx canary selected the wrong revision"
grep -Fq "\"slot\":\"$inactive\"" "$AUDIT_DIR/build.nginx.json" || die "post-reload nginx canary selected the wrong slot"
[[ ${LMM_DEPLOY_FAIL_AT:-} != switch ]] || die "injected failure at switch"

# Only short internal GET probes are owned here; SIGTERM uses the application's bounded drain.
if [[ $active != none ]]; then
    systemctl stop "lmm-api-rs@${active}.service"
    if systemctl is-active --quiet "lmm-api-rs@${active}.service"; then die "previous slot remained active after stop"; fi
fi
write_journal COMPLETE "$inactive"
write_result "SUCCESS active=$inactive previous=$active completed_at=$(date -u +%FT%TZ)"
trap - ERR EXIT
log "deployment succeeded: $active -> $inactive; production API ownership unchanged"
