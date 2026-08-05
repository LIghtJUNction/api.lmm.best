#!/usr/bin/env bash
# Package-bound activation for the isolated fallback instance.  It never
# changes nginx, blue/green units, or any production path.
set -Eeuo pipefail
umask 077

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
readonly SCRIPT_DIR
readonly GUARD="$SCRIPT_DIR/fallback-target-guard.sh"
readonly PACKAGE_NAME='lmm-api-rs-fallback-bin'
readonly SERVICE_NAME='lmm-api-rs-single.service'

die() { printf 'deploy-lmm-api-rs-single-instance: %s\n' "$*" >&2; exit 1; }
is_sha256() { [[ $1 =~ ^[0-9a-f]{64}$ ]]; }

usage() {
  cat <<'EOF'
Usage: deploy-lmm-api-rs-single-instance.sh --package /absolute/package.pkg.tar.zst --package-sha256 64-lowercase-hex [--activate]

Installs one audited Arch package on the machine bound fallback host.  Without
--activate it only prepares and atomically selects the immutable release.
EOF
}

PACKAGE=''
PACKAGE_SHA256=''
ACTIVATE=0
while (($#)); do
  case $1 in
    --package) (($# >= 2)) || die '--package requires a value'; PACKAGE=$2; shift 2 ;;
    --package-sha256) (($# >= 2)) || die '--package-sha256 requires a value'; PACKAGE_SHA256=$2; shift 2 ;;
    --activate) ACTIVATE=1; shift ;;
    --help|-h) usage; exit 0 ;;
    *) die "unknown argument: $1" ;;
  esac
done

[[ ${LMM_RS_TEST_INSTANCE:-} == 1 ]] || die 'refusing to deploy without LMM_RS_TEST_INSTANCE=1'
[[ -x $GUARD && ! -L $GUARD ]] || die 'shared fallback target guard is missing or unsafe'
"$GUARD"
[[ $EUID -eq 0 || ${LMM_RS_MOCK:-} == 1 ]] || die 'must run as root'
[[ $PACKAGE == /* && -f $PACKAGE && ! -L $PACKAGE && $PACKAGE == *.pkg.tar.zst ]] || \
  die 'package must be an absolute non-symlink .pkg.tar.zst regular file'
is_sha256 "$PACKAGE_SHA256" || die 'package SHA-256 must be 64 lowercase hexadecimal characters'
[[ $(sha256sum "$PACKAGE" | awk '{print $1}') == "$PACKAGE_SHA256" ]] || die 'package checksum mismatch'

if [[ ${LMM_RS_MOCK:-} == 1 ]]; then
  ROOT=${LMM_RS_SINGLE_ROOT:-/opt/lmm-api-rs-single}
  ETC_ROOT=${LMM_RS_SINGLE_ETC_ROOT:-/etc/lmm-api-rs-single}
  BIN_PATH=${LMM_RS_INSTALLED_BINARY:-/usr/lib/lmm-api-rs/bin/lmm-api-rs}
  MIGRATOR_PATH=${LMM_RS_INSTALLED_MIGRATOR:-/usr/lib/lmm-api-rs/bin/lmm-db-migrate}
  REVISION_PATH=${LMM_RS_INSTALLED_REVISION:-/usr/share/lmm-api-rs/revision}
  PAYLOAD_PATH=${LMM_RS_PAYLOAD_MANIFEST:-/usr/share/lmm-api-rs/payload.sha256}
  SOURCE_MANIFEST_PATH=${LMM_RS_SOURCE_MANIFEST:-/usr/share/lmm-api-rs/source-manifest.sha256}
else
  ROOT=/opt/lmm-api-rs-single
  ETC_ROOT=/etc/lmm-api-rs-single
  BIN_PATH=/usr/lib/lmm-api-rs/bin/lmm-api-rs
  MIGRATOR_PATH=/usr/lib/lmm-api-rs/bin/lmm-db-migrate
  REVISION_PATH=/usr/share/lmm-api-rs/revision
  PAYLOAD_PATH=/usr/share/lmm-api-rs/payload.sha256
  SOURCE_MANIFEST_PATH=/usr/share/lmm-api-rs/source-manifest.sha256
fi
if [[ ${LMM_RS_MOCK:-} == 1 ]]; then
  LOCK_PATH=${LMM_RS_SINGLE_LOCK:-${ROOT}.lock}
else
  LOCK_PATH=/run/lock/lmm-api-rs-single.lock
fi
readonly ROOT ETC_ROOT BIN_PATH MIGRATOR_PATH REVISION_PATH PAYLOAD_PATH SOURCE_MANIFEST_PATH LOCK_PATH
readonly RELEASES="$ROOT/releases"
readonly CURRENT="$ROOT/current"
readonly JOURNAL="$ROOT/release-journal.log"
readonly CURRENT_STATE="$ROOT/current-state"

for required in "$ETC_ROOT/common.env" "$ETC_ROOT/single.env"; do
  [[ -f $required && ! -L $required && -s $required ]] || die "required test configuration is absent or unsafe: $required"
done

require_owned_regular_file() {
  local path=$1
  [[ -f $path && ! -L $path ]] || die "required installed file is unsafe or absent: $path"
  [[ $(pacman -Qoq "$path") == "$PACKAGE_NAME" ]] || die "installed file is not owned by $PACKAGE_NAME: $path"
}

payload_hash_for() {
  local path=$1
  awk -v path="$path" '
    NF == 2 && $1 ~ /^[0-9a-f]{64}$/ && ($2 == path || $2 == "./" substr(path, 2)) { count++; value=$1 }
    END { if (count == 1) print value; else exit 1 }
  ' "$PAYLOAD_PATH"
}

verify_payload_entry() {
  local path=$1 expected actual
  expected=$(payload_hash_for "$path") || die "payload manifest has no unique hash for: $path"
  actual=$(sha256sum "$path" | awk '{print $1}')
  [[ $actual == "$expected" ]] || die "installed payload hash mismatch: $path"
}

read_single_hash() {
  local path=$1 label=$2
  local -a lines=()
  mapfile -t lines <"$path"
  [[ ${#lines[@]} -eq 1 ]] || die "$label must contain exactly one aggregate hash"
  is_sha256 "${lines[0]}" || die "$label aggregate is invalid"
  printf '%s\n' "${lines[0]}"
}

release_metadata_value() {
  local metadata=$1 key=$2
  awk -F= -v key="$key" '$1 == key { count++; value=$2 } END { if (count == 1) print value; else exit 1 }' "$metadata"
}

verify_release() {
  local manifest=$1
  local release_dir="$RELEASES/$manifest" metadata binary_hash expected_hash
  is_sha256 "$manifest" || return 1
  [[ -d $release_dir && ! -L $release_dir && ! -L $release_dir/lmm-api-rs ]] || return 1
  metadata="$release_dir/release.env"
  [[ -f $metadata && ! -L $metadata && -f $release_dir/lmm-api-rs ]] || return 1
  [[ $(release_metadata_value "$metadata" manifest) == "$manifest" ]] || return 1
  expected_hash=$(release_metadata_value "$metadata" binary_sha256) || return 1
  is_sha256 "$expected_hash" || return 1
  binary_hash=$(sha256sum "$release_dir/lmm-api-rs" | awk '{print $1}')
  [[ $binary_hash == "$expected_hash" ]]
}

current_manifest() {
  local target
  [[ -L $CURRENT ]] || return 1
  target=$(readlink "$CURRENT") || return 1
  [[ $target =~ ^releases/([0-9a-f]{64})$ ]] || return 1
  printf '%s\n' "${BASH_REMATCH[1]}"
}

select_release() {
  local manifest=$1 temporary_link
  temporary_link="$ROOT/.current.${manifest}.$$.new"
  ln -s "releases/$manifest" "$temporary_link"
  mv -Tf "$temporary_link" "$CURRENT"
}

write_current_state() {
  local manifest=$1 previous=$2 temporary="$ROOT/.current-state.$$.new"
  printf 'current=%s\nprevious=%s\n' "$manifest" "$previous" >"$temporary"
  chmod 0600 "$temporary"
  if [[ ${LMM_RS_MOCK:-} != 1 ]]; then
    chown 0:0 "$temporary"
  fi
  mv -Tf "$temporary" "$CURRENT_STATE"
}

journal_record() {
  local package_version=$1 manifest=$2 binary_hash=$3 previous=$4
  [[ ! -L $ROOT ]] || die 'release root must not be a symlink'
  [[ ! -e $JOURNAL || ! -L $JOURNAL ]] || die 'release journal must not be a symlink'
  touch "$JOURNAL"
  if [[ ${LMM_RS_MOCK:-} != 1 ]]; then
    chown 0:0 "$JOURNAL"
  fi
  chmod 0600 "$JOURNAL"
  printf 'package=%s package_sha256=%s version=%s manifest=%s binary_sha256=%s previous=%s\n' \
    "${PACKAGE##*/}" "$PACKAGE_SHA256" "$package_version" "$manifest" "$binary_hash" "$previous" >>"$JOURNAL"
}

probe_active_release() {
  local build
  curl --fail --silent --show-error --max-time 3 http://127.0.0.1:3100/livez >/dev/null
  curl --fail --silent --show-error --max-time 3 http://127.0.0.1:3100/readyz >/dev/null
  build=$(curl --fail --silent --show-error --max-time 3 http://127.0.0.1:3100/_internal/build)
  jq -e --arg manifest "$1" '.revision == $manifest and .slot == "single"' <<<"$build" >/dev/null
}

[[ ! -e $ROOT || ! -L $ROOT ]] || die 'release root must not be a symlink'
install -d -m 0755 "$ROOT"
if [[ ${LMM_RS_MOCK:-} != 1 ]]; then
  chown 0:0 "$ROOT"
fi
if [[ -e $RELEASES || -L $RELEASES ]]; then
  [[ -d $RELEASES && ! -L $RELEASES ]] || die 'release directory is unsafe'
fi
previous=none
if [[ -e $CURRENT || -L $CURRENT ]]; then
  previous=$(current_manifest) || die 'current release is unknown; refusing to mutate it'
  verify_release "$previous" || die 'current release verification failed'
fi

install -d -m 0755 "${LOCK_PATH%/*}"
exec 9>"$LOCK_PATH"
flock -n 9 || die 'another single-instance transaction is running'

archive_record=$(pacman -Qp --print-format '%n %v' "$PACKAGE") || die 'could not identify the package archive'
package_name=${archive_record%% *}
archive_version=${archive_record#* }
[[ $package_name == "$PACKAGE_NAME" ]] || die 'package archive is not the fallback package'
[[ $archive_version != "$archive_record" && -n $archive_version ]] || die 'package archive version is unavailable'
pacman -U --noconfirm "$PACKAGE"
package_record=$(pacman -Q "$PACKAGE_NAME") || die 'package installation did not register the expected package'
package_version=$(awk 'NF == 2 { print $2; found=1 } END { exit(found ? 0 : 1) }' <<<"$package_record") || \
  die 'installed package version is unavailable'
[[ $package_version == "$archive_version" ]] || die 'installed package version does not match the archive'
pacman -Qkk "$PACKAGE_NAME" >/dev/null || die 'package integrity verification failed'
for required in "$BIN_PATH" "$MIGRATOR_PATH" "$REVISION_PATH" "$PAYLOAD_PATH" "$SOURCE_MANIFEST_PATH"; do
  require_owned_regular_file "$required"
done

manifest=$(read_single_hash "$SOURCE_MANIFEST_PATH" 'source manifest')
revision=$(read_single_hash "$REVISION_PATH" 'revision')
[[ $revision == "$manifest" ]] || die 'installed revision does not equal the source-manifest aggregate'
verify_payload_entry "$BIN_PATH"
verify_payload_entry "$MIGRATOR_PATH"
verify_payload_entry "$REVISION_PATH"
binary_hash=$(payload_hash_for "$BIN_PATH") || die 'binary payload hash is unavailable'
install -d -m 0755 "$RELEASES"
[[ -d $RELEASES && ! -L $RELEASES ]] || die 'release directory is unsafe'
release_dir="$RELEASES/$manifest"
if [[ -e $release_dir || -L $release_dir ]]; then
  verify_release "$manifest" || die 'existing release directory is not an immutable verified release'
else
  stage_dir=$(mktemp -d "$RELEASES/.${manifest}.XXXXXXXX")
  cleanup_stage() { [[ -n ${stage_dir:-} && -d $stage_dir ]] && rm -rf -- "$stage_dir"; }
  trap cleanup_stage EXIT
  install -m 0555 "$BIN_PATH" "$stage_dir/lmm-api-rs"
  printf 'manifest=%s\nprevious=%s\nbinary_sha256=%s\nmigrator_sha256=%s\nrevision_sha256=%s\n' \
    "$manifest" "$previous" "$binary_hash" \
    "$(payload_hash_for "$MIGRATOR_PATH")" "$(payload_hash_for "$REVISION_PATH")" >"$stage_dir/release.env"
  chmod 0400 "$stage_dir/release.env"
  [[ $(sha256sum "$stage_dir/lmm-api-rs" | awk '{print $1}') == "$binary_hash" ]] || die 'staged binary hash mismatch'
  chmod 0555 "$stage_dir"
  mv -T "$stage_dir" "$release_dir"
  stage_dir=''
  trap - EXIT
fi
verify_release "$manifest" || die 'release verification failed before current switch'
journal_record "$package_version" "$manifest" "$binary_hash" "$previous"
select_release "$manifest"
write_current_state "$manifest" "$previous"

if ((ACTIVATE)); then
  systemctl restart "$SERVICE_NAME"
  systemctl is-active --quiet "$SERVICE_NAME"
  if ! probe_active_release "$manifest"; then
    if [[ $previous != none ]] && verify_release "$previous"; then
      select_release "$previous"
      systemctl restart "$SERVICE_NAME"
    else
      rm -f -- "$CURRENT"
    fi
    die 'direct loopback health or build identity probe failed; current release was failed closed'
  fi
fi
printf 'prepared_manifest=%s activated=%s nginx=unchanged\n' "$manifest" "$ACTIVATE"
