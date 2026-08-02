#!/usr/bin/env bash
set -euo pipefail

readonly BASE_COMMIT='3e39995a092f960882db6bf455b371d32591dc47'
readonly RELEASE_VERSION='0.1.0.r29.g3e39995.payrate2'
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd -- "$SCRIPT_DIR/.." && pwd)"
PATCH_FILE="$SCRIPT_DIR/channel-pricing.patch"
OUT_DIR="$SCRIPT_DIR/out"
WEB_DIST=''

usage() {
  printf 'Usage: %s --web-dist /path/to/verified/web-dist\n' "${0##*/}" >&2
}

while (($# > 0)); do
  case "$1" in
    --web-dist)
      (($# >= 2)) || { usage; exit 2; }
      WEB_DIST="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      usage
      exit 2
      ;;
  esac
done

[[ -n "$WEB_DIST" ]] || { usage; exit 2; }
[[ -d "$WEB_DIST" ]] || { printf 'web dist is not a directory: %s\n' "$WEB_DIST" >&2; exit 1; }
[[ -f "$PATCH_FILE" ]] || { printf 'missing patch: %s\n' "$PATCH_FILE" >&2; exit 1; }

SOURCE_DIR="$(mktemp -d "${TMPDIR:-/tmp}/lmm-channel-pricing-build.XXXXXX")"
OUTPUT_TMP=''
cleanup() {
  rm -rf -- "$SOURCE_DIR"
  if [[ -n "$OUTPUT_TMP" ]]; then
    rm -f -- "$OUTPUT_TMP"
  fi
}
trap cleanup EXIT

git -C "$REPO_DIR" archive "$BASE_COMMIT" | tar -x -C "$SOURCE_DIR"
git -C "$SOURCE_DIR" apply --check "$PATCH_FILE"
git -C "$SOURCE_DIR" apply "$PATCH_FILE"
mkdir -p "$SOURCE_DIR/web/dist"
cp -a -- "$WEB_DIST/." "$SOURCE_DIR/web/dist/"

mkdir -p "$OUT_DIR"
OUTPUT_TMP="$(mktemp "$OUT_DIR/.lmm-api.XXXXXX")"
(
  cd "$SOURCE_DIR"
  GOPROXY=off CGO_ENABLED=0 go build -trimpath -buildvcs=false \
    -ldflags "-s -w -extldflags '-static' -X github.com/QuantumNous/new-api/common.Version=$RELEASE_VERSION" \
    -o "$OUTPUT_TMP" .
)
chmod 0755 "$OUTPUT_TMP"
version_output="$("$OUTPUT_TMP" --version)"
if [[ "$version_output" != "$RELEASE_VERSION" ]]; then
  printf 'version assertion failed: expected %s, got %s\n' "$RELEASE_VERSION" "$version_output" >&2
  exit 1
fi
file_output="$(file -Lb "$OUTPUT_TMP")"
if [[ "$file_output" != *'statically linked'* ]]; then
  printf 'static file assertion failed: %s\n' "$file_output" >&2
  exit 1
fi
ldd_output="$(ldd "$OUTPUT_TMP" 2>&1 || true)"
if [[ "$ldd_output" != *'not a dynamic executable'* ]]; then
  printf 'static ldd assertion failed: %s\n' "$ldd_output" >&2
  exit 1
fi
mv -f -- "$OUTPUT_TMP" "$OUT_DIR/lmm-api"
OUTPUT_TMP=''

printf 'built %s from %s version=%s\n' "$OUT_DIR/lmm-api" "$BASE_COMMIT" "$RELEASE_VERSION"
sha256sum "$OUT_DIR/lmm-api"
