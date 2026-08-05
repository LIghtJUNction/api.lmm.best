#!/usr/bin/env bash
set -Eeuo pipefail

HERE=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
readonly HERE
readonly SHARED="$HERE/../common/lmm-api"

die() { printf 'test-bin-makepkg: %s\n' "$*" >&2; exit 1; }

tmp=$(mktemp -d "${TMPDIR:-/tmp}/lmm-bin-makepkg.XXXXXXXX")
cleanup() { rm -rf -- "$tmp"; }
trap cleanup EXIT
mkdir -p "$tmp/bin"
install -Dm0755 /usr/bin/true "$tmp/bin/cosign"

add_metadata() {
  local bundle=$1
  for file in LICENSE NOTICE THIRD-PARTY-LICENSES.md; do
    printf 'fixture\n' > "$bundle/$file"
  done
  printf '%040d\n' 0 > "$bundle/REVISION"
}

create_archive() {
  local work=$1 artifact=$2
  tar -czf "$work/${artifact}.tar.gz" -C "$work/stage" "$artifact"
  (cd "$work" && sha256sum "${artifact}.tar.gz" > "${artifact}.tar.gz.sha256")
  printf '{}\n' > "$work/${artifact}.tar.gz.sigstore.json"
}

build_package() {
  local package=$1 expected=$2
  local work="$tmp/$package"
  PATH="$tmp/bin:$PATH" BUILDDIR="$work/build" PKGDEST="$work/packages" \
    makepkg --dir "$work" --force --nodeps --noconfirm --cleanbuild
  archive=$(printf '%s\n' "$work/packages"/*.pkg.tar.*)
  [[ -f $archive ]] || die "$package did not produce a package archive"
  bsdtar -tf "$archive" | grep -Fqx "$expected" || \
    die "$package archive is missing $expected"
}

core="$tmp/lmm-api-bin"
mkdir -p "$core/stage/lmm-api-core-0.1.1/frontend-dist"
cp "$HERE/lmm-api-bin/PKGBUILD" "$HERE/lmm-api-bin/lmm-api-bin.install" "$core/"
cp "$SHARED"/* "$core/stage/lmm-api-core-0.1.1/"
printf '<!doctype html>\n' > "$core/stage/lmm-api-core-0.1.1/frontend-dist/index.html"
add_metadata "$core/stage/lmm-api-core-0.1.1"
create_archive "$core" lmm-api-core-0.1.1
build_package lmm-api-bin usr/bin/lmm-api

go="$tmp/lmm-api-go-bin"
mkdir -p "$go/stage/lmm-api-go-0.1.1-linux-amd64"
cp "$HERE/lmm-api-go-bin/PKGBUILD" "$go/"
printf '#!/bin/sh\nexit 0\n' > "$go/stage/lmm-api-go-0.1.1-linux-amd64/lmm-api"
chmod 0755 "$go/stage/lmm-api-go-0.1.1-linux-amd64/lmm-api"
add_metadata "$go/stage/lmm-api-go-0.1.1-linux-amd64"
create_archive "$go" lmm-api-go-0.1.1-linux-amd64
build_package lmm-api-go-bin usr/lib/lmm-api/backends/go/lmm-api

rs="$tmp/lmm-api-rs-bin"
mkdir -p "$rs/stage/lmm-api-rs-0.1.1-linux-amd64"
cp "$HERE/lmm-api-rs-bin/PKGBUILD" "$rs/"
for binary in lmm-api-rs lmm-db-migrate; do
  printf '#!/bin/sh\nexit 0\n' > "$rs/stage/lmm-api-rs-0.1.1-linux-amd64/$binary"
  chmod 0755 "$rs/stage/lmm-api-rs-0.1.1-linux-amd64/$binary"
done
add_metadata "$rs/stage/lmm-api-rs-0.1.1-linux-amd64"
create_archive "$rs" lmm-api-rs-0.1.1-linux-amd64
build_package lmm-api-rs-bin usr/lib/lmm-api/backends/rs/lmm-api-rs

printf '%s\n' 'prebuilt AUR packages built with makepkg'
