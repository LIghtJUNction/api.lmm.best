#!/usr/bin/env bash
# Frozen real-TCP differential for the identity admin/profile/2FA route family.
#
# Each listener must use an independent, equivalently seeded PostgreSQL 18
# database and Valkey instance. Tokens are accepted only through environment
# variables and are never printed. This gate intentionally refuses to run until
# the production listener mounts the three route families behind its verified
# principal adapters.
set -euo pipefail

: "${GO_BASE_URL:?set isolated legacy Go listener URL}"
: "${RUST_BASE_URL:?set isolated Rust listener URL}"
: "${GO_USER_BEARER:?set isolated Go user bearer}"
: "${RUST_USER_BEARER:?set isolated Rust user bearer}"
: "${GO_ADMIN_BEARER:?set isolated Go administrator bearer}"
: "${RUST_ADMIN_BEARER:?set isolated Rust administrator bearer}"

runtime=$(mktemp -d /tmp/lmm-identity-user-tcp.XXXXXX)
cleanup() { rm -rf "$runtime"; }
trap cleanup EXIT INT TERM

request() {
  local engine=$1 base=$2 bearer=$3 name=$4 method=$5 path=$6
  curl -fsS -D "$runtime/$engine-$name.headers" -o "$runtime/$engine-$name.json" \
    -X "$method" -H "authorization: Bearer $bearer" -H 'accept: application/json' \
    "$base$path" >/dev/null
  jq -e . "$runtime/$engine-$name.json" >/dev/null
}

canonical() {
  jq -S 'del(.data.secret?, .data.qr_code_data?, .data.backup_codes?)' "$1"
}

exercise() {
  local engine=$1 base=$2 user_bearer=$3 admin_bearer=$4
  request "$engine" "$base" "$user_bearer" twofa-status GET /api/user/2fa/status
  request "$engine" "$base" "$user_bearer" affiliation GET /api/user/aff
  request "$engine" "$base" "$admin_bearer" admin-list GET '/api/user/?p=1&page_size=10'
  jq -e '.success == true and (.data.enabled | type == "boolean")' "$runtime/$engine-twofa-status.json" >/dev/null
  jq -e '.success == true and (.data | type == "string")' "$runtime/$engine-affiliation.json" >/dev/null
  jq -e '.success == true and (.data.items | type == "array")' "$runtime/$engine-admin-list.json" >/dev/null
}

exercise go "$GO_BASE_URL" "$GO_USER_BEARER" "$GO_ADMIN_BEARER"
exercise rust "$RUST_BASE_URL" "$RUST_USER_BEARER" "$RUST_ADMIN_BEARER"
for name in twofa-status affiliation admin-list; do
  canonical "$runtime/go-$name.json" >"$runtime/go-$name.canonical"
  canonical "$runtime/rust-$name.json" >"$runtime/rust-$name.canonical"
  diff -u "$runtime/go-$name.canonical" "$runtime/rust-$name.canonical"
done

jq -cn '{test:"identity-user-tcp-differential",go_tcp_listener:true,rust_tcp_listener:true,routes:["/api/user/2fa/status","/api/user/aff","/api/user/"],result:"passed"}'
