#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
: "${TMPDIR:?set TMPDIR to a marker-owned workspace}"
tmp=$(mktemp -d "$TMPDIR/lmm-precutover-capture-test.XXXXXXXX")
trap 'rm -rf -- "$tmp"' EXIT

fail() { printf 'precutover-capture-test: %s\n' "$*" >&2; exit 1; }

bin=$tmp/bin
fs=$tmp/fs
workspace=$tmp/work/direct-fixture
mkdir -p "$bin" "$workspace/staging" \
  "$fs/etc/lmm-api-go" \
  "$fs/usr/bin" \
  "$fs/usr/lib/systemd/system" \
  "$fs/usr/share/doc/lmm-api-go" \
  "$fs/usr/share/licenses/lmm-api-go" \
  "$fs/usr/share/lmm-api-go/edge-policy/nginx" \
  "$fs/usr/share/lmm-api-go/frontend-dist"
printf 'format=1\ndeployment_id=direct-fixture\n' >"$workspace/.lmm-deploy-workspace"

cat >"$bin/hostnamectl" <<'EOF'
#!/usr/bin/env bash
printf 'arch-dmit\n'
EOF
cat >"$bin/systemctl" <<'EOF'
#!/usr/bin/env bash
case $1 in
  is-active|is-enabled) printf '%s\n' "${LMM_TEST_SERVICE_STATE:-active}" ;;
  *) exit 90 ;;
esac
EOF
cat >"$bin/pacman" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
case $1 in
  -Qq)
    [[ $2 == lmm-api-go ]] || exit 1
    printf 'lmm-api-go\n'
    ;;
  -Q)
    [[ $2 == lmm-api-go ]] || exit 1
    printf 'lmm-api-go 0.1.0.r267.g50dc6a7f9-1\n'
    ;;
  -Qlq)
    [[ $2 == lmm-api-go ]] || exit 1
    printf '%s\n' \
      /etc/ \
      /etc/lmm-api-go/ \
      /etc/lmm-api-go/lmm-api-go.env \
      /usr/ \
      /usr/bin/ \
      /usr/bin/lmm-api-go \
      /usr/lib/ \
      /usr/lib/systemd/ \
      /usr/lib/systemd/system/ \
      /usr/lib/systemd/system/geoip2-country-update.service \
      /usr/lib/systemd/system/geoip2-country-update.timer \
      /usr/lib/systemd/system/lmm-api-go.service \
      /usr/share/ \
      /usr/share/doc/ \
      /usr/share/doc/lmm-api-go/ \
      /usr/share/doc/lmm-api-go/REVISION \
      /usr/share/licenses/ \
      /usr/share/licenses/lmm-api-go/ \
      /usr/share/licenses/lmm-api-go/LICENSE \
      /usr/share/licenses/lmm-api-go/NOTICE \
      /usr/share/licenses/lmm-api-go/THIRD-PARTY-LICENSES.md \
      /usr/share/lmm-api-go/ \
      /usr/share/lmm-api-go/edge-policy/ \
      /usr/share/lmm-api-go/edge-policy/nginx/ \
      /usr/share/lmm-api-go/edge-policy/nginx/http-map.conf \
      /usr/share/lmm-api-go/edge-policy/nginx/lmm-api-locations.conf \
      /usr/share/lmm-api-go/edge-policy/nginx/lmm-api-region-policy.conf \
      /usr/share/lmm-api-go/edge-policy/nginx/mime.types \
      /usr/share/lmm-api-go/edge-policy/nginx/new-api.conf \
      /usr/share/lmm-api-go/frontend-dist/ \
      /usr/share/lmm-api-go/frontend-dist/index.html
    ;;
  *) exit 91 ;;
esac
EOF
chmod 0755 "$bin"/*

printf 'SQL_DSN=postgres://secret.invalid/fixture\n' >"$fs/etc/lmm-api-go/lmm-api-go.env"
printf '#!/bin/sh\nexit 0\n' >"$fs/usr/bin/lmm-api-go"
printf '[Service]\nExecStart=/usr/bin/lmm-api-go serve\n' >"$fs/usr/lib/systemd/system/lmm-api-go.service"
printf '[Service]\nExecStart=/usr/bin/geoip2-country-update\n' >"$fs/usr/lib/systemd/system/geoip2-country-update.service"
printf '[Timer]\nOnCalendar=daily\n' >"$fs/usr/lib/systemd/system/geoip2-country-update.timer"
printf '50dc6a7f9\n' >"$fs/usr/share/doc/lmm-api-go/REVISION"
for license_file in LICENSE NOTICE THIRD-PARTY-LICENSES.md; do
  printf 'fixture\n' >"$fs/usr/share/licenses/lmm-api-go/$license_file"
done
for edge_file in http-map.conf lmm-api-locations.conf lmm-api-region-policy.conf mime.types new-api.conf; do
  printf 'fixture edge policy\n' >"$fs/usr/share/lmm-api-go/edge-policy/nginx/$edge_file"
done
printf 'old frontend\n' >"$fs/usr/share/lmm-api-go/frontend-dist/index.html"
chmod 0600 "$fs/etc/lmm-api-go/lmm-api-go.env"
chmod 0755 "$fs/usr/bin/lmm-api-go"

PATH="$bin:$PATH" \
  LMM_DEPLOY_TEST_MODE=1 \
  LMM_DEPLOY_OBSERVED_HOST=arch-dmit \
  LMM_DEPLOY_TEST_WORK_ROOT="$tmp/work" \
  LMM_DEPLOY_TEST_FILESYSTEM_ROOT="$fs" \
  "$here/capture-precutover-payload.sh" \
    --workspace "$workspace" --output "$workspace/staging/precutover-payload.tar" \
    >"$tmp/capture.out"

payload=$workspace/staging/precutover-payload.tar
[[ -f $payload && ! -L $payload ]] || fail 'direct payload was not captured'
[[ $(bsdtar -xOf "$payload" ./metadata/layout) == direct ]] || fail 'direct layout metadata is wrong'
[[ $(bsdtar -xOf "$payload" ./metadata/packages.tsv) == $'lmm-api-go\t0.1.0.r267.g50dc6a7f9-1' ]] || \
  fail 'direct package metadata is wrong'
[[ -z $(bsdtar -xOf "$payload" ./go-root/etc/lmm-api-go/lmm-api-go.env) ]] || \
  fail 'direct payload embedded production configuration'
bsdtar -tf "$payload" | grep -Fqx './go-root/usr/bin/lmm-api-go' || fail 'direct payload lacks the Go binary'
bsdtar -tf "$payload" | grep -Fqx './go-root/usr/share/lmm-api-go/frontend-dist/index.html' || \
  fail 'direct payload lacks the packaged frontend'
printf 'pre-cutover direct capture verified\n'
