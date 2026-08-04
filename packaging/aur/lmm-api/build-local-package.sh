#!/usr/bin/env bash
set -Eeuo pipefail
umask 022

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
readonly SCRIPT_DIR
REPO_ROOT=$(cd -- "$SCRIPT_DIR/../../.." && pwd -P)
readonly REPO_ROOT

GO_BINARY=${LMM_API_GO_BINARY:-$REPO_ROOT/apps/api-go/out/lmm-api}
RS_BINARY=${LMM_API_RS_BINARY:-$REPO_ROOT/apps/api-rust/target/release/lmm-api-rs}
MIGRATOR_BINARY=${LMM_API_MIGRATOR_BINARY:-$REPO_ROOT/apps/api-rust/target/release/lmm-db-migrate}
FRONTEND_DIST=${LMM_API_FRONTEND_DIST:-$REPO_ROOT/apps/web/dist}
OUTPUT_DIR=${LMM_API_PKGDEST:-$SCRIPT_DIR/out}

die() { printf 'build-local-package: %s\n' "$*" >&2; exit 1; }

while (($#)); do
  case $1 in
    --output-dir) (($# >= 2)) || die '--output-dir requires a path'; OUTPUT_DIR=$2; shift 2 ;;
    -h|--help) printf '%s\n' 'Usage: build-local-package.sh [--output-dir PATH]'; exit 0 ;;
    *) die "unknown argument: $1" ;;
  esac
done

for command in file install makepkg pacman sha256sum tar; do
  command -v "$command" >/dev/null 2>&1 || die "required command is unavailable: $command"
done
for binary in "$GO_BINARY" "$RS_BINARY" "$MIGRATOR_BINARY"; do
  [[ -x $binary && ! -L $binary ]] || die "binary is missing or unsafe: $binary"
  file -Lb "$binary" | grep -Eq '^ELF 64-bit LSB (pie )?executable, x86-64,' || \
    die "expected an x86-64 ELF executable: $binary"
done
[[ -d $FRONTEND_DIST && ! -L $FRONTEND_DIST && -f $FRONTEND_DIST/index.html ]] || \
  die "frontend dist is missing, unsafe, or lacks index.html: $FRONTEND_DIST"

pkgver=$({ "$GO_BINARY" --version || true; } | head -n1)
[[ $pkgver =~ ^[0-9][0-9A-Za-z._+]*$ ]] || die "Go binary returned an invalid pkgver: $pkgver"
[[ $OUTPUT_DIR == /* ]] || OUTPUT_DIR="$PWD/$OUTPUT_DIR"
mkdir -p -- "$OUTPUT_DIR"
OUTPUT_DIR=$(cd -- "$OUTPUT_DIR" && pwd -P)

build_dir=$(mktemp -d "${TMPDIR:-/tmp}/lmm-api-split-package.XXXXXXXX")
pkgdest=$(mktemp -d "${TMPDIR:-/tmp}/lmm-api-split-pkgdest.XXXXXXXX")
cleanup() { rm -rf -- "$build_dir" "$pkgdest"; }
trap cleanup EXIT
mkdir -p -- "$build_dir/makepkg"

for file in PKGBUILD lmm-api-launcher lmm-api-select lmm-api.service lmm-api.env \
  backend.conf lmm-api.install lmm-api-rs.env.example; do
  install -Dm0644 "$SCRIPT_DIR/$file" "$build_dir/$file"
done
chmod 0755 "$build_dir/lmm-api-launcher" "$build_dir/lmm-api-select" "$build_dir/lmm-api.install"
install -Dm0755 "$GO_BINARY" "$build_dir/lmm-api-go-bin"
install -Dm0755 "$RS_BINARY" "$build_dir/lmm-api-rs-bin"
install -Dm0755 "$MIGRATOR_BINARY" "$build_dir/lmm-db-migrate-bin"
for file in LICENSE NOTICE THIRD-PARTY-LICENSES.md; do
  install -Dm0644 "$REPO_ROOT/$file" "$build_dir/$file"
done
tar --sort=name --mtime='UTC 1970-01-01' --owner=0 --group=0 --numeric-owner \
  -C "$FRONTEND_DIST" -cf "$build_dir/frontend-dist.tar" .

(
  cd -- "$build_dir"
  BUILDDIR="$build_dir/makepkg" PKGDEST="$pkgdest" \
    LMM_API_PKGVER="$pkgver" LMM_API_PKGREL=1 \
    makepkg --force --nodeps --noconfirm --cleanbuild
)

for package_name in lmm-api lmm-api-go lmm-api-rs; do
  matches=("$pkgdest/$package_name-$pkgver-1-x86_64.pkg.tar."*)
  [[ ${#matches[@]} -eq 1 && -f ${matches[0]} ]] || die "missing package: $package_name"
  destination="$OUTPUT_DIR/${matches[0]##*/}"
  install -Dm0644 "${matches[0]}" "$destination"
  sha256sum "$destination" >"$destination.sha256"
  pacman -Qip "$destination"
done
