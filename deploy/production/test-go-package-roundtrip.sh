#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

repo=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd -P)
here=$repo/deploy/production
: "${TMPDIR:?set TMPDIR to a private persistent test workspace}"
[[ -d $TMPDIR && -w $TMPDIR && ! -L $TMPDIR ]] || {
  printf 'go-package-roundtrip: TMPDIR is not a safe writable directory\n' >&2
  exit 1
}

for command in cc fakeroot makepkg pacman tar; do
  command -v "$command" >/dev/null 2>&1 || {
    printf 'go-package-roundtrip: required command is unavailable: %s\n' "$command" >&2
    exit 1
  }
done

tmp=$(mktemp -d "$TMPDIR/lmm-go-package-roundtrip.XXXXXXXX")
trap 'rm -rf -- "$tmp"' EXIT
workspace=$tmp/workspace
payload_root=$tmp/payload-root
rollback_dir=$tmp/rollback
candidate_dir=$tmp/candidate
frontend=$tmp/frontend
pacman_root=$tmp/pacman-root
install -d -m0700 "$workspace/tmp" "$payload_root/metadata" \
  "$payload_root/core-root/etc/lmm-api" \
  "$rollback_dir" "$candidate_dir" "$frontend"
install -d -m0755 "$payload_root/core-root/usr/bin" \
  "$payload_root/core-root/usr/lib/systemd/system" \
  "$payload_root/core-root/usr/share/licenses/lmm-api" \
  "$payload_root/go-root/usr/lib/lmm-api/backends/go"
printf 'format=1\nrole=test\n' >"$workspace/.lmm-deploy-workspace"

old_core_version=0.1.0.r31.gfixture-1
old_go_version=0.1.0.r122.gfixture-1
candidate_version=0.1.0.r999.gfixture
printf 'lmm-api\t%s\n' "$old_core_version" >"$payload_root/metadata/packages.tsv"
printf 'lmm-api-go\t%s\n' "$old_go_version" >>"$payload_root/metadata/packages.tsv"
printf '#!/usr/bin/env bash\nexit 0\n' >"$payload_root/core-root/usr/bin/lmm-api"
cp -- "$payload_root/core-root/usr/bin/lmm-api" "$payload_root/core-root/usr/bin/lmm-api-select"
cp -- "$payload_root/core-root/usr/bin/lmm-api" "$payload_root/go-root/usr/lib/lmm-api/backends/go/lmm-api"
chmod 0755 "$payload_root/core-root/usr/bin/lmm-api" \
  "$payload_root/core-root/usr/bin/lmm-api-select" \
  "$payload_root/go-root/usr/lib/lmm-api/backends/go/lmm-api"
printf '[Service]\nExecStart=/usr/bin/lmm-api\n' >"$payload_root/core-root/usr/lib/systemd/system/lmm-api.service"
printf 'LMM_API_BACKEND=go\n' >"$payload_root/core-root/etc/lmm-api/backend.conf"
: >"$payload_root/core-root/etc/lmm-api/lmm-api.env"
chmod 0644 "$payload_root/core-root/usr/lib/systemd/system/lmm-api.service" \
  "$payload_root/core-root/etc/lmm-api/backend.conf"
chmod 0600 "$payload_root/core-root/etc/lmm-api/lmm-api.env"
printf 'fixture\n' >"$payload_root/core-root/usr/share/licenses/lmm-api/LICENSE"
chmod 0644 "$payload_root/core-root/usr/share/licenses/lmm-api/LICENSE"
tar --sort=name --numeric-owner --owner=0 --group=0 -C "$payload_root" -cf "$tmp/precutover-payload.tar" .

TMPDIR=$workspace/tmp "$here/build-precutover-packages.sh" \
  --workspace "$workspace" --payload "$tmp/precutover-payload.tar" --output-dir "$rollback_dir" >/dev/null

cat >"$tmp/candidate.c" <<EOF
#include <stdio.h>
int main(void) { puts("$candidate_version"); return 0; }
EOF
cc -O2 -s -o "$tmp/lmm-api-go" "$tmp/candidate.c"
printf '<!doctype html><title>LMM fixture</title>\n' >"$frontend/index.html"
"$repo/packaging/local/lmm-api-go/build-local-package.sh" \
  --workspace "$workspace" --binary "$tmp/lmm-api-go" \
  --frontend "$frontend" --output-dir "$candidate_dir" >/dev/null

old_core=$(find "$rollback_dir" -maxdepth 1 -type f -name 'lmm-api-*.pkg.tar.*' ! -name 'lmm-api-go-*' ! -name '*.sha256' -print -quit)
old_go=$(find "$rollback_dir" -maxdepth 1 -type f -name 'lmm-api-go-*.pkg.tar.*' ! -name '*.sha256' -print -quit)
new_go=$(find "$candidate_dir" -maxdepth 1 -type f -name 'lmm-api-go-*.pkg.tar.*' ! -name '*.sha256' -print -quit)
[[ -n $old_core && -n $old_go && -n $new_go ]] || {
  printf 'go-package-roundtrip: package fixture is incomplete\n' >&2
  exit 1
}

install -d -m0755 "$pacman_root/etc" "$pacman_root/usr" \
  "$pacman_root/var/lib/pacman/local" "$pacman_root/var/cache/pacman/pkg" "$pacman_root/var/log"
common=(--root "$pacman_root" --dbpath "$pacman_root/var/lib/pacman" \
  --cachedir "$pacman_root/var/cache/pacman/pkg" --logfile "$pacman_root/var/log/pacman.log")
# This fixture validates file ownership and conflict transitions, not dependency
# resolution. Keeping the database empty avoids copying the host's entire local
# pacman database into every test run.
install_args=(pacman "${common[@]}" --noconfirm --noscriptlet --nodeps --nodeps)
query_args=(pacman "${common[@]}")

fakeroot -- "${install_args[@]}" -U "$old_core" "$old_go" >/dev/null
[[ $("${query_args[@]}" -Q lmm-api 2>/dev/null) == "lmm-api $old_core_version" ]]
[[ $("${query_args[@]}" -Q lmm-api-go 2>/dev/null) == "lmm-api-go $old_go_version" ]]

fakeroot -- "${install_args[@]}" -Rdd lmm-api >/dev/null
fakeroot -- "${install_args[@]}" -U "$new_go" >/dev/null
if "${query_args[@]}" -Q lmm-api >/dev/null 2>&1; then
  printf 'go-package-roundtrip: old core package remains installed\n' >&2
  exit 1
fi
[[ $("${query_args[@]}" -Q lmm-api-go 2>/dev/null) == "lmm-api-go $candidate_version-1" ]]
[[ -x $pacman_root/usr/bin/lmm-api-go && ! -e $pacman_root/usr/bin/lmm-api ]]

fakeroot -- "${install_args[@]}" -U "$old_core" "$old_go" >/dev/null
[[ $("${query_args[@]}" -Q lmm-api 2>/dev/null) == "lmm-api $old_core_version" ]]
[[ $("${query_args[@]}" -Q lmm-api-go 2>/dev/null) == "lmm-api-go $old_go_version" ]]
[[ -x $pacman_root/usr/bin/lmm-api && -x $pacman_root/usr/bin/lmm-api-select ]]
[[ -x $pacman_root/usr/lib/lmm-api/backends/go/lmm-api && ! -e $pacman_root/usr/bin/lmm-api-go ]]

printf 'direct lmm-api-go package transaction roundtrip verified\n'
