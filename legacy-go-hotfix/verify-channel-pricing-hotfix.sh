#!/usr/bin/env bash
set -euo pipefail

readonly BASE_COMMIT='3e39995a092f960882db6bf455b371d32591dc47'
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd -- "$SCRIPT_DIR/.." && pwd)"
PATCH_FILE="$SCRIPT_DIR/channel-pricing.patch"
WEB_DIST=''

usage() {
  printf 'Usage: %s [--web-dist /path/to/web-dist]\n' "${0##*/}" >&2
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

[[ -f "$PATCH_FILE" ]] || { printf 'missing patch: %s\n' "$PATCH_FILE" >&2; exit 1; }
if [[ -n "$WEB_DIST" && ! -d "$WEB_DIST" ]]; then
  printf 'web dist is not a directory: %s\n' "$WEB_DIST" >&2
  exit 1
fi

SOURCE_DIR="$(mktemp -d "${TMPDIR:-/tmp}/lmm-channel-pricing.XXXXXX")"
cleanup() { rm -rf -- "$SOURCE_DIR"; }
trap cleanup EXIT

git -C "$REPO_DIR" archive "$BASE_COMMIT" | tar -x -C "$SOURCE_DIR"
git -C "$SOURCE_DIR" apply --check "$PATCH_FILE"
git -C "$SOURCE_DIR" apply "$PATCH_FILE"

if [[ -n "$WEB_DIST" ]]; then
  mkdir -p "$SOURCE_DIR/web/dist"
  cp -a -- "$WEB_DIST/." "$SOURCE_DIR/web/dist/"
fi

(
  cd "$SOURCE_DIR"
  go test ./controller -run 'TestQuoteTopUp|TestValidateEpayCallback' -count=1
  go build ./controller
)

printf 'channel-pricing hotfix verified against %s\n' "$BASE_COMMIT"
