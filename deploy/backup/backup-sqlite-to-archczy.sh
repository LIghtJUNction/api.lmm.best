#!/usr/bin/env bash
# Creates a verified online SQLite backup and transfers it to the fixed archczy backup root.
set -Eeuo pipefail

readonly REMOTE_ROOT='/var/backups/lmm-api/sqlite'
readonly SNAPSHOT_PREFIX='lmm-api-sqlite-'
readonly SNAPSHOT_PATTERN='^lmm-api-sqlite-[0-9]{8}T[0-9]{6}Z-[a-f0-9]{16}\.sqlite\.zst$'

SQLITE3_BIN="${SQLITE3_BIN:-sqlite3}"
ZSTD_BIN="${ZSTD_BIN:-zstd}"
SHA256SUM_BIN="${SHA256SUM_BIN:-sha256sum}"
SCP_BIN="${SCP_BIN:-scp}"
SSH_BIN="${SSH_BIN:-ssh}"
LOCK_FILE="${SQLITE_BACKUP_LOCK_FILE:-/run/lock/lmm-api-sqlite-backup.lock}"
REMOTE_INSTANCE="${SQLITE_BACKUP_REMOTE_INSTANCE:-production}"

log() { printf '[lmm-api-sqlite-backup] %s\n' "$*" >&2; }
die() { log "ERROR: $*"; exit 1; }

