#!/usr/bin/env bash
set -Eeuo pipefail

repo=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
config=$repo/deploy/nginx/lmm-api-locations.conf
mime_types=$repo/deploy/nginx/mime.types
release=$repo/deploy/frontend-release.sh
nginx_installer=$repo/deploy/nginx/install-nginx-split.sh
route_manifest=$repo/apps/api-rust/routes/legacy-go-routes.tsv

fail() { printf 'split-check: %s\n' "$*" >&2; exit 1; }
assert_literal() { grep -Fq -- "$1" "$2" || fail "$2 is missing: $1"; }

for route in '/api/' '/v1/' '/v1beta/' '/pg/' '/mj/' '/suno/' '/kling/v1/' '/jimeng' '/dashboard/'; do
  assert_literal "$route" "$config"
done
assert_literal '^/[^/]+/mj(?:/|$)' "$config"
assert_literal 'location ^~ /oauth/' "$config"
assert_literal 'include /etc/nginx/lmm-api-mime.types;' "$config"
assert_literal 'default_type application/octet-stream;' "$config"
if grep -Fq 'include /etc/nginx/mime.types;' "$config"; then
  fail 'site config must not depend on or manage the global nginx MIME map'
fi
assert_literal 'application/javascript               js mjs;' "$mime_types"
assert_literal 'text/css                              css;' "$mime_types"
assert_literal 'application/json                     json map;' "$mime_types"
assert_literal 'image/svg+xml                         svg svgz;' "$mime_types"
assert_literal 'font/woff2                            woff2;' "$mime_types"
assert_literal 'location = /terms' "$config"
assert_literal 'location = /privacy' "$config"
assert_literal 'alias /var/www/api.lmm.best/legal/terms.html;' "$config"
assert_literal 'alias /var/www/api.lmm.best/legal/privacy.html;' "$config"
assert_literal 'default_type text/html;' "$config"
assert_literal 'charset utf-8;' "$config"
assert_literal 'add_header X-Content-Type-Options nosniff always;' "$config"
[[ $(grep -Fc 'default_type text/html;' "$config") == 2 ]] ||
  fail 'each exact legal alias must set the HTML content type'
[[ $(grep -Fc 'charset utf-8;' "$config") == 2 ]] ||
  fail 'each exact legal alias must set UTF-8'
[[ $(grep -Fc 'add_header X-Content-Type-Options nosniff always;' "$config") == 2 ]] ||
  fail 'each exact legal alias must set nosniff'
if grep -Eq 'return 30[1278] /(user-agreement|privacy-policy)' "$config"; then
  fail 'legal aliases must not redirect into the SPA'
fi
assert_literal 'alias /srv/lmm-api-frontend/assets/' "$config"
assert_literal 'location = /dashboard/billing/subscription' "$config"
assert_literal 'location = /dashboard/billing/usage' "$config"
assert_literal 'location = /jimeng ' "$config"
assert_literal 'location ^~ /jimeng/' "$config"
assert_literal 'jpe?g|js|json|map|png|svg|webp|woff2?' "$config"
assert_literal 'max-age=31536000, immutable' "$config"
assert_literal 'no-cache, must-revalidate' "$config"
assert_literal 'proxy_buffering off' "$config"
assert_literal 'Connection $connection_upgrade' "$config"
assert_literal 'mv -Tf -- "$temp" "$root/current"' "$release"
assert_literal 'flock -n 9' "$release"
assert_literal 'immutable asset collision with different content' "$release"
assert_literal 'preflight_assets "$stage/static"' "$release"
assert_literal 'flock -n 9' "$nginx_installer"
assert_literal 'mv -Tf -- "$temp" "$target"' "$nginx_installer"
assert_literal 'nginx -t' "$nginx_installer"
assert_literal 'systemctl reload nginx' "$nginx_installer"
assert_literal 'restore_backup "$backup"' "$nginx_installer"
assert_literal 'MIME_TARGET=$ROOT_PREFIX/etc/nginx/lmm-api-mime.types' "$nginx_installer"
if grep -Fq 'location ^~ /dashboard/' "$config"; then
  fail 'broad /dashboard/ proxy would swallow frontend dashboard routes'
fi
if grep -Fq 'location ^~ /jimeng {' "$config"; then
  fail 'broad /jimeng prefix would also proxy /jimengx'
fi

# Keep the nginx split synchronized with every route in the immutable legacy
# backend surface. This remains available after the Go source is archived.
while IFS=$'\t' read -r method route handler; do
  [[ -n $method && -n $route && -n $handler ]] ||
    fail "malformed frozen backend route: $method $route $handler"
  case $route in
    /|/api|/api/*|/v1|/v1/*|/v1beta|/v1beta/*|/pg|/pg/*|/mj|/mj/*|/suno|/suno/*|/kling/v1|/kling/v1/*|jimeng|/jimeng|/jimeng/*|/dashboard|/dashboard/*|/:mode/mj|/:mode/mj/*) ;;
    *) fail "unclassified backend router family: $route" ;;
  esac
done < "$route_manifest"

bash -n "$release"
bash -n "$nginx_installer"
if command -v nginx >/dev/null; then
  LMM_NGINX_MIME_TYPES="$mime_types" "$repo/deploy/test-nginx-mime.sh"
else
  printf 'split-check: nginx not installed; MIME integration test skipped\n' >&2
fi
"$repo/deploy/test-nginx-installer.sh"

# The behavioral test must consume the tracked map, not an unrelated system
# file. Corrupting a copy of that map must make nginx validation fail.
mime_test_root=$(mktemp -d)
trap 'rm -rf -- "$mime_test_root"' EXIT
cp -- "$mime_types" "$mime_test_root/mime.types"
printf 'this is not nginx syntax\n' >>"$mime_test_root/mime.types"
if command -v nginx >/dev/null &&
   LMM_NGINX_MIME_TYPES="$mime_test_root/mime.types" "$repo/deploy/test-nginx-mime.sh" >/dev/null 2>&1; then
  fail 'corrupted tracked MIME map unexpectedly passed nginx validation'
fi
printf 'frontend/backend split checks passed\n'
