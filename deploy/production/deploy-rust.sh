#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
REPO_ROOT=$(cd -- "$SCRIPT_DIR/../.." && pwd -P)
readonly SCRIPT_DIR REPO_ROOT

die() { printf 'deploy-rust: %s\n' "$*" >&2; exit 1; }

[[ ${CONFIRM_PRODUCTION:-} == api.lmm.best ]] || die 'CONFIRM_PRODUCTION must equal api.lmm.best'
[[ ${LMM_API_BACKEND:-} == rust ]] || die 'LMM_API_BACKEND must equal rust'

source_ref=${LMM_SOURCE_REF:-HEAD}
revision=$(git -C "$REPO_ROOT" rev-parse --verify "${source_ref}^{commit}")
head_revision=$(git -C "$REPO_ROOT" rev-parse HEAD)
[[ $revision == "$head_revision" ]] || die 'source ref must resolve to the checked-out HEAD'
git -C "$REPO_ROOT" diff --quiet || die 'tracked worktree changes must be committed first'
git -C "$REPO_ROOT" diff --cached --quiet || die 'staged changes must be committed first'

short_revision=$(git -C "$REPO_ROOT" rev-parse --short=8 "$revision")

(
  cd -- "$REPO_ROOT"
  VITE_REACT_APP_VERSION=$short_revision bun run build:web
)

cargo build --manifest-path "$REPO_ROOT/apps/api-rust/Cargo.toml" --release
ARTIFACT_PATH="$REPO_ROOT/apps/api-rust/target/release/lmm-api-rs"
ARTIFACT_SHA256=$(sha256sum "$ARTIFACT_PATH" | awk '{print $1}')

DEPLOY_SCRIPT="$REPO_ROOT/deploy/backend-rust/deploy-lmm-api-rs.sh"
if [[ ! -x "$DEPLOY_SCRIPT" ]]; then
  die "Rust deployment script $DEPLOY_SCRIPT is missing or not executable"
fi
export LMM_RS_CUTOVER_APPROVAL=GO_FREEZE_OVERRIDE_INTERNAL_PROBES

exec "$DEPLOY_SCRIPT" \
  --artifact "$ARTIFACT_PATH" \
  --sha256 "$ARTIFACT_SHA256" \
  --revision "$short_revision" \
  --approve-cutover \
  --cutover-target internal-probes \
  --cutover-revision "$short_revision" \
  "$@"