require_absolute_path() {
  local value="$1" label="$2"
  [[ "$value" == /* && "$value" != *$'\n'* ]] || die "$label must be an absolute path"
}

require_tools() {
  local tool
  for tool in "$SQLITE3_BIN" "$ZSTD_BIN" "$SHA256SUM_BIN" "$SCP_BIN" "$SSH_BIN" \
    flock mktemp date install mv chmod awk tr od dirname rm; do
    command -v "$tool" >/dev/null 2>&1 || die "missing command: $tool"
  done
}

require_configuration() {
  : "${SQLITE_BACKUP_SOURCE_DB:?SQLITE_BACKUP_SOURCE_DB must be set}"
  : "${SQLITE_BACKUP_REMOTE_HOST:?SQLITE_BACKUP_REMOTE_HOST must be set}"
  : "${CREDENTIALS_DIRECTORY:?CREDENTIALS_DIRECTORY must be set by systemd LoadCredential}"
  require_absolute_path "$SQLITE_BACKUP_SOURCE_DB" 'SQLITE_BACKUP_SOURCE_DB'
  require_absolute_path "$LOCK_FILE" 'SQLITE_BACKUP_LOCK_FILE'
  require_absolute_path "$CREDENTIALS_DIRECTORY" 'CREDENTIALS_DIRECTORY'
  [[ "$SQLITE_BACKUP_REMOTE_HOST" =~ ^[A-Za-z0-9_.@-]+$ ]] || die 'SQLITE_BACKUP_REMOTE_HOST contains unsupported characters'
  [[ "$REMOTE_INSTANCE" =~ ^[A-Za-z0-9][A-Za-z0-9_-]{0,63}$ ]] || die 'SQLITE_BACKUP_REMOTE_INSTANCE is unsafe'
  [[ -f "$SQLITE_BACKUP_SOURCE_DB" && -r "$SQLITE_BACKUP_SOURCE_DB" ]] || die 'source SQLite database is not a readable regular file'
  IDENTITY_FILE="$CREDENTIALS_DIRECTORY/archczy-backup.identity"
  KNOWN_HOSTS_FILE="$CREDENTIALS_DIRECTORY/archczy-backup.known_hosts"
  [[ -f "$IDENTITY_FILE" && -r "$IDENTITY_FILE" ]] || die 'missing archczy backup SSH identity credential'
  [[ -f "$KNOWN_HOSTS_FILE" && -r "$KNOWN_HOSTS_FILE" ]] || die 'missing archczy backup known_hosts credential'
}

temporary_dir=''
cleanup() {
  local status=$?
  [[ -z "$temporary_dir" ]] || rm -rf -- "$temporary_dir"
  return "$status"
}
trap cleanup EXIT

main() {
  local lock_parent backup_db archive_partial archive checksum_file quick_check snapshot_id snapshot_name archive_hash
  local remote_dir remote_archive_temp remote_checksum_temp
  local -a transport_options

  require_tools
  require_configuration
  transport_options=(-i "$IDENTITY_FILE" -o "UserKnownHostsFile=$KNOWN_HOSTS_FILE" -o StrictHostKeyChecking=yes -o IdentitiesOnly=yes -o BatchMode=yes)
  remote_dir="$REMOTE_ROOT/$REMOTE_INSTANCE"

  lock_parent="$(dirname -- "$LOCK_FILE")"
  install -d -m 0700 -- "$lock_parent"
  exec 9>"$LOCK_FILE"
  flock -n 9 || die 'another SQLite backup is already running'

  temporary_dir="$(mktemp -d "${TMPDIR:-/tmp}/lmm-api-sqlite-backup.XXXXXXXX")"
  chmod 0700 -- "$temporary_dir"
  backup_db="$temporary_dir/one-api.db"
  archive_partial="$temporary_dir/one-api.db.zst.partial"
  archive="$temporary_dir/one-api.db.zst"
  checksum_file="$temporary_dir/one-api.db.zst.sha256"

  # SQLite's backup API yields a transactionally consistent online copy.
  "$SQLITE3_BIN" "$SQLITE_BACKUP_SOURCE_DB" ".backup '$backup_db'"
  quick_check="$("$SQLITE3_BIN" "$backup_db" 'PRAGMA quick_check;' | tr -d '\r')"
  [[ "$quick_check" == 'ok' ]] || die 'SQLite quick_check failed for the temporary snapshot'
  "$ZSTD_BIN" -q -T0 -19 -f -o "$archive_partial" -- "$backup_db"
  "$ZSTD_BIN" -q -t -- "$archive_partial"
  chmod 0600 -- "$archive_partial"
  mv -fT -- "$archive_partial" "$archive"

  archive_hash="$("$SHA256SUM_BIN" -- "$archive" | awk '{print $1}')"
  [[ "$archive_hash" =~ ^[a-f0-9]{64}$ ]] || die 'could not calculate SHA-256 for compressed snapshot'
  snapshot_id="$(date -u +%Y%m%dT%H%M%SZ)-$(od -An -N8 -tx1 /dev/urandom | tr -d ' \n')"
  snapshot_name="${SNAPSHOT_PREFIX}${snapshot_id}.sqlite.zst"
  [[ "$snapshot_name" =~ $SNAPSHOT_PATTERN ]] || die 'generated an unsafe snapshot name'
  # The checksum is written last locally; it is the local publication marker.
  printf '%s  %s\n' "$archive_hash" "$snapshot_name" >"$checksum_file"
  chmod 0600 -- "$archive" "$checksum_file"

  remote_archive_temp=".${snapshot_name}.upload.${snapshot_id}"
  remote_checksum_temp=".${snapshot_name}.sha256.upload.${snapshot_id}"

  # Do not upload before the fixed remote root and the single safe instance
  # directory have been created and verified by the pinned remote account.
  "$SSH_BIN" "${transport_options[@]}" "$SQLITE_BACKUP_REMOTE_HOST" bash -s -- "$REMOTE_INSTANCE" <<'PREFLIGHT'
set -Eeuo pipefail
instance="$1"
remote_root='/var/backups/lmm-api/sqlite'
fail() { printf '[lmm-api-sqlite-backup remote] ERROR: %s\n' "$*" >&2; exit 1; }
for tool in realpath stat install id; do
  command -v "$tool" >/dev/null 2>&1 || fail "missing remote command: $tool"
done
[[ "$instance" =~ ^[A-Za-z0-9][A-Za-z0-9_-]{0,63}$ ]] || fail 'remote instance is unsafe'
[[ "$(id -u)" == 0 ]] || fail 'remote backup account must run as root'
install -d -o root -g root -m 0700 -- "$remote_root"
dir="$remote_root/$instance"
install -d -o root -g root -m 0700 -- "$dir"
[[ "$(realpath -e -- "$remote_root")" == "$remote_root" ]] || fail 'backup root must not resolve through a symlink'
[[ "$(realpath -e -- "$dir")" == "$dir" ]] || fail 'backup instance directory must not resolve through a symlink'
for candidate in "$remote_root" "$dir"; do
  [[ "$(stat -c '%U:%G:%a' -- "$candidate")" == 'root:root:700' ]] || fail 'remote backup directories must be root:root mode 0700'
done
PREFLIGHT

  "$SCP_BIN" "${transport_options[@]}" -- "$archive" "${SQLITE_BACKUP_REMOTE_HOST}:${remote_dir}/${remote_archive_temp}"
  "$SCP_BIN" "${transport_options[@]}" -- "$checksum_file" "${SQLITE_BACKUP_REMOTE_HOST}:${remote_dir}/${remote_checksum_temp}"

  "$SSH_BIN" "${transport_options[@]}" "$SQLITE_BACKUP_REMOTE_HOST" bash -s -- \
    "$REMOTE_INSTANCE" "$remote_archive_temp" "$remote_checksum_temp" "$snapshot_name" "$SNAPSHOT_PATTERN" <<'REMOTE'
set -Eeuo pipefail
instance="$1"
archive_temp_name="$2"
checksum_temp_name="$3"
snapshot_name="$4"
snapshot_pattern="$5"
remote_root='/var/backups/lmm-api/sqlite'
snapshot_prefix='lmm-api-sqlite-'
fail() { printf '[lmm-api-sqlite-backup remote] ERROR: %s\n' "$*" >&2; exit 1; }

for tool in realpath sha256sum awk sort basename rm mv chmod stat id; do
  command -v "$tool" >/dev/null 2>&1 || fail "missing remote command: $tool"
done
[[ "$instance" =~ ^[A-Za-z0-9][A-Za-z0-9_-]{0,63}$ ]] || fail 'remote instance is unsafe'
[[ "$(id -u)" == 0 ]] || fail 'remote backup account must run as root'
dir="$remote_root/$instance"
[[ "$snapshot_name" =~ $snapshot_pattern ]] || fail 'unsafe snapshot filename'
[[ "$archive_temp_name" == ".${snapshot_name}.upload."* && "$archive_temp_name" != */* ]] || fail 'unsafe archive temporary filename'
[[ "$checksum_temp_name" == ".${snapshot_name}.sha256.upload."* && "$checksum_temp_name" != */* ]] || fail 'unsafe checksum temporary filename'

[[ "$(realpath -e -- "$remote_root")" == "$remote_root" ]] || fail 'backup root must not resolve through a symlink'
[[ "$(realpath -e -- "$dir")" == "$dir" ]] || fail 'backup instance directory must not resolve through a symlink'
for candidate in "$remote_root" "$dir"; do
  [[ "$(stat -c '%U:%G:%a' -- "$candidate")" == 'root:root:700' ]] || fail 'remote backup directories must be root:root mode 0700'
done
archive_temp="$dir/$archive_temp_name"
checksum_temp="$dir/$checksum_temp_name"
archive="$dir/$snapshot_name"
checksum="$archive.sha256"
[[ -f "$archive_temp" && -f "$checksum_temp" ]] || fail 'uploaded temporary pair is incomplete'
chmod 0600 -- "$archive_temp" "$checksum_temp"
(
  cd -- "$dir"
  read -r expected_hash expected_name <"$checksum_temp"
  [[ "$expected_name" == "$snapshot_name" && "$expected_hash" =~ ^[a-f0-9]{64}$ ]] || fail 'unsafe checksum metadata'
  observed_hash="$(sha256sum -- "$archive_temp" | awk '{print $1}')"
  [[ "$observed_hash" == "$expected_hash" ]] || fail 'uploaded archive checksum mismatch'
)
# Promote archive first; checksum appears last and is the remote publication marker.
mv -fT -- "$archive_temp" "$archive"
chmod 0600 -- "$archive"
mv -fT -- "$checksum_temp" "$checksum"
chmod 0600 -- "$checksum"
[[ "$(stat -c '%a' -- "$archive")" == 600 && "$(stat -c '%a' -- "$checksum")" == 600 ]] || fail 'remote snapshot permissions must be 0600'

mapfile -t snapshots < <(
  for candidate in "$dir"/${snapshot_prefix}*.sqlite.zst; do
    [[ -f "$candidate" ]] || continue
    name="$(basename -- "$candidate")"
    [[ "$name" =~ $snapshot_pattern && -f "$candidate.sha256" ]] || continue
    (cd -- "$dir" && sha256sum -c -- "$name.sha256" >/dev/null 2>&1) || continue
    printf '%s\n' "$name"
  done | LC_ALL=C sort -r
)
(( ${#snapshots[@]} >= 1 )) || fail 'no checksum-valid snapshot remains after upload'
for ((index = 3; index < ${#snapshots[@]}; index++)); do
  old_name="${snapshots[index]}"
  [[ "$old_name" =~ $snapshot_pattern ]] || fail 'refusing to delete an unsafe filename'
  rm -f -- "$dir/$old_name" "$dir/$old_name.sha256"
done
REMOTE
  log "backup completed: $snapshot_name"
}

main "$@"
