#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
REPO_ROOT=$(cd -- "$SCRIPT_DIR/../.." && pwd -P)
readonly SCRIPT_DIR REPO_ROOT

die() { printf 'deploy-rust: %s\n' "$*" >&2; exit 1; }

[[ ${CONFIRM_PRODUCTION:-} == api.lmm.best ]] || die 'CONFIRM_PRODUCTION must equal api.lmm.best'
[[ ${LMM_API_BACKEND:-} == rust ]] || die 'LMM_API_BACKEND must equal rust'

DEPLOY_SCRIPT="$REPO_ROOT/deploy/backend-rust/deploy-lmm-api-rs.sh"
if [[ ! -x "$DEPLOY_SCRIPT" ]]; then
  die "Rust deployment script $DEPLOY_SCRIPT is missing or not executable"
fi

exec "$DEPLOY_SCRIPT" "$@"
