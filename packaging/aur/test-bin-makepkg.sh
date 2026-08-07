#!/usr/bin/env bash
set -Eeuo pipefail

HERE=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
readonly HERE
REPO_ROOT=$(cd -- "$HERE/../.." && pwd -P)
readonly REPO_ROOT
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
  local package=$1
  shift
  local work="$tmp/$package" archive expected verify_root
  PATH="$tmp/bin:$PATH" BUILDDIR="$work/build" PKGDEST="$work/packages" \
    makepkg --dir "$work" --force --nodeps --noconfirm --cleanbuild
  archive=$(printf '%s\n' "$work/packages"/*.pkg.tar.*)
  [[ -f $archive ]] || die "$package did not produce a package archive"
  for expected in "$@"; do
    bsdtar -tf "$archive" | grep -Fqx "$expected" || \
      die "$package archive is missing $expected"
  done
  if [[ $package == lmm-api-bin ]]; then
    for expected in usr/bin/lmm-api-select usr/bin/lmm-api-deploy; do
      if bsdtar -tf "$archive" | grep -Fqx "$expected"; then
        die "$package archive exposes retired command $expected"
      fi
    done
    verify_root="$work/verify"
    mkdir -p "$verify_root"
    bsdtar -xf "$archive" -C "$verify_root"
    (
      cd -- "$verify_root/usr/lib/lmm-api/deploy"
      sha256sum -c route-gate-assets.sha256 >/dev/null
    )
  fi
}

core="$tmp/lmm-api-bin"
core_bundle="$core/stage/lmm-api-core-0.1.2"
deploy_bundle="$core_bundle/deploy"
mkdir -p "$core_bundle/frontend-dist" "$deploy_bundle/route-evidence" \
  "$deploy_bundle/migration-evidence"
cp "$HERE/lmm-api-bin/PKGBUILD" "$HERE/lmm-api-bin/lmm-api-bin.install" "$core/"
cp "$SHARED"/* "$core_bundle/"
cp "$REPO_ROOT/apps/web/scripts/production-acceptance.mjs" \
  "$REPO_ROOT/apps/web/scripts/production-acceptance-lib.mjs" "$deploy_bundle/"
cp "$REPO_ROOT/apps/api-rust/tests/fixtures/routes/migration-gate.tsv" \
  "$REPO_ROOT/apps/api-rust/tests/fixtures/routes/frozen-route-auth.tsv" "$deploy_bundle/"
cp "$SHARED/validate-route-gate" "$SHARED/migration-compatibility.env" "$deploy_bundle/"
printf 'route evidence fixture\n' > "$deploy_bundle/route-evidence/fixture.txt"
printf 'migration evidence fixture\n' > "$deploy_bundle/migration-evidence/fixture.txt"
(
  cd -- "$deploy_bundle"
  sha256sum migration-gate.tsv validate-route-gate migration-compatibility.env \
    frozen-route-auth.tsv > route-gate-assets.sha256
)
printf '<!doctype html>\n' > "$core_bundle/frontend-dist/index.html"
add_metadata "$core_bundle"
create_archive "$core" lmm-api-core-0.1.2
build_package lmm-api-bin \
  usr/bin/lmm-api \
  usr/lib/systemd/system/lmm-api.service \
  usr/lib/lmm-api/deploy/production-acceptance.mjs \
  usr/lib/lmm-api/deploy/production-acceptance-lib.mjs \
  usr/lib/lmm-api/deploy/migration-gate.tsv \
  usr/lib/lmm-api/deploy/validate-route-gate \
  usr/lib/lmm-api/deploy/migration-compatibility.env \
  usr/lib/lmm-api/deploy/frozen-route-auth.tsv \
  usr/lib/lmm-api/deploy/route-gate-assets.sha256 \
  usr/lib/lmm-api/deploy/route-evidence/fixture.txt \
  usr/lib/lmm-api/deploy/migration-evidence/fixture.txt \
  usr/share/lmm-api/frontend-dist/index.html

go="$tmp/lmm-api-go-bin"
mkdir -p "$go/stage/lmm-api-go-0.1.2-linux-amd64"
cp "$HERE/lmm-api-go-bin/PKGBUILD" "$go/"
printf '#!/bin/sh\nexit 0\n' > "$go/stage/lmm-api-go-0.1.2-linux-amd64/lmm-api"
chmod 0755 "$go/stage/lmm-api-go-0.1.2-linux-amd64/lmm-api"
add_metadata "$go/stage/lmm-api-go-0.1.2-linux-amd64"
create_archive "$go" lmm-api-go-0.1.2-linux-amd64
build_package lmm-api-go-bin usr/lib/lmm-api/backends/go/lmm-api

rs="$tmp/lmm-api-rs-bin"
mkdir -p "$rs/stage/lmm-api-rs-0.1.2-linux-amd64"
cp "$HERE/lmm-api-rs-bin/PKGBUILD" "$rs/"
for binary in lmm-api-rs lmm-db-migrate; do
  printf '#!/bin/sh\nexit 0\n' > "$rs/stage/lmm-api-rs-0.1.2-linux-amd64/$binary"
  chmod 0755 "$rs/stage/lmm-api-rs-0.1.2-linux-amd64/$binary"
done
add_metadata "$rs/stage/lmm-api-rs-0.1.2-linux-amd64"
create_archive "$rs" lmm-api-rs-0.1.2-linux-amd64
build_package lmm-api-rs-bin \
  usr/lib/lmm-api/backends/rs/lmm-api-rs \
  usr/lib/lmm-api/backends/rs/lmm-db-migrate

printf '%s\n' 'prebuilt AUR packages built with makepkg'
