#!/usr/bin/env bash
set -Eeuo pipefail

HERE=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
readonly HERE
die() { printf 'test-package: %s\n' "$*" >&2; exit 1; }

readonly SHARED="$HERE/../../common/lmm-api"
bash -n "$SHARED/lmm-api-launcher" "$SHARED/lmm-api.install" \
  "$HERE/build-local-package.sh" "$HERE/test-package.sh"
if command -v shellcheck >/dev/null 2>&1; then
  shellcheck "$SHARED/lmm-api-launcher" "$SHARED/lmm-api.install" \
    "$HERE/build-local-package.sh" "$HERE/test-package.sh"
fi

grep -Fqx 'LMM_API_BACKEND=auto' "$SHARED/backend.conf" || die 'packaged default is not auto'
grep -Fq 'Environment=LMM_API_BACKEND=auto' "$SHARED/lmm-api.service" || die 'service default is not auto'
grep -Fq 'apps/api-go/out/lmm-api' "$HERE/build-local-package.sh" || die 'Go artifact path is stale'
grep -Fq 'apps/api-rust/target/release/lmm-api-rs' "$HERE/build-local-package.sh" || die 'Rust path is stale'
grep -Fq 'apps/web/dist' "$HERE/build-local-package.sh" || die 'frontend path is stale'
grep -Fq 'usr/bin/lmm-api' "$HERE/PKGBUILD" || die 'canonical CLI is not installed'
grep -Fq 'usr/lib/lmm-api/deploy' "$HERE/PKGBUILD" || die 'private deployment data layout is missing'
grep -Fq 'ExecStart=/usr/bin/lmm-api serve' "$SHARED/lmm-api.service" || \
  die 'service does not use canonical serve command'
if rg -q 'lmm-api-deploy|lmm-api-select|activate-rust-release|create-backup-copy|prepare-production-backup|promote-production-backups|frontend-release|inspect-state|verify-backup-set' \
  "$HERE/PKGBUILD" "$HERE/build-local-package.sh"; then
  die 'local package still stages a separate deploy or helper command'
fi
grep -Fq "'diffutils'" "$HERE/PKGBUILD" || die 'local core lacks the route validator diff runtime'
grep -Fq 'route-evidence.tar' "$HERE/PKGBUILD" || die 'route evidence is not packaged atomically'
grep -Fq 'migration-evidence.tar' "$HERE/PKGBUILD" || die 'migration evidence is not packaged atomically'
# shellcheck disable=SC2016 # Match literal builder and PKGBUILD variables.
grep -Fq 'install -Dm0755 "$REPO_ROOT/apps/web/scripts/production-acceptance.mjs"' \
  "$HERE/build-local-package.sh" || die 'acceptance runner is not staged executable'
# shellcheck disable=SC2016 # Match literal builder and PKGBUILD variables.
grep -Fq 'install -Dm0644 "$REPO_ROOT/apps/web/scripts/production-acceptance-lib.mjs"' \
  "$HERE/build-local-package.sh" || die 'acceptance library is not staged read-only'
# shellcheck disable=SC2016 # Match literal builder and PKGBUILD variables.
grep -Fq 'install -Dm0755 "$srcdir/production-acceptance.mjs"' "$HERE/PKGBUILD" || \
  die 'acceptance runner is not installed executable'
# shellcheck disable=SC2016 # Match literal builder and PKGBUILD variables.
grep -Fq 'install -Dm0644 "$srcdir/production-acceptance-lib.mjs"' "$HERE/PKGBUILD" || \
  die 'acceptance library is not installed read-only'

tmp=$(mktemp -d "${TMPDIR:-/tmp}/lmm-api-split-test.XXXXXXXX")
cleanup() { rm -rf -- "$tmp"; }
trap cleanup EXIT
if LMM_API_GO_BINARY="$tmp/missing-go" "$HERE/build-local-package.sh" \
    --output-dir "$tmp/packages" >"$tmp/builder.out" 2>"$tmp/builder.err"; then
  die 'local package builder unexpectedly accepted a missing Go binary'
fi
grep -Fq 'binary is missing or unsafe' "$tmp/builder.err" || \
  die 'local package builder failed before initialized build state'
if grep -Fq 'unbound variable' "$tmp/builder.err"; then
  die 'local package builder still uses build_dir before initialization'
fi
mkdir -p "$tmp/backends/go" "$tmp/backends/rs"
# shellcheck disable=SC2016 # Write literal fixture source for a child process.
printf '%s\n' '#!/usr/bin/env bash' 'printf "go:%s\n" "$*"' >"$tmp/backends/go/lmm-api"
# shellcheck disable=SC2016 # Write literal fixture source for a child process.
printf '%s\n' '#!/usr/bin/env bash' 'printf "rs:%s\n" "$LMM_DATABASE_SCHEMA"' >"$tmp/backends/rs/lmm-api-rs"
chmod 0755 "$tmp/backends/go/lmm-api" "$tmp/backends/rs/lmm-api-rs"

output=$(LMM_API_BACKEND_ROOT="$tmp/backends" LMM_API_BACKEND=auto "$SHARED/lmm-api-launcher" serve marker)
[[ $output == 'go:marker' ]] || die 'development auto did not prefer Go'
rm -f "$tmp/backends/go/lmm-api"
if LMM_API_BACKEND_ROOT="$tmp/backends" LMM_API_BACKEND=go "$SHARED/lmm-api-launcher" serve >/dev/null 2>&1; then
  die 'explicit Go selection silently fell back to Rust'
fi
output=$(LMM_API_BACKEND_ROOT="$tmp/backends" LMM_API_BACKEND=rs \
  LMM_DATABASE_SCHEMA=lmm_preview_test "$SHARED/lmm-api-launcher" serve)
[[ $output == 'rs:lmm_preview_test' ]] || die 'explicit Rust preview did not start'

printf '%s\n' 'split package contract verified'
