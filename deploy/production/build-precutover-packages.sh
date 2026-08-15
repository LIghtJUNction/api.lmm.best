#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
readonly SCRIPT_DIR

die() { printf 'build-precutover-packages: %s\n' "$*" >&2; exit 2; }
is_pkgver() { [[ $1 =~ ^[0-9][0-9A-Za-z._+:]*$ ]]; }
is_pkgrel() { [[ $1 =~ ^[1-9][0-9.]*$ ]]; }

WORKSPACE=''
PAYLOAD=''
OUTPUT_DIR=''
while (($#)); do
  case $1 in
    --workspace) (($# >= 2)) || die '--workspace requires a value'; WORKSPACE=$2; shift 2 ;;
    --payload) (($# >= 2)) || die '--payload requires a value'; PAYLOAD=$2; shift 2 ;;
    --output-dir) (($# >= 2)) || die '--output-dir requires a value'; OUTPUT_DIR=$2; shift 2 ;;
    -h|--help)
      printf '%s\n' 'Usage: build-precutover-packages.sh --workspace PATH --payload PATH --output-dir PATH'
      exit 0
      ;;
    *) die "unknown argument: $1" ;;
  esac
done

[[ $WORKSPACE == /* && -d $WORKSPACE && ! -L $WORKSPACE ]] || die 'workspace must be an absolute real directory'
[[ -f $WORKSPACE/.lmm-deploy-workspace && ! -L $WORKSPACE/.lmm-deploy-workspace ]] || die 'workspace marker is missing'
[[ $(realpath -e -- "$WORKSPACE") == "$WORKSPACE" ]] || die 'workspace must be canonical'
[[ $PAYLOAD == /* && -s $PAYLOAD && -f $PAYLOAD && ! -L $PAYLOAD ]] || die 'payload must be a safe regular file'
[[ $OUTPUT_DIR == /* && $OUTPUT_DIR != / ]] || die 'output directory must be a safe absolute path'
for command in bsdtar install makepkg pacman realpath sha256sum tar wc; do
  command -v "$command" >/dev/null 2>&1 || die "required command is unavailable: $command"
done

if bsdtar -tf "$PAYLOAD" | grep -Eq '(^/|(^|/)\.\.(/|$))'; then
  die 'payload contains an unsafe path'
fi
extract_dir=$(mktemp -d "$WORKSPACE/tmp/precutover-payload.XXXXXXXX")
build_root=$(mktemp -d "$WORKSPACE/tmp/precutover-build.XXXXXXXX")
pkgdest=$(mktemp -d "$WORKSPACE/tmp/precutover-pkgdest.XXXXXXXX")
cleanup() { rm -rf -- "$extract_dir" "$build_root" "$pkgdest"; }
trap cleanup EXIT
# libarchive applies the process umask while extracting archived modes. Keep the
# surrounding workspace private, but preserve the payload's deliberate 0755 and
# 0644 runtime modes inside this already-private extraction directory.
(umask 022; bsdtar -xf "$PAYLOAD" -C "$extract_dir")

metadata=$extract_dir/metadata/packages.tsv
layout_file=$extract_dir/metadata/layout
[[ -f $metadata && ! -L $metadata ]] || die 'payload package metadata is missing'
[[ -f $layout_file && ! -L $layout_file && $(wc -l <"$layout_file") == 1 ]] || \
  die 'payload rollback layout is missing or ambiguous'
IFS= read -r layout <"$layout_file"
case $layout in split|direct) ;; *) die 'payload rollback layout is invalid' ;; esac
core_record=$(awk -F '\t' '$1 == "lmm-api" { print $2 }' "$metadata")
go_record=$(awk -F '\t' '$1 == "lmm-api-go" { print $2 }' "$metadata")
[[ -n $go_record && $go_record != *$'\n'* ]] || die 'payload Go package metadata is ambiguous'
if [[ $layout == split ]]; then
  [[ -n $core_record && $core_record != *$'\n'* ]] || die 'payload core package metadata is ambiguous'
else
  [[ -z $core_record ]] || die 'direct payload unexpectedly contains core package metadata'
fi

go_pkgver=${go_record%-*}
go_pkgrel=${go_record##*-}
if [[ $layout == split ]]; then
  core_pkgver=${core_record%-*}
  core_pkgrel=${core_record##*-}
  if ! is_pkgver "$core_pkgver" || ! is_pkgrel "$core_pkgrel"; then
    die 'invalid pre-cutover core version'
  fi
fi
if ! is_pkgver "$go_pkgver" || ! is_pkgrel "$go_pkgrel"; then
  die 'invalid pre-cutover Go version'
fi

core_root=$extract_dir/core-root
go_root=$extract_dir/go-root
required_files=()
if [[ $layout == split ]]; then
  required_files=(
    "$core_root/usr/bin/lmm-api"
    "$core_root/usr/bin/lmm-api-select"
    "$core_root/usr/lib/systemd/system/lmm-api.service"
    "$core_root/etc/lmm-api/backend.conf"
    "$core_root/etc/lmm-api/lmm-api.env"
    "$core_root/usr/share/licenses/lmm-api/LICENSE"
    "$go_root/usr/lib/lmm-api/backends/go/lmm-api"
  )
else
  required_files=(
    "$go_root/etc/lmm-api-go/lmm-api-go.env"
    "$go_root/usr/bin/lmm-api-go"
    "$go_root/usr/lib/systemd/system/lmm-api-go.service"
    "$go_root/usr/share/doc/lmm-api-go/REVISION"
    "$go_root/usr/share/licenses/lmm-api-go/LICENSE"
    "$go_root/usr/share/licenses/lmm-api-go/NOTICE"
    "$go_root/usr/share/licenses/lmm-api-go/THIRD-PARTY-LICENSES.md"
    "$go_root/usr/share/lmm-api-go/frontend-dist/index.html"
  )
fi
for required in "${required_files[@]}"; do
  [[ -f $required && ! -L $required ]] || die "captured payload is incomplete: ${required#"$extract_dir/"}"
done
if [[ $layout == split ]]; then
  secret_stub=$core_root/etc/lmm-api/lmm-api.env
else
  secret_stub=$go_root/etc/lmm-api-go/lmm-api-go.env
fi
[[ ! -s $secret_stub ]] || die 'captured rollback package must not embed production secrets'
roots=("$go_root")
[[ $layout == direct ]] || roots+=("$core_root")
if find "${roots[@]}" -type l -print -quit | grep -q .; then
  die 'captured package roots must not contain symlinks'
fi

mkdir -p -- "$OUTPUT_DIR"
OUTPUT_DIR=$(realpath -e -- "$OUTPUT_DIR")
build_one() {
  local name=$1 pkgver=$2 pkgrel=$3 template=$4 captured_root=$5 build_dir source_name
  build_dir=$build_root/$name
  source_name=$name
  mkdir -p -- "$build_dir/root"
  install -Dm0644 "$template" "$build_dir/PKGBUILD"
  cp -a -- "$captured_root/." "$build_dir/root/"
  tar --sort=name --mtime='UTC 1970-01-01' --owner=0 --group=0 --numeric-owner \
    -C "$build_dir" -cf "$build_dir/${source_name}-root.tar" root
  rm -rf -- "$build_dir/root"
  (
    cd -- "$build_dir"
    # makepkg inherits this script's private umask. The captured payload already
    # carries deliberate per-file modes, so use the normal packaging umask while
    # extracting it or executable paths become root-only in the rollback package.
    umask 022
    BUILDDIR="$build_dir/makepkg" PKGDEST="$pkgdest" \
      LMM_PRECUTOVER_PKGVER="$pkgver" LMM_PRECUTOVER_PKGREL="$pkgrel" \
      makepkg --force --nodeps --noconfirm --cleanbuild
  )
}

if [[ $layout == split ]]; then
  build_one core "$core_pkgver" "$core_pkgrel" "$SCRIPT_DIR/precutover-lmm-api.PKGBUILD" "$core_root"
  build_one go "$go_pkgver" "$go_pkgrel" "$SCRIPT_DIR/precutover-lmm-api-go.PKGBUILD" "$go_root"
else
  build_one go "$go_pkgver" "$go_pkgrel" "$SCRIPT_DIR/precutover-lmm-api-go-direct.PKGBUILD" "$go_root"
fi

go_matches=("$pkgdest/lmm-api-go-$go_pkgver-$go_pkgrel-x86_64.pkg.tar."*)
[[ ${#go_matches[@]} -eq 1 && -f ${go_matches[0]} ]] || die 'Go rollback package was not produced exactly once'
if [[ $layout == split ]]; then
  core_matches=("$pkgdest/lmm-api-$core_pkgver-$core_pkgrel-x86_64.pkg.tar."*)
  [[ ${#core_matches[@]} -eq 1 && -f ${core_matches[0]} ]] || die 'core rollback package was not produced exactly once'
fi
archive_mode() {
  local archive=$1 entry=$2
  bsdtar -tvf "$archive" "$entry" | awk -v entry="$entry" \
    '$NF == entry { count += 1; mode = $1 } END { if (count == 1) print mode; else exit 2 }'
}
mode_records=()
if [[ $layout == split ]]; then
  mode_records=(
    "${core_matches[0]}:etc/lmm-api/:drwx------"
    "${core_matches[0]}:etc/lmm-api/backend.conf:-rw-r--r--"
    "${core_matches[0]}:usr/bin/:drwxr-xr-x"
    "${core_matches[0]}:usr/bin/lmm-api:-rwxr-xr-x"
    "${core_matches[0]}:usr/bin/lmm-api-select:-rwxr-xr-x"
    "${core_matches[0]}:usr/lib/systemd/system/:drwxr-xr-x"
    "${core_matches[0]}:usr/lib/systemd/system/lmm-api.service:-rw-r--r--"
    "${core_matches[0]}:etc/lmm-api/lmm-api.env:-rw-------"
    "${core_matches[0]}:usr/share/licenses/lmm-api/:drwxr-xr-x"
    "${core_matches[0]}:usr/share/licenses/lmm-api/LICENSE:-rw-r--r--"
    "${go_matches[0]}:usr/lib/lmm-api/:drwxr-xr-x"
    "${go_matches[0]}:usr/lib/lmm-api/backends/:drwxr-xr-x"
    "${go_matches[0]}:usr/lib/lmm-api/backends/go/:drwxr-xr-x"
    "${go_matches[0]}:usr/lib/lmm-api/backends/go/lmm-api:-rwxr-xr-x"
  )
else
  mode_records=(
    "${go_matches[0]}:etc/lmm-api-go/:drwx------"
    "${go_matches[0]}:etc/lmm-api-go/lmm-api-go.env:-rw-------"
    "${go_matches[0]}:usr/bin/lmm-api-go:-rwxr-xr-x"
    "${go_matches[0]}:usr/lib/systemd/system/lmm-api-go.service:-rw-r--r--"
    "${go_matches[0]}:usr/share/lmm-api-go/frontend-dist/:drwxr-xr-x"
    "${go_matches[0]}:usr/share/lmm-api-go/frontend-dist/index.html:-rw-r--r--"
  )
fi
for record in "${mode_records[@]}"; do
  archive=${record%%:*}
  remainder=${record#*:}
  entry=${remainder%%:*}
  expected_mode=${remainder##*:}
  actual_mode=$(archive_mode "$archive" "$entry")
  [[ $actual_mode == "$expected_mode" ]] || \
    die "rollback package mode is unsafe: $entry ($actual_mode, expected $expected_mode)"
done
archives=("${go_matches[0]}")
[[ $layout == direct ]] || archives=("${core_matches[0]}" "${go_matches[0]}")
for archive in "${archives[@]}"; do
  destination=$OUTPUT_DIR/${archive##*/}
  install -Dm0600 "$archive" "$destination"
  sha256sum "$destination" >"$destination.sha256"
  pacman -Qip "$destination" >/dev/null
done
if [[ $layout == split ]]; then
  printf 'layout=split\ncore_package=%s\ngo_package=%s\n' \
    "$OUTPUT_DIR/${core_matches[0]##*/}" "$OUTPUT_DIR/${go_matches[0]##*/}"
else
  install -Dm0600 /dev/null "$OUTPUT_DIR/rollback-layout.direct"
  printf 'direct\n' >"$OUTPUT_DIR/rollback-layout.direct"
  printf 'layout=direct\ncore_package=%s\ngo_package=%s\n' \
    "$OUTPUT_DIR/rollback-layout.direct" "$OUTPUT_DIR/${go_matches[0]##*/}"
fi
