#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

TEST_MODE=${LMM_CUTOVER_INSTALL_TEST_MODE:-0}
INSTALL_ROOT=
expected_owner=0
expected_group=0
if [[ $TEST_MODE == 1 ]]; then
  INSTALL_ROOT=${LMM_CUTOVER_INSTALL_ROOT:?test install root is required}
  [[ $INSTALL_ROOT == /* && $INSTALL_ROOT != / ]] || { echo "unsafe test install root" >&2; exit 1; }
  expected_owner=$(id -u)
  expected_group=$(id -g)
else
  [[ $EUID -eq 0 ]] || { echo "must run as root" >&2; exit 1; }
fi
[[ ${1:-} == --migrator && $# == 2 ]] || { echo "usage: ${0##*/} --migrator /absolute/path/lmm-db-migrate" >&2; exit 1; }
MIGRATOR_SOURCE=$2
[[ $MIGRATOR_SOURCE == /* && -f $MIGRATOR_SOURCE && ! -L $MIGRATOR_SOURCE && -x $MIGRATOR_SOURCE ]] || { echo "migrator must be an absolute executable regular file" >&2; exit 1; }
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
readonly HERE
RUST_ROOT=$(cd "$HERE/../../rust" && pwd)
readonly RUST_ROOT

rooted() { printf '%s%s\n' "$INSTALL_ROOT" "$1"; }
lock_dir=$(rooted /run/lock)
install -d -m 0755 "$lock_dir"
exec 9>"$lock_dir/lmm-api-backend-cutover.lock"
flock -n 9 || { echo "another backend cutover or installer is running" >&2; exit 1; }

sources=(
  "$HERE/cutover-sqlite-to-pg.sh"
  "$HERE/lmm-api-cutover-gate.sh"
  "$HERE/prepare-candidate-env.sh"
  "$RUST_ROOT/crates/lmm-db-migrate/schema/table-map.json"
  "$RUST_ROOT/crates/lmm-db-migrate/schema/postgresql-baseline.sql"
  "$RUST_ROOT/crates/lmm-db-migrate/schema/export-postgres-catalog.sql"
  "$MIGRATOR_SOURCE"
  "$HERE/cutover.conf.example"
  "$HERE/migration.env.example"
  "$HERE/lmm-api-cutover-reconcile.service"
  "$HERE/lmm-api-cutover-canary.service"
  "$HERE/lmm-api-cutover-recover.service"
  "$HERE/lmm-api-cutover.conf"
)
target_names=(
  /usr/lib/lmm-api-cutover/cutover-sqlite-to-pg.sh
  /usr/lib/lmm-api-cutover/lmm-api-cutover-gate.sh
  /usr/lib/lmm-api-cutover/prepare-candidate-env.sh
  /usr/lib/lmm-api-cutover/schema/table-map.json
  /usr/lib/lmm-api-cutover/schema/postgresql-baseline.sql
  /usr/lib/lmm-api-cutover/schema/export-postgres-catalog.sql
  /usr/lib/lmm-api-cutover/lmm-db-migrate
  /etc/lmm-api-cutover/cutover.conf.example
  /etc/lmm-api-cutover/migration.env.example
  /etc/systemd/system/lmm-api-cutover-reconcile.service
  /etc/systemd/system/lmm-api-cutover-canary.service
  /etc/systemd/system/lmm-api-cutover-recover.service
  /etc/systemd/system/lmm-api.service.d/30-cutover-reconcile.conf
)
modes=(0755 0755 0755 0644 0644 0644 0755 0600 0600 0644 0644 0644 0644)
link_names=(/usr/local/sbin/lmm-api-cutover /usr/local/sbin/lmm-api-prepare-cutover-env)
link_values=(/usr/lib/lmm-api-cutover/cutover-sqlite-to-pg.sh /usr/lib/lmm-api-cutover/prepare-candidate-env.sh)

for source in "${sources[@]}"; do
  [[ -f $source && ! -L $source ]] || { echo "managed install source is absent or unsafe" >&2; exit 1; }
done
command -v systemctl >/dev/null || { echo "systemctl is required" >&2; exit 1; }
bash -n "${sources[0]}" "${sources[1]}" "${sources[2]}"
for unit_source in "${sources[9]}" "${sources[10]}" "${sources[11]}" "${sources[12]}"; do
  if ! grep -Fxq '[Unit]' "$unit_source" || ! grep -Fxq '[Service]' "$unit_source"; then
    echo "managed systemd unit is malformed" >&2; exit 1;
  fi
done

install -d -m 0700 "$(rooted /etc/lmm-api-cutover)" "$(rooted /var/lib/lmm-api-cutover/artifacts)" \
  "$(rooted /var/lib/lmm-api-cutover/sqlite-backups)" "$(rooted /var/log/lmm-api-cutover)"
install -d -m 0755 "$(rooted /usr/lib/lmm-api-cutover/schema)" \
  "$(rooted /etc/systemd/system/lmm-api.service.d)" "$(rooted /usr/local/sbin)"

targets=()
staged=()
backups=()
prior=()
published=()
for target_name in "${target_names[@]}"; do targets+=("$(rooted "$target_name")"); done
for link_name in "${link_names[@]}"; do targets+=("$(rooted "$link_name")"); done

enabled_units=(lmm-api-cutover-reconcile.service lmm-api-cutover-canary.service)
enabled_before=()
for unit in "${enabled_units[@]}"; do
  if systemctl is-enabled --quiet "$unit"; then enabled_before+=(1); else enabled_before+=(0); fi
done

cleanup_install_files() {
  local path
  for path in "${staged[@]}" "${backups[@]}"; do
    [[ -n ${path:-} ]] || continue
    rm -f -- "$path"
  done
}

rollback_install() {
  local original_status=$? rollback_failed=0 index target dir
  trap - ERR EXIT INT TERM
  set +e
  for ((index=${#targets[@]} - 1; index >= 0; index--)); do
    [[ ${published[index]:-0} == 1 ]] || continue
    target=${targets[index]}
    dir=${target%/*}
    if [[ ${prior[index]:-0} == 1 ]]; then
      mv -Tf -- "${backups[index]}" "$target" || rollback_failed=1
    else
      rm -f -- "$target" || rollback_failed=1
    fi
    sync -f "$dir" || rollback_failed=1
  done
  for ((index=0; index<${#enabled_units[@]}; index++)); do
    if [[ ${enabled_before[index]} == 1 ]]; then
      systemctl enable "${enabled_units[index]}" >/dev/null || rollback_failed=1
    else
      systemctl disable "${enabled_units[index]}" >/dev/null || rollback_failed=1
    fi
  done
  systemctl daemon-reload || rollback_failed=1
  cleanup_install_files || rollback_failed=1
  if ((rollback_failed)); then
    echo "cutover asset installation failed and rollback needs operator attention" >&2
  else
    echo "cutover asset installation failed; previous managed assets were restored" >&2
  fi
  ((original_status != 0)) || original_status=1
  exit "$original_status"
}
trap rollback_install ERR EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

# Stage and validate every managed asset before replacing any published path.
for ((index=0; index<${#sources[@]}; index++)); do
  target=${targets[index]}
  stage="${target}.lmm-install-$$.new"
  backup="${target}.lmm-install-$$.old"
  [[ ! -e $stage && ! -L $stage && ! -e $backup && ! -L $backup ]] || false
  install -m "${modes[index]}" -o "$expected_owner" -g "$expected_group" "${sources[index]}" "$stage"
  sync -f "$stage"
  cmp -s "${sources[index]}" "$stage"
  [[ $(stat -c %u "$stage") == "$expected_owner" && $(stat -c %a "$stage") == "${modes[index]#0}" ]]
  staged[index]=$stage
  backups[index]=$backup
  prior[index]=0
  published[index]=0
done
for ((link_index=0; link_index<${#link_names[@]}; link_index++)); do
  index=$((${#sources[@]} + link_index))
  target=${targets[index]}
  stage="${target}.lmm-install-$$.new"
  backup="${target}.lmm-install-$$.old"
  [[ ! -e $stage && ! -L $stage && ! -e $backup && ! -L $backup ]] || false
  ln -s -- "${link_values[link_index]}" "$stage"
  [[ -L $stage && $(readlink "$stage") == "${link_values[link_index]}" ]]
  sync -f "${target%/*}"
  staged[index]=$stage
  backups[index]=$backup
  prior[index]=0
  published[index]=0
done

# Preserve exact previous type/content/mode beside each target on the same
# filesystem, then atomically publish each already-validated staged asset.
for ((index=0; index<${#targets[@]}; index++)); do
  target=${targets[index]}
  if [[ -e $target || -L $target ]]; then
    [[ -f $target || -L $target ]] || false
    cp -a -- "$target" "${backups[index]}"
    [[ -L ${backups[index]} ]] || sync -f "${backups[index]}"
    sync -f "${target%/*}"
    prior[index]=1
  fi
done

publish_count=0
for ((index=0; index<${#targets[@]}; index++)); do
  target=${targets[index]}
  published[index]=1
  mv -Tf -- "${staged[index]}" "$target"
  sync -f "${target%/*}"
  publish_count=$((publish_count + 1))
  [[ ${LMM_CUTOVER_INSTALL_FAIL_AT:-} != "publish-$publish_count" ]] || false
done

systemctl daemon-reload
systemctl enable "${enabled_units[@]}"
cleanup_install_files
trap - ERR EXIT INT TERM
echo "Installed cutover assets and boot reconciliation gate. Populate candidate env, migration.env, cutover.conf, and a fresh admin canary token before dry-run."
