#!/usr/bin/env bash
set -Eeuo pipefail

HERE=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
readonly HERE
die() { printf 'test-package: %s\n' "$*" >&2; exit 1; }

readonly SHARED="$HERE/../../common/lmm-api"
bash -n "$SHARED/lmm-api-launcher" "$SHARED/lmm-api-select" \
  "$SHARED/lmm-api.install" "$HERE/build-local-package.sh" "$HERE/test-package.sh"
if command -v shellcheck >/dev/null 2>&1; then
  shellcheck "$SHARED/lmm-api-launcher" "$SHARED/lmm-api-select" \
    "$SHARED/lmm-api.install" "$HERE/build-local-package.sh" "$HERE/test-package.sh"
fi

grep -Fqx 'LMM_API_BACKEND=auto' "$SHARED/backend.conf" || die 'packaged default is not auto'
grep -Fq 'Environment=LMM_API_BACKEND=auto' "$SHARED/lmm-api.service" || die 'service default is not auto'
grep -Fq 'apps/api-go/out/lmm-api' "$HERE/build-local-package.sh" || die 'Go artifact path is stale'
grep -Fq 'apps/api-rust/target/release/lmm-api-rs' "$HERE/build-local-package.sh" || die 'Rust path is stale'
grep -Fq 'apps/web/dist' "$HERE/build-local-package.sh" || die 'frontend path is stale'

tmp=$(mktemp -d "${TMPDIR:-/tmp}/lmm-api-split-test.XXXXXXXX")
cleanup() { rm -rf -- "$tmp"; }
trap cleanup EXIT
mkdir -p "$tmp/backends/go" "$tmp/backends/rs"
# shellcheck disable=SC2016 # Write literal fixture source for a child process.
printf '%s\n' '#!/usr/bin/env bash' 'printf "go:%s\n" "$*"' >"$tmp/backends/go/lmm-api"
# shellcheck disable=SC2016 # Write literal fixture source for a child process.
printf '%s\n' '#!/usr/bin/env bash' 'printf "rs:%s\n" "$LMM_DATABASE_SCHEMA"' >"$tmp/backends/rs/lmm-api-rs"
chmod 0755 "$tmp/backends/go/lmm-api" "$tmp/backends/rs/lmm-api-rs"

output=$(LMM_API_BACKEND_ROOT="$tmp/backends" LMM_API_BACKEND=auto "$SHARED/lmm-api-launcher" marker)
[[ $output == 'go:marker' ]] || die 'development auto did not prefer Go'
rm -f "$tmp/backends/go/lmm-api"
if LMM_API_BACKEND_ROOT="$tmp/backends" LMM_API_BACKEND=go "$SHARED/lmm-api-launcher" >/dev/null 2>&1; then
  die 'explicit Go selection silently fell back to Rust'
fi
output=$(LMM_API_BACKEND_ROOT="$tmp/backends" LMM_API_BACKEND=rs \
  LMM_DATABASE_SCHEMA=lmm_preview_test "$SHARED/lmm-api-launcher")
[[ $output == 'rs:lmm_preview_test' ]] || die 'explicit Rust preview did not start'

printf '%s\n' 'split package contract verified'
