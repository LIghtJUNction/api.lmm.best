#!/usr/bin/env bash
set -Eeuo pipefail

HERE=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
readonly HERE
readonly PKGBUILD_PATH="$HERE/PKGBUILD"
readonly RELEASE_WORKFLOW="$HERE/../../../.github/workflows/release.yml"

die() { printf 'test-package: %s\n' "$*" >&2; exit 1; }

bash -n "$PKGBUILD_PATH" "$HERE/test-package.sh"
if command -v shellcheck >/dev/null 2>&1; then
  # makepkg consumes these PKGBUILD variables and provides srcdir/pkgdir.
  shellcheck -s bash -e SC2034,SC2154 "$PKGBUILD_PATH"
  # The sourced PKGBUILD uses the fixture variables assigned below.
  shellcheck -s bash -e SC1091,SC2016,SC2034 "$HERE/test-package.sh"
fi

srcinfo=$(cd -- "$HERE" && makepkg --printsrcinfo)
cmp -s <(printf '%s\n' "$srcinfo") "$HERE/.SRCINFO" || die '.SRCINFO is stale'
grep -Fqx $'pkgbase = lmm-api-bin' <<<"$srcinfo" || die 'wrong package base'
grep -Fqx $'\tarch = x86_64' <<<"$srcinfo" || die 'x86_64 is missing'
grep -Fqx $'\tarch = aarch64' <<<"$srcinfo" || die 'aarch64 is missing'
grep -Fqx $'\tmakedepends = cosign' <<<"$srcinfo" || die 'cosign verification is missing'
grep -Fq 'releases/download/' "$PKGBUILD_PATH" || die 'release source is missing'
grep -Fq 'cosign verify-blob' "$PKGBUILD_PATH" || die 'Sigstore verification is missing'
grep -Fq 'sha256sum' "$PKGBUILD_PATH" || die 'SHA-256 verification is missing'
grep -Fq 'noextract=(' "$PKGBUILD_PATH" || die 'archive must not be extracted before verification'
grep -Fq 'cp packaging/aur/lmm-api-bin/lmm-api.service "$bundle/"' \
  "$RELEASE_WORKFLOW" || die 'release archive is missing the systemd service'
grep -Fq 'cp packaging/aur/lmm-api-bin/lmm-api.env "$bundle/"' \
  "$RELEASE_WORKFLOW" || die 'release archive is missing the environment template'

if grep -Eq "(^|[[:space:]'\"])(go|bun|cargo)([[:space:]'\"]|$)" "$PKGBUILD_PATH"; then
  die 'PKGBUILD must not invoke a project compiler'
fi

tmp=$(mktemp -d "${TMPDIR:-/tmp}/lmm-api-bin-test.XXXXXXXX")
cleanup() { rm -rf -- "$tmp"; }
trap cleanup EXIT

bundle="$tmp/stage/lmm-api-go-0.1.0-linux-amd64"
mkdir -p -- "$bundle" "$tmp/bin" "$tmp/pkg" "$tmp/src"
printf '#!/bin/sh\nexit 0\n' >"$bundle/lmm-api"
chmod 0755 "$bundle/lmm-api"
install -Dm0644 "$HERE/lmm-api.service" "$bundle/lmm-api.service"
install -Dm0644 "$HERE/lmm-api.env" "$bundle/lmm-api.env"
for file in LICENSE NOTICE THIRD-PARTY-LICENSES.md; do
  printf 'fixture\n' >"$bundle/$file"
done
printf '%040d\n' 0 >"$bundle/REVISION"
tar -czf "$tmp/src/lmm-api-go-0.1.0-linux-amd64.tar.gz" \
  -C "$tmp/stage" lmm-api-go-0.1.0-linux-amd64
(
  cd -- "$tmp/src"
  sha256sum lmm-api-go-0.1.0-linux-amd64.tar.gz \
    >lmm-api-go-0.1.0-linux-amd64.tar.gz.sha256
)
printf '{}\n' >"$tmp/src/lmm-api-go-0.1.0-linux-amd64.tar.gz.sigstore.json"
# shellcheck disable=SC2016 # Keep the child process variables literal.
printf '%s\n' '#!/usr/bin/env bash' 'printf "%s\n" "$@" >"$COSIGN_ARGS"' \
  >"$tmp/bin/cosign"
chmod 0755 "$tmp/bin/cosign"

(
  CARCH=x86_64
  srcdir="$tmp/src"
  pkgdir="$tmp/pkg"
  COSIGN_ARGS="$tmp/cosign.args"
  export COSIGN_ARGS
  PATH="$tmp/bin:$PATH"
  # shellcheck source=PKGBUILD
  source "$PKGBUILD_PATH"
  cd -- "$srcdir"
  prepare
  package
)

grep -Fqx 'verify-blob' "$tmp/cosign.args" || die 'Sigstore verification was not invoked'
grep -Fqx \
  'https://github.com/LIghtJUNction/api.lmm.best/.github/workflows/release.yml@refs/tags/v0.1.0' \
  "$tmp/cosign.args" || die 'Sigstore identity is not pinned to the release tag'

for path in \
  usr/bin/lmm-api \
  usr/lib/systemd/system/lmm-api.service \
  etc/lmm-api/lmm-api.env \
  usr/share/licenses/lmm-api-bin/LICENSE \
  usr/share/doc/lmm-api-bin/REVISION; do
  [[ -f $tmp/pkg/$path ]] || die "package layout is missing $path"
done

printf '%s\n' 'lmm-api-bin package contract verified'
