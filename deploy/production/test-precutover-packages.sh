#!/usr/bin/env bash
set -Eeuo pipefail

here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
: "${TMPDIR:?set TMPDIR to a marker-owned workspace}"
tmp=$(mktemp -d "$TMPDIR/lmm-precutover-package-test.XXXXXXXX")
trap 'rm -rf -- "$tmp"' EXIT

fail() { printf 'precutover-package-test: %s\n' "$*" >&2; exit 1; }
root=$tmp/payload
mkdir -p \
  "$root/metadata" \
  "$root/core-root/usr/bin" \
  "$root/core-root/usr/lib/systemd/system" \
  "$root/core-root/etc/lmm-api" \
  "$root/core-root/usr/share/licenses/lmm-api" \
  "$root/go-root/usr/lib/lmm-api/backends/go"
printf 'lmm-api\t0.1.0.r31.g3e39995.payrate2.cachefix1.txfix1-1\n' >"$root/metadata/packages.tsv"
printf 'lmm-api-go\t0.1.0.r122.g27d4df76-1\n' >>"$root/metadata/packages.tsv"
for command_path in "$root/core-root/usr/bin/lmm-api" "$root/core-root/usr/bin/lmm-api-select" \
  "$root/go-root/usr/lib/lmm-api/backends/go/lmm-api"; do
  printf '#!/bin/sh\nexit 0\n' >"$command_path"
  chmod 0755 "$command_path"
done
printf '[Service]\nExecStart=/usr/bin/lmm-api\n' >"$root/core-root/usr/lib/systemd/system/lmm-api.service"
printf 'LMM_API_BACKEND=go\n' >"$root/core-root/etc/lmm-api/backend.conf"
: >"$root/core-root/etc/lmm-api/lmm-api.env"
printf 'fixture\n' >"$root/core-root/usr/share/licenses/lmm-api/LICENSE"
tar -C "$root" -cf "$tmp/payload.tar" .

mkdir -p "$tmp/workspace/tmp" "$tmp/output"
printf 'test\n' >"$tmp/workspace/.lmm-deploy-workspace"
"$here/build-precutover-packages.sh" \
  --workspace "$tmp/workspace" \
  --payload "$tmp/payload.tar" \
  --output-dir "$tmp/output" >"$tmp/result"

core=("$tmp/output/lmm-api-0.1.0.r31.g3e39995.payrate2.cachefix1.txfix1-1-x86_64.pkg.tar.zst")
go=("$tmp/output/lmm-api-go-0.1.0.r122.g27d4df76-1-x86_64.pkg.tar.zst")
[[ ${#core[@]} -eq 1 && -f ${core[0]} ]] || fail 'core package identity is wrong'
[[ ${#go[@]} -eq 1 && -f ${go[0]} ]] || fail 'Go package identity is wrong'
[[ $(pacman -Qp "${core[0]}") == 'lmm-api 0.1.0.r31.g3e39995.payrate2.cachefix1.txfix1-1' ]] || \
  fail 'core package record is wrong'
[[ $(pacman -Qp "${go[0]}") == 'lmm-api-go 0.1.0.r122.g27d4df76-1' ]] || fail 'Go package record is wrong'
for expected in usr/bin/lmm-api usr/bin/lmm-api-select usr/lib/systemd/system/lmm-api.service; do
  bsdtar -tf "${core[0]}" | grep -Fqx "$expected" || fail "core package lacks $expected"
done
bsdtar -tf "${go[0]}" | grep -Fqx 'usr/lib/lmm-api/backends/go/lmm-api' || fail 'Go package lacks captured binary'
if bsdtar -xOf "${core[0]}" etc/lmm-api/lmm-api.env | grep -q .; then
  fail 'core rollback package embedded an environment value'
fi
printf 'pre-cutover rollback packages verified\n'
