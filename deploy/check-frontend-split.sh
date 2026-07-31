#!/usr/bin/env bash
set -Eeuo pipefail

repo=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
config=$repo/deploy/nginx/lmm-api-locations.conf
release=$repo/deploy/frontend-release.sh

fail() { printf 'split-check: %s\n' "$*" >&2; exit 1; }
assert_literal() { grep -Fq -- "$1" "$2" || fail "$2 is missing: $1"; }

for route in '/api/' '/v1/' '/v1beta/' '/pg/' '/mj/' '/suno/' '/kling/v1/' '/jimeng' '/dashboard/'; do
  assert_literal "$route" "$config"
done
assert_literal '^/[^/]+/mj(?:/|$)' "$config"
assert_literal 'location ^~ /oauth/' "$config"
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
if grep -Fq 'location ^~ /dashboard/' "$config"; then
  fail 'broad /dashboard/ proxy would swallow frontend dashboard routes'
fi
if grep -Fq 'location ^~ /jimeng {' "$config"; then
  fail 'broad /jimeng prefix would also proxy /jimengx'
fi

# Keep the nginx split synchronized with every top-level Gin router family.
while IFS= read -r route; do
  case $route in
    /|/api|/api/*|/v1|/v1/*|/v1beta|/v1beta/*|/pg|/pg/*|/mj|/mj/*|/suno|/suno/*|/kling/v1|/kling/v1/*|jimeng|/jimeng|/jimeng/*|/dashboard|/dashboard/*|/:mode/mj) ;;
    *) fail "unclassified backend router family: $route" ;;
  esac
done < <(sed -nE 's/.*router\.Group\("?([^" ]+)"?\).*/\1/p' "$repo"/router/*.go | sort -u)

bash -n "$release"
printf 'frontend/backend split checks passed\n'
