#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)

die() { printf 'build-go-package: %s\n' "$*" >&2; exit 1; }

usage() {
  printf '%s\n' 'Usage: build-go-package.sh --binary /absolute/lmm-api --output-dir /absolute/output'
}

BINARY=''
OUTPUT_DIR=''
while (($#)); do
  case $1 in
    --binary) (($# >= 2)) || die '--binary requires a value'; BINARY=$2; shift 2 ;;
    --output-dir) (($# >= 2)) || die '--output-dir requires a value'; OUTPUT_DIR=$2; shift 2 ;;
    --help|-h) usage; exit 0 ;;
    *) die "unknown argument: $1" ;;
  esac
done

[[ $BINARY == /* && -x $BINARY && -f $BINARY && ! -L $BINARY ]] || \
  die '--binary must be an absolute executable regular file'
[[ $OUTPUT_DIR == /* && $OUTPUT_DIR != / ]] || die '--output-dir must be a safe absolute path'
for command in file ldd makepkg pacman readelf sha256sum; do
  command -v "$command" >/dev/null 2>&1 || die "required command is unavailable: $command"
done

version=$($BINARY --version)
[[ $version =~ ^[0-9][0-9A-Za-z._+]*$ ]] || die "binary returned an invalid version: $version"
file -Lb "$BINARY" | grep -Eq '^ELF 64-bit LSB (pie )?executable, x86-64,' || \
  die 'binary is not an x86-64 ELF executable'
if readelf -d "$BINARY" | grep -Fq '(NEEDED)'; then
  die 'binary is dynamically linked'
fi
ldd_output=$(ldd "$BINARY" 2>&1 || true)
case $ldd_output in
  *'not a dynamic executable'*|*'statically linked'*) ;;
  *) die "unexpected ldd result: $ldd_output" ;;
esac

build_dir=$(mktemp -d "${TMPDIR:-/tmp}/lmm-api-go-package.XXXXXXXX")
pkgdest=$(mktemp -d "${TMPDIR:-/tmp}/lmm-api-go-pkgdest.XXXXXXXX")
cleanup() { rm -rf -- "$build_dir" "$pkgdest"; }
trap cleanup EXIT

install -Dm0644 "$SCRIPT_DIR/lmm-api-go.PKGBUILD" "$build_dir/PKGBUILD"
install -Dm0755 "$BINARY" "$build_dir/lmm-api"
(
  cd -- "$build_dir"
  LMM_API_PKGVER=$version PKGDEST=$pkgdest \
    makepkg --cleanbuild --force --nodeps --noconfirm
)

matches=("$pkgdest/lmm-api-go-$version-1-x86_64.pkg.tar."*)
[[ ${#matches[@]} -eq 1 && -f ${matches[0]} ]] || die 'expected exactly one package archive'
archive=${matches[0]}
package_record=$(pacman -Qp --print-format '%n %v' "$archive")
[[ $package_record == "lmm-api-go $version-1" ]] || die "unexpected package record: $package_record"

mkdir -p -- "$OUTPUT_DIR"
destination="$OUTPUT_DIR/${archive##*/}"
[[ ! -e $destination && ! -e $destination.sha256 ]] || die "output already exists: $destination"
install -Dm0644 "$archive" "$destination"
sha256sum "$destination" >"$destination.sha256"
printf 'built_package=%s\n' "$destination"
printf 'package_sha256=%s\n' "$(awk '{print $1}' "$destination.sha256")"
