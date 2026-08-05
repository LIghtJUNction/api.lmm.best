#!/usr/bin/env bash
set -Eeuo pipefail

HERE=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
readonly HERE
readonly SHARED="$HERE/../common/lmm-api"
readonly PACKAGES=(
  lmm-api-bin
  lmm-api-git
  lmm-api-go-bin
  lmm-api-go-git
  lmm-api-rs-bin
  lmm-api-rs-git
)

die() { printf 'test-aur-matrix: %s\n' "$*" >&2; exit 1; }

contains_srcinfo() {
  local package=$1 expected=$2
  grep -Fqx "$expected" "$HERE/$package/.SRCINFO" || \
    die "$package .SRCINFO is missing: $expected"
}

contains_srcinfo_prefix() {
  local package=$1 expected=$2
  grep -Fq "$expected" "$HERE/$package/.SRCINFO" || \
    die "$package .SRCINFO is missing: $expected"
}

for package in "${PACKAGES[@]}"; do
  pkgbuild="$HERE/$package/PKGBUILD"
  [[ -f $pkgbuild ]] || die "missing $pkgbuild"
  bash -n "$pkgbuild"
  if command -v shellcheck >/dev/null 2>&1; then
    shellcheck -s bash -e SC2034,SC2154 "$pkgbuild"
  fi
  srcinfo=$(cd -- "$HERE/$package" && makepkg --printsrcinfo)
  cmp -s <(printf '%s\n' "$srcinfo") "$HERE/$package/.SRCINFO" || \
    die "$package .SRCINFO is stale"
  contains_srcinfo "$package" $'pkgbase = '"$package"
done

for package in lmm-api-bin lmm-api-git; do
  contains_srcinfo_prefix "$package" $'\tprovides = lmm-api'
  contains_srcinfo "$package" $'\toptdepends = lmm-api-go: Go backend provider'
  contains_srcinfo "$package" $'\toptdepends = lmm-api-rs: Rust backend provider'
done
contains_srcinfo lmm-api-bin $'\tconflicts = lmm-api-git'
contains_srcinfo lmm-api-git $'\tconflicts = lmm-api-bin'

for package in lmm-api-go-bin lmm-api-go-git lmm-api-rs-bin lmm-api-rs-git; do
  contains_srcinfo "$package" $'\tdepends = lmm-api'
done
for package in lmm-api-go-bin lmm-api-go-git; do
  contains_srcinfo_prefix "$package" $'\tprovides = lmm-api-go'
done
for package in lmm-api-rs-bin lmm-api-rs-git; do
  contains_srcinfo_prefix "$package" $'\tprovides = lmm-api-rs'
done
contains_srcinfo lmm-api-go-bin $'\tconflicts = lmm-api-go-git'
contains_srcinfo lmm-api-go-git $'\tconflicts = lmm-api-go-bin'
contains_srcinfo lmm-api-rs-bin $'\tconflicts = lmm-api-rs-git'
contains_srcinfo lmm-api-rs-git $'\tconflicts = lmm-api-rs-bin'

for package in lmm-api-bin lmm-api-go-bin lmm-api-rs-bin; do
  pkgbuild="$HERE/$package/PKGBUILD"
  grep -Fq 'cosign verify-blob' "$pkgbuild" || die "$package lacks Sigstore verification"
  grep -Fq 'sha256sum' "$pkgbuild" || die "$package lacks SHA-256 verification"
  grep -Fq 'noextract=(' "$pkgbuild" || die "$package extracts before verification"
  if grep -Eq '(^|[[:space:]])(go|bun|cargo)([[:space:]]|$)' "$pkgbuild"; then
    die "$package invokes a project compiler"
  fi
done
contains_srcinfo lmm-api-git $'\tmakedepends = bun'
contains_srcinfo lmm-api-go-git $'\tmakedepends = go>=1.25.1'
contains_srcinfo lmm-api-rs-git $'\tmakedepends = cargo'

grep -Fqx 'LMM_API_BACKEND=auto' "$SHARED/backend.conf" || die 'default backend is not auto'
grep -Fq 'Environment=LMM_API_BACKEND=auto' "$SHARED/lmm-api.service" || \
  die 'systemd default backend is not auto'

tmp=$(mktemp -d "${TMPDIR:-/tmp}/lmm-aur-matrix.XXXXXXXX")
cleanup() { rm -rf -- "$tmp"; }
trap cleanup EXIT
mkdir -p "$tmp/backends/go" "$tmp/backends/rs"
printf '%s\n' '#!/usr/bin/env bash' 'printf "go:%s\n" "$*"' > "$tmp/backends/go/lmm-api"
# shellcheck disable=SC2016 # Write a literal fixture script.
printf '%s\n' '#!/usr/bin/env bash' 'printf "rs:%s\n" "$LMM_DATABASE_SCHEMA"' \
  > "$tmp/backends/rs/lmm-api-rs"
