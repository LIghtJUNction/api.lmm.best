#!/usr/bin/env bash
# Build an x86_64 Arch package from locally compiled Rust executables.
# No network deployment, remote build, or server access is performed.
set -Eeuo pipefail
umask 022

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
readonly SCRIPT_DIR
REPO_ROOT=$(cd -- "$SCRIPT_DIR/../../.." && pwd -P)
readonly REPO_ROOT
readonly MANIFEST_PATH="$REPO_ROOT/apps/api-rust/Cargo.toml"
readonly CRATE_BINARY="$REPO_ROOT/apps/api-rust/target/release/lmm-api-rs"
readonly MIGRATOR_BINARY="$REPO_ROOT/apps/api-rust/target/release/lmm-db-migrate"
readonly MANIFEST_BUILDER="$SCRIPT_DIR/build-source-manifest.sh"

# These arrays are the package contract. Keep them explicit: adding a whole
# deploy directory here would accidentally reintroduce blue/green, production,
# generic-nginx, or cutover material.
readonly FALLBACK_ASSETS=(
  deploy/backend-rust/deploy-lmm-api-rs-single-instance.sh
  deploy/backend-rust/install-lmm-api-rs-single-instance.sh
  deploy/backend-rust/fallback-target-guard.sh
  deploy/backend-rust/generate-release-metadata.sh
  deploy/backend-rust/lmm-api-rs-single.service
  deploy/backend-rust/single.env
  deploy/backend-rust/test-instance.env.example
  deploy/backend-rust/nginx/fallback.lmm.best.conf
  deploy/backend-rust/create-sanitized-test-schema.sh
  deploy/backend-rust/import-sanitized-auth-snapshot.sh
  deploy/backend-rust/sanitized-auth-snapshot-v1.tsv.schema
  deploy/backend-rust/README-sanitized-test-schema.md
)
readonly MIGRATION_ASSETS=(
  apps/api-rust/crates/lmm-db-migrate/schema/table-map.json
  apps/api-rust/crates/lmm-db-migrate/schema/postgresql-baseline.sql
  apps/api-rust/crates/lmm-db-migrate/schema/export-postgres-catalog.sql
  apps/api-rust/migrations/0001_schema_contract.sql
  apps/api-rust/migrations/0002_open_source_bounty_schema.sql
  apps/api-rust/tests/fixtures/routes/legacy-go-routes.tsv
)

die() {
  printf 'build-local-package: %s\n' "$*" >&2
  exit 1
}

usage() {
  cat <<'EOF'
Usage: build-local-package.sh [--output-dir ABSOLUTE_OR_RELATIVE_PATH]

Builds lmm-api-rs and lmm-db-migrate locally, then packages only the
fallback.lmm.best single-instance assets declared in this script. The
deterministic source-manifest SHA-256 is the package identity, the Rust build
revision, and the installed revision. There is intentionally no revision
override or escape hatch. This command never connects to or deploys on a
server.
EOF
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || die "required command is unavailable: $1"
}

