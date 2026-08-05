#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
REPO_ROOT=$(cd -- "$SCRIPT_DIR/../.." && pwd -P)
readonly SCRIPT_DIR REPO_ROOT
readonly HOST=${LMM_PRODUCTION_HOST:-ArchDmit}
readonly EXPECTED_HOST=arch-dmit

die() { printf 'deploy-go: %s\n' "$*" >&2; exit 1; }

[[ ${CONFIRM_PRODUCTION:-} == api.lmm.best ]] || die 'CONFIRM_PRODUCTION must equal api.lmm.best'
[[ ${LMM_API_BACKEND:-} == go ]] || die 'LMM_API_BACKEND must equal go'
for command in bun git jq makepkg pacman scp sha256sum ssh tar; do
  command -v "$command" >/dev/null 2>&1 || die "required command is unavailable: $command"
done
[[ $(ssh "$HOST" hostnamectl --static) == "$EXPECTED_HOST" ]] || die 'production host identity mismatch'

source_ref=${LMM_SOURCE_REF:-HEAD}
revision=$(git -C "$REPO_ROOT" rev-parse --verify "${source_ref}^{commit}")
head_revision=$(git -C "$REPO_ROOT" rev-parse HEAD)
[[ $revision == "$head_revision" ]] || die 'source ref must resolve to the checked-out HEAD'
git -C "$REPO_ROOT" diff --quiet || die 'tracked worktree changes must be committed first'
git -C "$REPO_ROOT" diff --cached --quiet || die 'staged changes must be committed first'

base_version=$(git -C "$REPO_ROOT" show "$revision:VERSION")
[[ $base_version =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || die 'VERSION is not semantic'
revision_count=$(git -C "$REPO_ROOT" rev-list --count "$revision")
short_revision=$(git -C "$REPO_ROOT" rev-parse --short=8 "$revision")
release_version="$base_version.r$revision_count.g$short_revision"
installed_version=$(ssh "$HOST" pacman -Q lmm-api-go | awk '{print $2}')
installed_version=${installed_version%-1}
# Both package versions are locally validated data.
# shellcheck disable=SC2029
comparison=$(ssh "$HOST" vercmp "$installed_version" "$release_version")
(( comparison < 0 )) || die "release does not upgrade production: $installed_version -> $release_version"

work_dir=$(mktemp -d "${TMPDIR:-/tmp}/lmm-api-production.XXXXXXXX")
# Invoked indirectly by the EXIT trap.
# shellcheck disable=SC2329
cleanup() { rm -rf -- "$work_dir"; }
trap cleanup EXIT
mkdir -p "$work_dir/new" "$work_dir/rollback"

(
  cd -- "$REPO_ROOT"
  VITE_REACT_APP_VERSION=$release_version bun run build:web
)
"$SCRIPT_DIR/build-go-binary.sh" \
  --source-ref "$revision" \
  --version "$release_version"
"$SCRIPT_DIR/build-go-package.sh" \
  --binary "$REPO_ROOT/apps/api-go/out/lmm-api" \
  --output-dir "$work_dir/new"

scp "$HOST:/usr/lib/lmm-api/backends/go/lmm-api" "$work_dir/rollback/lmm-api"
chmod 0755 "$work_dir/rollback/lmm-api"
[[ $("$work_dir/rollback/lmm-api" --version) == "$installed_version" ]] || \
  die 'downloaded rollback binary does not match the installed package'
"$SCRIPT_DIR/build-go-package.sh" \
  --binary "$work_dir/rollback/lmm-api" \
  --output-dir "$work_dir/rollback"

if find "$REPO_ROOT/apps/web/dist" -type l -print -quit | grep -q .; then
  die 'frontend dist must not contain symlinks'
fi
frontend_archive="$work_dir/frontend-dist.tar"
tar --sort=name --mtime='UTC 1970-01-01' --owner=0 --group=0 --numeric-owner \
  -C "$REPO_ROOT/apps/web/dist" -cf "$frontend_archive" .
frontend_sha256=$(sha256sum "$frontend_archive" | awk '{print $1}')

new_package=$(find "$work_dir/new" -maxdepth 1 -type f -name 'lmm-api-go-*.pkg.tar.*' ! -name '*.sha256' -print -quit)
rollback_package=$(find "$work_dir/rollback" -maxdepth 1 -type f -name 'lmm-api-go-*.pkg.tar.*' ! -name '*.sha256' -print -quit)
[[ -n $new_package && -n $rollback_package ]] || die 'release or rollback package is missing'
new_sha256=$(sha256sum "$new_package" | awk '{print $1}')
rollback_sha256=$(sha256sum "$rollback_package" | awk '{print $1}')

remote_stage="/var/lib/lmm-api/deploy-staging/$release_version"
ssh "$HOST" install -d -m0700 "$remote_stage"
scp \
  "$SCRIPT_DIR/activate-go-release.sh" \
  "$SCRIPT_DIR/../frontend-release.sh" \
  "$frontend_archive" \
  "$new_package" \
  "$rollback_package" \
  "$HOST:$remote_stage/"
# The remote path is derived from a validated pkgver.
# shellcheck disable=SC2029
ssh "$HOST" chmod 0700 \
  "$remote_stage/activate-go-release.sh" \
  "$remote_stage/frontend-release.sh"

new_name=${new_package##*/}
rollback_name=${rollback_package##*/}
status_file="$remote_stage/status"
unit="lmm-api-go-deploy-$short_revision"
ssh "$HOST" systemd-run \
  --unit="$unit" \
  --collect \
  --property=Type=oneshot \
  "$remote_stage/activate-go-release.sh" \
  --package "$remote_stage/$new_name" \
  --package-sha256 "$new_sha256" \
  --rollback-package "$remote_stage/$rollback_name" \
  --rollback-sha256 "$rollback_sha256" \
  --frontend-archive "$remote_stage/${frontend_archive##*/}" \
  --frontend-sha256 "$frontend_sha256" \
  --frontend-release-script "$remote_stage/frontend-release.sh" \
  --expected-version "$release_version" \
  --status-file "$status_file"

printf 'deployment_unit=%s\nrelease_version=%s\nstatus_file=%s\n' \
  "$unit" "$release_version" "$status_file"

for _ in {1..90}; do
  # The remote path is derived from a validated pkgver.
  # shellcheck disable=SC2029
  remote_status=$(ssh "$HOST" cat -- "$status_file" 2>/dev/null || true)
  case $remote_status in
    DEPLOYED\ *) printf 'deployment_status=%s\n' "$remote_status"; exit 0 ;;
    ROLLED_BACK\ *|ROLLBACK_FAILED\ *) die "$remote_status" ;;
  esac
  sleep 2
done
die "deployment status timed out; inspect $unit and $status_file on $EXPECTED_HOST"
