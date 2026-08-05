#!/usr/bin/env bash
set -Eeuo pipefail

repo=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd -P)
deploy=$repo/deploy/production/deploy-go.sh
activate=$repo/deploy/production/activate-go-release.sh

fail() { printf 'go-deploy-contract: %s\n' "$*" >&2; exit 1; }
contains() { grep -Fq -- "$1" "$2" || fail "$2 is missing: $1"; }

bash -n "$deploy"
bash -n "$activate"

# These strings intentionally match the shell source literally.
# shellcheck disable=SC2016
for literal in \
  'frontend-dist.tar' \
  'frontend-release.sh' \
  '--frontend-archive' \
  '--frontend-sha256' \
  '--frontend-release-script'; do
  contains "$literal" "$deploy"
done

# These strings intentionally match the shell source literally.
# shellcheck disable=SC2016
for literal in \
  'old_frontend_release' \
  'frontend archive checksum mismatch' \
  'frontend-publish-failed' \
  'frontend-health-probe-failed' \
  'probe_frontend "$EXPECTED_VERSION" "$frontend_sha256"' \
  'probe_frontend "$old_frontend_release" "$old_frontend_sha256"' \
  'write_status "DEPLOYED $EXPECTED_VERSION $snapshot frontend=$EXPECTED_VERSION"'; do
  contains "$literal" "$activate"
done

# shellcheck disable=SC2016
publish_line=$(grep -nF '"$FRONTEND_RELEASE_SCRIPT" publish' "$activate" | cut -d: -f1)
# shellcheck disable=SC2016
probe_line=$(grep -nF 'probe_frontend "$EXPECTED_VERSION" "$frontend_sha256"' "$activate" | cut -d: -f1)
# shellcheck disable=SC2016
deployed_line=$(grep -nF 'write_status "DEPLOYED $EXPECTED_VERSION $snapshot frontend=$EXPECTED_VERSION"' "$activate" | cut -d: -f1)
[[ $publish_line =~ ^[0-9]+$ && $probe_line =~ ^[0-9]+$ && $deployed_line =~ ^[0-9]+$ ]] ||
  fail 'could not locate ordered frontend deployment operations'
(( publish_line < probe_line && probe_line < deployed_line )) ||
  fail 'deployment may report success before frontend publication and probing'

printf 'Go production deployment contract verified\n'
