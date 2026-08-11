#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
REPO_ROOT=$(cd -- "$SCRIPT_DIR/../.." && pwd -P)
readonly SCRIPT_DIR REPO_ROOT

die() { printf 'build-go-package: %s\n' "$*" >&2; exit 2; }

WORKSPACE=''
BINARY=''
FRONTEND=''
OUTPUT_DIR=''
while (($#)); do
  case $1 in
    --workspace) (($# >= 2)) || die '--workspace requires a value'; WORKSPACE=$2; shift 2 ;;
    --binary) (($# >= 2)) || die '--binary requires a value'; BINARY=$2; shift 2 ;;
    --frontend) (($# >= 2)) || die '--frontend requires a value'; FRONTEND=$2; shift 2 ;;
    --output-dir) (($# >= 2)) || die '--output-dir requires a value'; OUTPUT_DIR=$2; shift 2 ;;
    -h|--help)
      printf '%s\n' 'Usage: build-go-package.sh --workspace PATH --binary PATH --frontend PATH --output-dir PATH'
      exit 0
      ;;
    *) die "unknown argument: $1" ;;
  esac
done

[[ -n $WORKSPACE && -n $BINARY && -n $FRONTEND && -n $OUTPUT_DIR ]] || die 'all arguments are required'
exec "$REPO_ROOT/packaging/local/lmm-api-go/build-local-package.sh" \
  --workspace "$WORKSPACE" \
  --binary "$BINARY" \
  --frontend "$FRONTEND" \
  --output-dir "$OUTPUT_DIR"
