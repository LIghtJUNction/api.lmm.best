#!/usr/bin/env bash
# Static package-contract test, with an optional real package archive check.
set -Eeuo pipefail

HERE=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
readonly HERE
readonly PKGBUILD="$HERE/PKGBUILD"
readonly INSTALL_TEMPLATE="$HERE/lmm-api-rs-fallback-bin.install"
readonly BUILD_SCRIPT="$HERE/build-local-package.sh"
readonly DEPLOY_SCRIPT="$HERE/../../../deploy/backend-rust/deploy-lmm-api-rs-single-instance.sh"
readonly BOOTSTRAP_SCRIPT="$HERE/../../../deploy/backend-rust/install-lmm-api-rs-single-instance.sh"
readonly GUARD_SOURCE_PATH='deploy/backend-rust/fallback-target-guard.sh'
readonly GUARD_PACKAGE_PATH='usr/lib/lmm-api-rs/deploy/fallback-target-guard.sh'

die() {
  printf 'test-package-layout: %s\n' "$*" >&2
  exit 1
}

contains() {
  local needle=$1 file=$2
  grep -Fq -- "$needle" "$file" || die "missing package contract text: $needle"
}

guard_executes_before_changes() {
  local script=$1 guard_line mutation_line
  local -a guard_lines=()

  # shellcheck disable=SC2016 # Match the literal runtime guard invocation.
  mapfile -t guard_lines < <(grep -nE '^[[:space:]]*"\$GUARD"[[:space:]]*$' "$script" || true)
  ((${#guard_lines[@]} == 1)) || return 1
  guard_line=${guard_lines[0]%%:*}
  mutation_line=$(awk '
    /^[[:space:]]*(install|mkdir|rm|mv|cp|ln|touch|chmod|chown|pacman|systemctl)([[:space:]]|$)/ {
      print NR
      exit
    }
  ' "$script")
  [[ -z $mutation_line || $guard_line -lt $mutation_line ]]
}

fallback_guard_is_manifested() {
  local script=$1
  awk -v guard="$GUARD_SOURCE_PATH" '
    /^readonly FALLBACK_ASSETS=\(/ { in_assets=1; next }
    in_assets && /^\)/ { exit }
    in_assets && $0 == "  " guard { found=1 }
    END { exit(found ? 0 : 1) }
  ' "$script" || return 1
  # shellcheck disable=SC2016 # Match literal build-script source, not expanded values.
  grep -Fq 'for path in "${FALLBACK_ASSETS[@]}" "${MIGRATION_ASSETS[@]}"; do' "$script" || return 1
  # shellcheck disable=SC2016 # Match literal build-script source, not expanded values.
  grep -Fq 'manifest_args+=(--path "$path")' "$script"
}

for file in "$PKGBUILD" "$INSTALL_TEMPLATE" "$BUILD_SCRIPT" "$DEPLOY_SCRIPT" "$BOOTSTRAP_SCRIPT"; do
  [[ -f $file && ! -L $file ]] || die "missing test input: $file"
done

tmp=$(mktemp -d "${TMPDIR:-/tmp}/lmm-api-rs-package-layout.XXXXXXXX")
package_body="$tmp/package-body"
trap 'rm -rf -- "$tmp"' EXIT
sed -n '/^package()/,$p' "$PKGBUILD" >"$package_body"

# Required payload and metadata are all explicit package() destinations.
for required in \
  '/usr/lib/lmm-api-rs/bin/lmm-api-rs' \
  '/usr/lib/lmm-api-rs/bin/lmm-db-migrate' \
  '/usr/share/lmm-api-rs/revision' \
  '/usr/share/lmm-api-rs/payload.sha256' \
  '/usr/share/lmm-api-rs/source-manifest.tsv' \
  '/usr/share/lmm-api-rs/source-manifest.sha256' \
  'lmm-api-rs-fallback-bin.install' \
  'create-sanitized-test-schema.sh' \
  'import-sanitized-auth-snapshot.sh' \
  'sanitized-auth-snapshot-v1.tsv.schema' \
  'README-sanitized-test-schema.md'; do
  contains "$required" "$PKGBUILD"
done

contains 'post_install()' "$INSTALL_TEMPLATE"
contains 'post_upgrade()' "$INSTALL_TEMPLATE"
contains 'fallback-target-guard.sh' "$INSTALL_TEMPLATE"
if grep -Eiq 'machine-id|machine_binding_check|pre_install\(\)|pre_upgrade\(\)' "$INSTALL_TEMPLATE"; then
  die 'install scriptlet must not bind a package installation to the build machine'
fi

# The package must carry the runtime authorization guard beside both entry
# points.  The unit and sysuser use one dedicated, non-root identity.
for required in \
  'fallback-target-guard.sh' \
  'deploy-lmm-api-rs-single-instance.sh' \
  'install-lmm-api-rs-single-instance.sh' \
  'lmm-api-rs-single.service' \
  'lmm-api-rs-fallback.conf' \
  'u lmm-api-rs-fallback - "LMM API Rust fallback test instance" /var/lib/lmm-api-rs-single /usr/bin/nologin'; do
  contains "$required" "$PKGBUILD"
done
for script in "$DEPLOY_SCRIPT" "$BOOTSTRAP_SCRIPT"; do
  contains "readonly GUARD=\"\$SCRIPT_DIR/fallback-target-guard.sh\"" "$script"
  guard_executes_before_changes "$script" || die "guard is not executed before changes: $script"
  negative="$tmp/${script##*/}.without-guard"
  # shellcheck disable=SC2016 # Delete only the literal runtime guard invocation.
  sed '/^[[:space:]]*"\$GUARD"[[:space:]]*$/d' "$script" >"$negative"
  if guard_executes_before_changes "$negative"; then
    die "guard execution negative test unexpectedly passed: $script"
  fi
done
fallback_guard_is_manifested "$BUILD_SCRIPT" || die 'guard is not a FALLBACK_ASSET passed to source-manifest generation'
negative="$tmp/build-local-package.without-guard-asset"
sed '/^[[:space:]]*deploy\/backend-rust\/fallback-target-guard\.sh[[:space:]]*$/d' "$BUILD_SCRIPT" >"$negative"
if fallback_guard_is_manifested "$negative"; then
  die 'source-manifest guard asset negative test unexpectedly passed'
fi
negative="$tmp/build-local-package.without-fallback-manifest-loop"
# shellcheck disable=SC2016 # Delete only the literal manifest path loop body.
sed '/^[[:space:]]*manifest_args+=(--path "\$path")[[:space:]]*$/d' "$BUILD_SCRIPT" >"$negative"
if fallback_guard_is_manifested "$negative"; then
  die 'source-manifest guard loop negative test unexpectedly passed'
fi
contains 'User=lmm-api-rs-fallback' "$HERE/../../../deploy/backend-rust/lmm-api-rs-single.service"
contains 'Group=lmm-api-rs-fallback' "$HERE/../../../deploy/backend-rust/lmm-api-rs-single.service"

# These are forbidden package-path families, not just forbidden commands.
for forbidden in \
  'bootstrap' \
  'blue.env' \
  'green.env' \
  'lmm-api-rs@.service' \
  'blue-green' \
  'deploy-lmm-api-rs.sh' \
  'install-lmm-api-rs-blue-green.sh' \
  'install-nginx-rust-routing.sh' \
  'new-api.conf' \
  'http-map.conf' \
  'mime.types' \
  'lmm-api-rs-probe-locations.conf' \
  'lmm-api-rs-upstream.conf' \
  'cutover'; do
  if grep -Fq -- "$forbidden" "$package_body"; then
    die "forbidden package asset is referenced: $forbidden"
  fi
done
if grep -Eq '(^|[^[:alnum:]_.-])api\.lmm\.best([^[:alnum:]_.-]|$)' "$package_body"; then
  die 'production api.lmm.best is referenced by package()'
fi
if grep -Eiq 'generic[[:space:]_-]*nginx' "$package_body"; then
  die 'generic nginx is referenced by package()'
fi
if grep -Eiq 'systemctl[[:space:]]+(start|enable|restart|reload|daemon-reload)' "$INSTALL_TEMPLATE"; then
  die 'install scriptlet attempts service activation'
fi
if grep -Eiq 'hostname|HOSTNAME' "$INSTALL_TEMPLATE"; then
  die 'install scriptlet authorizes by hostname'
fi

archive=${1:-}
if [[ -n $archive ]]; then
  [[ -f $archive && ! -L $archive ]] || die "archive is missing or unsafe: $archive"
  if command -v bsdtar >/dev/null 2>&1; then
    TAR=(bsdtar -tf)
    TAR_EXTRACT=(bsdtar -xOf)
  else
    TAR=(tar -tf)
    TAR_EXTRACT=(tar -xOf)
  fi
  mapfile -t entries < <("${TAR[@]}" "$archive")
  has_entry() { printf '%s\n' "${entries[@]}" | grep -Fxq -- "$1"; }
  for required in \
    usr/lib/lmm-api-rs/bin/lmm-api-rs \
    usr/lib/lmm-api-rs/bin/lmm-db-migrate \
    usr/share/lmm-api-rs/revision \
    usr/share/lmm-api-rs/payload.sha256 \
    usr/share/lmm-api-rs/source-manifest.tsv \
    usr/share/lmm-api-rs/source-manifest.sha256 \
    usr/lib/systemd/system/lmm-api-rs-single.service \
    usr/lib/sysusers.d/lmm-api-rs-fallback.conf \
    "$GUARD_PACKAGE_PATH" \
    usr/lib/lmm-api-rs/deploy/deploy-lmm-api-rs-single-instance.sh \
    usr/lib/lmm-api-rs/deploy/install-lmm-api-rs-single-instance.sh \
    usr/lib/lmm-api-rs/deploy/create-sanitized-test-schema.sh \
    usr/lib/lmm-api-rs/deploy/import-sanitized-auth-snapshot.sh \
    usr/lib/lmm-api-rs/deploy/sanitized-auth-snapshot-v1.tsv.schema \
    usr/lib/lmm-api-rs/deploy/README-sanitized-test-schema.md; do
    has_entry "$required" || die "archive is missing: $required"
  done
  while IFS= read -r entry; do
    case $entry in
      */blue.env|*/green.env|*lmm-api-rs@.service|*blue-green*|*cutover*|*/bootstrap/*|*new-api.conf|*http-map.conf|*mime.types|*lmm-api-rs-probe-locations.conf|*lmm-api-rs-upstream.conf|*api.lmm.best/*)
        die "archive contains forbidden path: $entry"
        ;;
    esac
  done < <(printf '%s\n' "${entries[@]}")

  has_entry '.INSTALL' || die 'archive is missing pacman install hook'
  if "${TAR_EXTRACT[@]}" "$archive" .INSTALL | grep -Eiq 'machine-id|machine_binding_check|pre_install\(\)|pre_upgrade\(\)'; then
    die 'archive install hook must not bind package installation to the build machine'
  fi

  while read -r expected path; do
    [[ $expected =~ ^[0-9a-f]{64}$ && $path == usr/lib/lmm-api-rs/bin/* ]] || \
      die 'payload.sha256 has an unsafe row'
    actual=$("${TAR_EXTRACT[@]}" "$archive" "$path" | sha256sum | awk '{print $1}')
    [[ $actual == "$expected" ]] || die "payload hash mismatch: $path"
  done < <("${TAR_EXTRACT[@]}" "$archive" usr/share/lmm-api-rs/payload.sha256)

  guard_expected=$("${TAR_EXTRACT[@]}" "$archive" usr/share/lmm-api-rs/source-manifest.tsv | \
    awk -F $'\t' -v path="$GUARD_SOURCE_PATH" '
      $1 == path && $2 ~ /^[0-9]{4}$/ && $3 ~ /^[0-9a-f]{64}$/ { count++; hash=$3 }
      END { if (count == 1) print hash; else exit 1 }
    ') || die 'source manifest lacks one valid fallback guard hash'
  guard_actual=$("${TAR_EXTRACT[@]}" "$archive" "$GUARD_PACKAGE_PATH" | sha256sum | awk '{print $1}')
  [[ $guard_actual == "$guard_expected" ]] || die 'fallback guard hash differs from source manifest'
fi

printf '%s\n' 'package layout contract verified'
