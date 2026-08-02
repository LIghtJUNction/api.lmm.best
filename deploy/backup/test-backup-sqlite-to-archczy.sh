#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
BACKUP_SCRIPT="$SCRIPT_DIR/backup-sqlite-to-archczy.sh"
test_root="$(mktemp -d)"
trap 'rm -rf -- "$test_root"' EXIT
fail() { printf 'test-backup-sqlite-to-archczy: %s\n' "$*" >&2; exit 1; }
command -v fakeroot >/dev/null 2>&1 || fail 'fakeroot is required for offline root-owned remote simulation'

make_fakes() {
  mkdir -p -- "$test_root/bin" "$test_root/credentials" "$test_root/tmp"
  : >"$test_root/credentials/archczy-backup.identity"
  : >"$test_root/credentials/archczy-backup.known_hosts"
  chmod 0600 -- "$test_root/credentials"/*
  cat >"$test_root/bin/fake-scp" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
while [[ "$1" == -i || "$1" == -o ]]; do shift 2; done
[[ "$1" == -- ]] || exit 90
source="$2"; target="$3"
[[ "$target" == fake-archczy:/var/backups/lmm-api/sqlite/* ]] || exit 91
[[ "${FAKE_SCP_FAIL:-0}" != 1 ]] || exit 92
if [[ "${FAKE_SCP_FAIL_SECOND:-0}" == 1 && "$source" == *.sha256 ]]; then exit 93; fi
suffix="${target#fake-archczy:/var/backups/lmm-api/sqlite}"
destination="${FAKE_REMOTE_ROOT}/var/backups/lmm-api/sqlite${suffix}"
cp -- "$source" "$destination"
EOF
  cat >"$test_root/bin/fake-ssh" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
while [[ "$1" == -i || "$1" == -o ]]; do shift 2; done
[[ "$1" == fake-archczy ]] || exit 94
shift
[[ "${FAKE_SSH_FAIL:-0}" != 1 ]] || exit 95
[[ "$1" == bash && "$2" == -s && "$3" == -- ]] || exit 96
shift 3
export PATH="${FAKE_REMOTE_BIN:-$PATH}:$PATH"
sed "s|remote_root='/var/backups/lmm-api/sqlite'|remote_root='${FAKE_REMOTE_ROOT}/var/backups/lmm-api/sqlite'|" |
  fakeroot -- bash -s -- "$@"
EOF
  chmod 0755 -- "$test_root/bin/fake-scp" "$test_root/bin/fake-ssh"
  mkdir -p -- "$test_root/remote/var/backups/lmm-api"
}

run_backup() {
  local source="$1" lock="$2" instance="${3:-production}"
  SQLITE_BACKUP_SOURCE_DB="$source" SQLITE_BACKUP_REMOTE_HOST='fake-archczy' \
    SQLITE_BACKUP_REMOTE_INSTANCE="$instance" SQLITE_BACKUP_LOCK_FILE="$lock" \
    CREDENTIALS_DIRECTORY="$test_root/credentials" SSH_BIN="$test_root/bin/fake-ssh" \
    SCP_BIN="$test_root/bin/fake-scp" FAKE_REMOTE_ROOT="$test_root/remote" \
    FAKE_REMOTE_BIN="${FAKE_REMOTE_BIN:-}" \
    TMPDIR="$test_root/tmp" bash "$BACKUP_SCRIPT"
}

remote_dir() { printf '%s/remote/var/backups/lmm-api/sqlite/%s\n' "$test_root" "${1:-production}"; }
count_valid() {
  local dir="$1" candidate name count=0
  shopt -s nullglob
  for candidate in "$dir"/lmm-api-sqlite-*.sqlite.zst; do
    name="$(basename -- "$candidate")"
    [[ -f "$candidate.sha256" ]] || continue
    (cd -- "$dir" && sha256sum -c -- "$name.sha256" >/dev/null) || continue
    ((count += 1))
  done
  printf '%s\n' "$count"
}

test_wal_backup_and_three_version_retention() {
  local source="$test_root/wal.db" lock="$test_root/wal.lock" dir archive
  sqlite3 "$source" "PRAGMA journal_mode=WAL; CREATE TABLE t (value TEXT); INSERT INTO t VALUES ('first');"
  for _ in 1 2 3 4; do
    sqlite3 "$source" "INSERT INTO t VALUES ('next');"
    run_backup "$source" "$lock"
    sleep 1
  done
  dir="$(remote_dir)"
  [[ "$(count_valid "$dir")" == 3 ]] || fail 'did not retain exactly three valid snapshots'
  for archive in "$dir"/*.sqlite.zst; do
    zstd -q -d -c -- "$archive" | sqlite3 ':memory:' 'PRAGMA quick_check;' | grep -qx ok ||
      fail 'decompressed WAL snapshot did not pass quick_check'
  done
  [[ "$(stat -c '%a' -- "$dir")" == 700 ]] || fail 'remote directory mode is not 0700'
}

test_failures_preserve_last_three() {
  local source="$test_root/failure.db" lock="$test_root/failure.lock" dir
  sqlite3 "$source" 'CREATE TABLE t (value TEXT);'
  for _ in 1 2 3; do run_backup "$source" "$lock" failures; sleep 1; done
  dir="$(remote_dir failures)"
  if FAKE_SCP_FAIL_SECOND=1 run_backup "$source" "$lock" failures; then fail 'second SCP failure succeeded'; fi
  [[ "$(count_valid "$dir")" == 3 ]] || fail 'second SCP failure removed a valid snapshot'
  if FAKE_SSH_FAIL=1 run_backup "$source" "$lock" failures; then fail 'remote validation failure succeeded'; fi
  [[ "$(count_valid "$dir")" == 3 ]] || fail 'remote validation failure removed a valid snapshot'
}

test_remote_dependency_failure_does_not_promote() {
  local source="$test_root/dependency.db" lock="$test_root/dependency.lock" dir fakebin="$test_root/remote-bin"
  sqlite3 "$source" 'CREATE TABLE t (value TEXT);'
  run_backup "$source" "$lock" dependency
  dir="$(remote_dir dependency)"
  mkdir -p -- "$fakebin"
  cat >"$fakebin/realpath" <<'EOF'
#!/usr/bin/env bash
exit 127
EOF
  chmod 0755 -- "$fakebin/realpath"
  export FAKE_REMOTE_BIN="$fakebin"
  if run_backup "$source" "$lock" dependency; then fail 'missing remote dependency succeeded'; fi
  unset FAKE_REMOTE_BIN
  [[ "$(count_valid "$dir")" == 1 ]] || fail 'dependency failure promoted or deleted a snapshot'
}

test_path_and_lock_protection() {
  local source="$test_root/protect.db" lock="$test_root/protect.lock"
  sqlite3 "$source" 'CREATE TABLE t (value TEXT);'
  if SQLITE_BACKUP_SOURCE_DB='relative.db' SQLITE_BACKUP_REMOTE_HOST=fake-archczy CREDENTIALS_DIRECTORY="$test_root/credentials" bash "$BACKUP_SCRIPT"; then fail 'relative source accepted'; fi
  if run_backup "$source" "$lock" '../escape'; then fail 'unsafe instance accepted'; fi
  exec 8>"$lock"; flock -n 8
  if run_backup "$source" "$lock"; then fail 'concurrent invocation acquired lock'; fi
  flock -u 8
}

make_fakes
test_wal_backup_and_three_version_retention
test_failures_preserve_last_three
test_remote_dependency_failure_does_not_promote
test_path_and_lock_protection
printf 'test-backup-sqlite-to-archczy: OK\n'
