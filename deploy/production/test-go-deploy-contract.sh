#!/usr/bin/env bash
# shellcheck disable=SC2016 # Literal source snippets are intentional contract assertions.
set -Eeuo pipefail

repo=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd -P)
here=$repo/deploy/production
: "${TMPDIR:?set TMPDIR to a marker-owned workspace}"

fail() { printf 'go-deploy-contract: %s\n' "$*" >&2; exit 1; }
contains() { grep -Fq -- "$1" "$2" || fail "$2 is missing: $1"; }

scripts=(
  "$here/deploy-go.sh"
  "$here/activate-go-release.sh"
  "$here/build-go-binary.sh"
  "$here/build-go-package.sh"
  "$here/build-precutover-packages.sh"
  "$here/capture-precutover-payload.sh"
  "$here/prepare-production-backup.sh"
  "$here/create-backup-copy.sh"
  "$here/promote-production-backups.sh"
)
for script in "${scripts[@]}"; do
  [[ -x $script ]] || fail "production script is not executable: $script"
  bash -n "$script"
done
if command -v shellcheck >/dev/null 2>&1; then
  shellcheck "${scripts[@]}"
fi

for literal in \
  'ExecStart=/usr/bin/lmm-api-go serve' \
  'Environment=LMM_API_FRONTEND_DIR=/usr/share/lmm-api-go/frontend-dist' \
  'Environment=LMM_DB_MIGRATION_MODE=verify'; do
  contains "$literal" "$repo/packaging/common/lmm-api/lmm-api-go.service"
done
for literal in \
  'lmm-api-go-rollback-$deployment_id.timer' \
  'Persistent=true' \
	'write_status "AWAITING_CONFIRMATION' \
	'write_status "CONFIRMED' \
	'write_status "MIGRATING' \
  'probe_authenticated_models' \
	'discover_database_schema' \
	'database_schema=%s' \
	'"$PROBE_BINARY" request' \
	'run_candidate_migration apply' \
	'run_candidate_migration verify' \
  'pacman -Rdd --noconfirm lmm-api' \
  'release_transaction_lock'; do
  contains "$literal" "$here/activate-go-release.sh"
done
if grep -Fq 'search_path=public' "$here/activate-go-release.sh" \
  "$repo/packaging/common/lmm-api/lmm-api-go.service"; then
  fail 'production activation or service unit still hard-codes the public schema'
fi
contains 'PGOPTIONS="-c search_path=public"' "$repo/packaging/common/lmm-api/lmm-api-go.env"
for literal in \
  'origin/main' \
  'backup-target-$deployment_id' \
  'old_version=$(ssh -o BatchMode=yes "$HOST" cat --' \
  'select(.success == true and .ready == true and (.data.version | type == "string")) | .data.version' \
  'pg_restore --list' \
  'LMM_BACKUP_AGE_IDENTITY_FILE' \
  'decrypted database backup does not match the target copy' \
  'production observation detected an anomaly; rollback timer remains armed' \
  'activate-go-release.sh" confirm'; do
  contains "$literal" "$here/deploy-go.sh"
done
if grep -Fq 'old_version=$(ssh -o BatchMode=yes "$HOST" jq' "$here/deploy-go.sh"; then
  fail 'pre-cutover version parsing still sends a jq filter through the remote shell'
fi
if grep -Fq '| pg_restore --list' "$here/deploy-go.sh" || \
  grep -Fq '| tar -tf -' "$here/deploy-go.sh"; then
  fail 'encrypted backup verification still risks truncating the age stream'
fi

if grep -R -nE '(^|[^[:alnum:]_])(curl|wget)([^[:alnum:]_]|$)|SIGKILL|mktemp[^\n]*(/tmp|TMPDIR:-/tmp)' \
  "$here/deploy-go.sh" "$here/activate-go-release.sh" "$here/build-go-package.sh" \
  "$here/capture-precutover-payload.sh" "$here/prepare-production-backup.sh"; then
  fail 'Go production path retains a browser-style client, SIGKILL fallback, or /tmp artifact path'
fi
if grep -R -nE 'lmm-api-launcher|backend\.conf.*selector|/usr/lib/lmm-api/backends/go/lmm-api.*ExecStart' \
  "$repo/packaging/common/lmm-api" "$repo/packaging/local/lmm-api-go" \
  "$repo"/packaging/aur/*/PKGBUILD "$repo"/packaging/aur/*/.SRCINFO; then
  fail 'new package path retains launcher/provider architecture'
fi

fixture=$(mktemp -d "$TMPDIR/lmm-go-deploy-env-test.XXXXXXXX")
trap 'rm -rf -- "$fixture"' EXIT
printf 'SQL_DSN=postgresql://fixture.invalid/lmm\n' >"$fixture/safe.env"
LMM_DEPLOY_TEST_MODE=1 LMM_DEPLOY_OBSERVED_HOST=arch-dmit \
  "$here/prepare-production-backup.sh" --check-env-only --env-file "$fixture/safe.env" \
  | grep -Fqx 'database_engine=postgres'
side_effect=$fixture/executed
printf 'SQL_DSN=$(touch %s)\n' "$side_effect" >"$fixture/malicious.env"
if LMM_DEPLOY_TEST_MODE=1 LMM_DEPLOY_OBSERVED_HOST=arch-dmit \
  "$here/prepare-production-backup.sh" --check-env-only --env-file "$fixture/malicious.env" \
  >"$fixture/out" 2>"$fixture/err"; then
  fail 'malicious environment assignment was accepted'
fi
[[ ! -e $side_effect ]] || fail 'malicious environment assignment executed'

TMPDIR=$TMPDIR "$here/test-go-rollback-state-machine.sh"
"$here/test-backup-promotion-contract.sh"
"$repo/deploy/test-frontend-release.sh"

printf 'direct lmm-api-go production deployment contract verified\n'