OUTPUT_DIR="$SCRIPT_DIR/out"
while (($#)); do
  case $1 in
    --output-dir)
      (($# >= 2)) || die '--output-dir requires a path'
      OUTPUT_DIR=$2
      shift 2
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    --revision)
      die '--revision is forbidden; source-manifest SHA-256 is the only identity'
      ;;
    *) die "unknown argument: $1" ;;
  esac
done

[[ $(uname -m) == x86_64 ]] || die 'lmm-api-rs-fallback-bin only packages a locally built x86_64 binary'
[[ -f $MANIFEST_PATH && ! -L $MANIFEST_PATH ]] || die "Rust workspace manifest is missing: $MANIFEST_PATH"
[[ -f $SCRIPT_DIR/PKGBUILD && ! -L $SCRIPT_DIR/PKGBUILD ]] || die "PKGBUILD is missing: $SCRIPT_DIR/PKGBUILD"
[[ -f $SCRIPT_DIR/lmm-api-rs-fallback-bin.install && ! -L $SCRIPT_DIR/lmm-api-rs-fallback-bin.install ]] || \
  die 'install scriptlet template is missing'
[[ -x $MANIFEST_BUILDER && ! -L $MANIFEST_BUILDER ]] || die 'source manifest builder is missing or not executable'

for required_asset in "${FALLBACK_ASSETS[@]}" "${MIGRATION_ASSETS[@]}"; do
  path="$REPO_ROOT/$required_asset"
  [[ -f $path && ! -L $path ]] || die "required packaging asset is missing or unsafe: $required_asset"
done
if find -P "$REPO_ROOT/apps/api-rust" -type d -name target -prune -o -type l -print -quit | grep -q .; then
  die "source tree must not contain symlinks outside target directories: $REPO_ROOT/apps/api-rust"
fi

for command in awk cargo find install makepkg sha256sum stat tar; do
  require_command "$command"
done

if [[ $OUTPUT_DIR != /* ]]; then
  OUTPUT_DIR="$PWD/$OUTPUT_DIR"
fi
mkdir -p -- "$OUTPUT_DIR"
OUTPUT_DIR=$(cd -- "$OUTPUT_DIR" && pwd -P)

workspace_version=$(sed -nE 's/^version = "([0-9][0-9A-Za-z._]*)"$/\1/p' "$MANIFEST_PATH" | head -n1)
[[ -n $workspace_version ]] || die 'could not determine workspace version'

build_dir=$(mktemp -d "${TMPDIR:-/tmp}/lmm-api-rs-fallback-bin.XXXXXXXX")
cleanup() { rm -rf -- "$build_dir"; }
trap cleanup EXIT
makepkg_build_dir="$build_dir/makepkg"
mkdir -p -- "$makepkg_build_dir"

source_manifest="$build_dir/source-manifest.tsv"
source_manifest_sha="$build_dir/source-manifest.sha256"
manifest_args=(
  --root "$REPO_ROOT"
  --output "$source_manifest"
  --sha256-output "$source_manifest_sha"
  --path apps/api-rust
  --exclude apps/api-rust/target
  --path apps/api-rust/Cargo.toml
  --path apps/api-rust/Cargo.lock
)
while IFS= read -r -d '' target_dir; do
  target_relative=${target_dir#"$REPO_ROOT/"}
  manifest_args+=(--exclude "$target_relative")
done < <(find -P "$REPO_ROOT/apps/api-rust" -type d -name target -print0)
for path in "${FALLBACK_ASSETS[@]}" "${MIGRATION_ASSETS[@]}"; do
  manifest_args+=(--path "$path")
done
manifest_args+=(
  --path packaging/local/lmm-api-rs-fallback-bin/PKGBUILD
  --path packaging/local/lmm-api-rs-fallback-bin/lmm-api-rs-fallback-bin.install
)
"$MANIFEST_BUILDER" "${manifest_args[@]}"
manifest_sha=$(<"$source_manifest_sha")
[[ $manifest_sha =~ ^[0-9a-f]{64}$ ]] || die 'source manifest aggregate is not a SHA-256'

pkgver="${workspace_version}.${manifest_sha}"
printf 'Building Rust runtime and migrator for manifest %s (package version %s)...\n' \
  "$manifest_sha" "$pkgver" >&2
LMM_BUILD_REVISION="$manifest_sha" cargo build --manifest-path "$MANIFEST_PATH" --release --locked \
  -p lmm-api-rs -p lmm-db-migrate >&2
[[ -x $CRATE_BINARY && ! -L $CRATE_BINARY ]] || die "local Cargo build did not create: $CRATE_BINARY"
[[ -x $MIGRATOR_BINARY && ! -L $MIGRATOR_BINARY ]] || die "local Cargo build did not create: $MIGRATOR_BINARY"

install -Dm0755 "$CRATE_BINARY" "$build_dir/lmm-api-rs"
install -Dm0755 "$MIGRATOR_BINARY" "$build_dir/lmm-db-migrate"
printf '%s\n' "$manifest_sha" >"$build_dir/revision.txt"
chmod 0644 "$build_dir/revision.txt"
{
  sha256sum "$CRATE_BINARY" | awk '{print $1 "  usr/lib/lmm-api-rs/bin/lmm-api-rs"}'
  sha256sum "$MIGRATOR_BINARY" | awk '{print $1 "  usr/lib/lmm-api-rs/bin/lmm-db-migrate"}'
} >"$build_dir/payload.sha256"
chmod 0644 "$build_dir/payload.sha256"
install -Dm0644 "$source_manifest" "$build_dir/source-manifest.tsv"
install -Dm0644 "$source_manifest_sha" "$build_dir/source-manifest.sha256"
install -Dm0644 "$SCRIPT_DIR/lmm-api-rs-fallback-bin.install" \
  "$build_dir/lmm-api-rs-fallback-bin.install"

# Transport only the declared runtime files. The PKGBUILD installs each path
# explicitly, so this archive can never become an installed deploy-tree mirror.
tar_args=(
  --sort=name
  --mtime='UTC 1970-01-01'
  --owner=0
  --group=0
  --numeric-owner
  -C "$REPO_ROOT"
  -cf "$build_dir/selected-fallback-assets.tar"
)
tar_args+=("${FALLBACK_ASSETS[@]}" "${MIGRATION_ASSETS[@]}")
tar "${tar_args[@]}"

install -Dm0644 "$SCRIPT_DIR/PKGBUILD" "$build_dir/PKGBUILD"

printf 'Packaging fallback single-instance assets...\n' >&2
(
  cd -- "$build_dir"
  BUILDDIR="$makepkg_build_dir" LMM_API_RS_PKGVER="$pkgver" LMM_API_RS_PKGREL=1 \
    makepkg --force --nodeps --noconfirm --cleanbuild >&2
)

packages=("$build_dir"/lmm-api-rs-fallback-bin-"$pkgver"-1-x86_64.pkg.tar.zst)
[[ ${#packages[@]} -eq 1 && -f ${packages[0]} && ! -L ${packages[0]} ]] || \
  die 'makepkg did not produce exactly the expected .pkg.tar.zst artifact'

package_path="$OUTPUT_DIR/${packages[0]##*/}"
install -Dm0644 "${packages[0]}" "$package_path"
package_sha256=$(sha256sum "$package_path" | awk '{print $1}')
[[ $package_sha256 =~ ^[0-9a-f]{64}$ ]] || die 'could not calculate package SHA-256'

printf 'package=%s\nrevision=%s\nsha256=%s\n' "$package_path" "$manifest_sha" "$package_sha256"