chmod 0755 "$tmp/backends/go/lmm-api" "$tmp/backends/rs/lmm-api-rs"
output=$(LMM_API_BACKEND_ROOT="$tmp/backends" LMM_API_BACKEND=auto \
  "$SHARED/lmm-api-launcher" marker)
[[ $output == go:marker ]] || die 'auto selection did not prefer Go'
rm -f "$tmp/backends/go/lmm-api"
output=$(LMM_API_BACKEND_ROOT="$tmp/backends" LMM_API_BACKEND=auto \
  LMM_DATABASE_SCHEMA=lmm_preview_fixture "$SHARED/lmm-api-launcher")
[[ $output == rs:lmm_preview_fixture ]] || die 'auto selection did not fall back to Rust'

grep -Fq '/usr/bin/lmm-api' "$HERE/lmm-api-bin/PKGBUILD" || die 'core bin lacks launcher'
grep -Fq '/usr/bin/lmm-api' "$HERE/lmm-api-git/PKGBUILD" || die 'core git lacks launcher'
grep -Fq '/usr/lib/lmm-api/backends/go/lmm-api' "$HERE/lmm-api-go-bin/PKGBUILD" || \
  die 'Go bin backend layout is wrong'
grep -Fq '/usr/lib/lmm-api/backends/go/lmm-api' "$HERE/lmm-api-go-git/PKGBUILD" || \
  die 'Go git backend layout is wrong'
for package in lmm-api-rs-bin lmm-api-rs-git; do
  grep -Fq '/usr/lib/lmm-api/backends/rs/lmm-api-rs' "$HERE/$package/PKGBUILD" || \
    die "$package backend layout is wrong"
  grep -Fq '/usr/lib/lmm-api/backends/rs/lmm-db-migrate' "$HERE/$package/PKGBUILD" || \
    die "$package migrator layout is wrong"
done

stage="$tmp/stage"
mkdir -p "$stage/core/lmm-api-core-0.1.1/frontend-dist" \
  "$stage/go/lmm-api-go-0.1.1-linux-amd64" \
  "$stage/rs/lmm-api-rs-0.1.1-linux-amd64"
cp "$SHARED"/* "$stage/core/lmm-api-core-0.1.1/"
printf '<!doctype html>\n' > "$stage/core/lmm-api-core-0.1.1/frontend-dist/index.html"
printf '#!/bin/sh\n' > "$stage/go/lmm-api-go-0.1.1-linux-amd64/lmm-api"
printf '#!/bin/sh\n' > "$stage/rs/lmm-api-rs-0.1.1-linux-amd64/lmm-api-rs"
printf '#!/bin/sh\n' > "$stage/rs/lmm-api-rs-0.1.1-linux-amd64/lmm-db-migrate"
chmod 0755 "$stage/go/lmm-api-go-0.1.1-linux-amd64/lmm-api" \
  "$stage/rs/lmm-api-rs-0.1.1-linux-amd64/lmm-api-rs" \
  "$stage/rs/lmm-api-rs-0.1.1-linux-amd64/lmm-db-migrate"
for component in core/lmm-api-core-0.1.1 go/lmm-api-go-0.1.1-linux-amd64 \
  rs/lmm-api-rs-0.1.1-linux-amd64; do
  for file in LICENSE NOTICE THIRD-PARTY-LICENSES.md; do
    printf 'fixture\n' > "$stage/$component/$file"
  done
  printf '%040d\n' 0 > "$stage/$component/REVISION"
done

(
  srcdir="$stage/core"
  pkgdir="$tmp/pkg-core"
  # shellcheck disable=SC1091 # Dynamic path to the package under test.
  source "$HERE/lmm-api-bin/PKGBUILD"
  package
)
(
  # shellcheck disable=SC2034 # Consumed by the sourced PKGBUILD.
  CARCH=x86_64
  srcdir="$stage/go"
  pkgdir="$tmp/pkg-go"
  # shellcheck disable=SC1091 # Dynamic path to the package under test.
  source "$HERE/lmm-api-go-bin/PKGBUILD"
  package
)
(
  # shellcheck disable=SC2034
  local_srcdir="$stage/rs"
  local_pkgdir="$tmp/pkg-rs"
  # shellcheck disable=SC2034
  srcdir=$local_srcdir
  # shellcheck disable=SC2034
  pkgdir=$local_pkgdir
  # shellcheck disable=SC1091 # Dynamic path to the package under test.
  source "$HERE/lmm-api-rs-bin/PKGBUILD"
  package
)
for path in \
  pkg-core/usr/bin/lmm-api \
  pkg-core/usr/bin/lmm-api-select \
  pkg-core/usr/lib/systemd/system/lmm-api.service \
  pkg-core/usr/share/lmm-api/frontend-dist/index.html \
  pkg-go/usr/lib/lmm-api/backends/go/lmm-api \
  pkg-rs/usr/lib/lmm-api/backends/rs/lmm-api-rs \
  pkg-rs/usr/lib/lmm-api/backends/rs/lmm-db-migrate; do
  [[ -f $tmp/$path ]] || die "mock package layout is missing $path"
done

printf '%s\n' 'six-package AUR matrix contract verified'
