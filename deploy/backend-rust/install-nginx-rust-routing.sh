#!/usr/bin/env bash
set -Eeuo pipefail
umask 077
[[ $# -eq 0 ]] || { echo "usage: ${0##*/}" >&2; exit 1; }
[[ ${LMM_TEST_MODE:-0} == 1 || $EUID -eq 0 ]] || { echo "must run as root" >&2; exit 1; }
readonly ASSET_ROOT=${LMM_RS_ASSET_ROOT:-/usr/lib/lmm-api-rs/deploy}
readonly ROOT=${LMM_RS_ROOT:-/opt/lmm-api-rs}
readonly RUN_ROOT=${LMM_RS_RUN_ROOT:-/run/lmm-api-rs}
readonly LOCK_FILE=${LMM_RS_DEPLOY_LOCK:-/run/lock/lmm-api-nginx-deploy.lock}
readonly UPSTREAM_TARGET=${LMM_RS_NGINX_UPSTREAM:-/etc/nginx/conf.d/lmm-api-rs-active-upstream.conf}
readonly LOCATIONS_TARGET=${LMM_RS_NGINX_LOCATIONS:-/etc/nginx/snippets/lmm-api-rs-probe-locations.conf}
readonly SERVER_TEMPLATE=${LMM_RS_NGINX_SERVER_TEMPLATE:-$ASSET_ROOT/nginx/new-api.conf}
transaction="bootstrap-$(date -u +%Y%m%dT%H%M%SZ)-$$"; readonly transaction
mkdir -p "$RUN_ROOT" "$ROOT" "${LOCK_FILE%/*}"
exec 9>"$LOCK_FILE"; flock -n 9 || { echo "another transaction is running" >&2; exit 1; }
backup_dir=$(mktemp -d "$RUN_ROOT/lmm-api-rs-nginx.XXXXXX"); readonly backup_dir

atomic_replace() {
    source_file=$1 target_file=$2 mode=$3
    dir=${target_file%/*}; base=${target_file##*/}; mkdir -p "$dir" || return
    temp="$dir/.${base}.${transaction}.tmp"
    cp -- "$source_file" "$temp" || return
    chmod "$mode" "$temp" || return
    sync -f "$temp" || return
    mv -Tf "$temp" "$target_file" || return
    sync -f "$dir" || return
}
had_upstream=0; had_locations=0; upstream_changed=0; locations_changed=0; reload_attempted=0; success=0
[[ ! -f $UPSTREAM_TARGET ]] || { cp -- "$UPSTREAM_TARGET" "$backup_dir/upstream"; had_upstream=1; }
[[ ! -f $LOCATIONS_TARGET ]] || { cp -- "$LOCATIONS_TARGET" "$backup_dir/locations"; had_locations=1; }
restore_one() {
    target=$1 backup=$2 had=$3
    if ((had)); then atomic_replace "$backup" "$target" 0644; else rm -f -- "$target"; sync -f "${target%/*}"; fi
}
restore() {
    status=$?; trap - EXIT ERR; restore_failed=0
    if ((success == 0)); then
        if ((locations_changed)); then restore_one "$LOCATIONS_TARGET" "$backup_dir/locations" "$had_locations" || restore_failed=1; fi
        if ((upstream_changed)); then restore_one "$UPSTREAM_TARGET" "$backup_dir/upstream" "$had_upstream" || restore_failed=1; fi
        nginx -t || restore_failed=1
        if ((reload_attempted)); then systemctl reload nginx || restore_failed=1; systemctl is-active --quiet nginx || restore_failed=1; fi
        ((restore_failed == 0)) || echo "NEEDS_ATTENTION: nginx bootstrap rollback verification failed" >&2
    fi
    rm -rf "$backup_dir"; exit "$status"
}
trap restore EXIT ERR

grep -Fq 'include /etc/nginx/snippets/lmm-api-rs-probe-locations.conf;' "$SERVER_TEMPLATE" || {
    echo "server template does not own the Rust probe snippet include" >&2; exit 1;
}
if [[ -s $UPSTREAM_TARGET ]] && grep -Eq 'server[[:space:]]+127\.0\.0\.1:(3100|3101);' "$UPSTREAM_TARGET"; then
    echo "Rust routing is already active; bootstrap refuses to reset it" >&2
    exit 1
fi
upstream_changed=1
atomic_replace "$ASSET_ROOT/nginx/lmm-api-rs-upstream.conf" "$UPSTREAM_TARGET" 0644
[[ ${LMM_INSTALL_FAIL_AT:-} != upstream ]] || exit 70
locations_changed=1
atomic_replace "$ASSET_ROOT/nginx/lmm-api-rs-probe-locations.conf" "$LOCATIONS_TARGET" 0644
[[ ${LMM_INSTALL_FAIL_AT:-} != locations ]] || exit 71
nginx -t; reload_attempted=1; systemctl reload nginx; systemctl is-active --quiet nginx
nginx -T 2>&1 | grep -Fq 'location = /_internal/rust/readyz' || {
    echo "live nginx configuration does not include Rust probes" >&2; exit 1;
}
printf 'none\n' >"$backup_dir/active"; atomic_replace "$backup_dir/active" "$ROOT/active-slot" 0600
success=1
echo "Rust routing bootstrap installed at disabled port 9; first deploy will select blue"
