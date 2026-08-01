#!/usr/bin/env bash
set -Eeuo pipefail
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
INSTALLER="$HERE/install-lmm-api-cutover.sh"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
ROOT="$TMP/root"
mkdir -p "$TMP/bin" "$TMP/systemctl-state"
printf '#!/usr/bin/env bash\nexit 0\n' >"$TMP/migrator"
chmod 0755 "$TMP/migrator"

cat >"$TMP/bin/systemctl" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
state=${LMM_TEST_SYSTEMCTL_STATE:?}
command=$1
shift
printf '%s %s\n' "$command" "$*" >>"$state/calls"
case $command in
  is-enabled)
    [[ ${1:-} == --quiet ]] && shift
    [[ -e $state/$1.enabled ]]
    ;;
  enable)
    count=0
    for unit in "$@"; do
      touch "$state/$unit.enabled"
      count=$((count + 1))
      if [[ ${LMM_TEST_SYSTEMCTL_FAIL_AT:-} == enable-once && $count == 1 && ! -e $state/enable-failed ]]; then
        touch "$state/enable-failed"
        exit 1
      fi
    done
    ;;
  disable)
    for unit in "$@"; do rm -f "$state/$unit.enabled"; done
    ;;
  daemon-reload)
    if [[ ${LMM_TEST_SYSTEMCTL_FAIL_AT:-} == daemon-reload-once && ! -e $state/daemon-failed ]]; then
      touch "$state/daemon-failed"
      exit 1
    fi
    ;;
  *) exit 2 ;;
esac
EOF
chmod 0755 "$TMP/bin/systemctl"

run_installer() {
  PATH="$TMP/bin:$PATH" LMM_CUTOVER_INSTALL_TEST_MODE=1 \
    LMM_CUTOVER_INSTALL_ROOT="$ROOT" LMM_TEST_SYSTEMCTL_STATE="$TMP/systemctl-state" \
    "$INSTALLER" --migrator "$TMP/migrator"
}

managed=(
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
  /usr/local/sbin/lmm-api-cutover
  /usr/local/sbin/lmm-api-prepare-cutover-env
)

snapshot() {
  local relative target
  for relative in "${managed[@]}"; do
    target="$ROOT$relative"
    if [[ -L $target ]]; then
      printf '%s symlink %s\n' "$relative" "$(readlink "$target")"
    elif [[ -f $target ]]; then
      printf '%s file %s %s\n' "$relative" "$(stat -c %a "$target")" \
        "$(sha256sum "$target" | awk '{print $1}')"
    else
      printf '%s missing\n' "$relative"
    fi
  done
  for unit in lmm-api-cutover-reconcile.service lmm-api-cutover-canary.service; do
    if [[ -e $TMP/systemctl-state/$unit.enabled ]]; then
      printf '%s enabled\n' "$unit"
    else
      printf '%s disabled\n' "$unit"
    fi
  done
}

run_installer >/dev/null
for relative in "${managed[@]}"; do
  [[ -e $ROOT$relative || -L $ROOT$relative ]]
done

# Make the prior installation observably different from the checked-in source;
# rollback must restore its bytes and mode, not merely reinstall current files.
printf 'prior managed cutover script\n' >"$ROOT/usr/lib/lmm-api-cutover/cutover-sqlite-to-pg.sh"
chmod 0701 "$ROOT/usr/lib/lmm-api-cutover/cutover-sqlite-to-pg.sh"
before=$(snapshot)
if LMM_CUTOVER_INSTALL_FAIL_AT=publish-3 run_installer >/dev/null 2>&1; then
  echo 'mid-publish installer fault succeeded' >&2; exit 1
fi
[[ $(snapshot) == "$before" ]]

rm -f "$TMP/systemctl-state/daemon-failed"
before=$(snapshot)
if LMM_TEST_SYSTEMCTL_FAIL_AT=daemon-reload-once run_installer >/dev/null 2>&1; then
  echo 'daemon-reload installer fault succeeded' >&2; exit 1
fi
[[ $(snapshot) == "$before" ]]

# Preserve a mixed prior enablement state across partial `systemctl enable`.
rm -f "$TMP/systemctl-state/lmm-api-cutover-reconcile.service.enabled"
touch "$TMP/systemctl-state/lmm-api-cutover-canary.service.enabled"
rm -f "$TMP/systemctl-state/enable-failed"
before=$(snapshot)
if LMM_TEST_SYSTEMCTL_FAIL_AT=enable-once run_installer >/dev/null 2>&1; then
  echo 'enable installer fault succeeded' >&2; exit 1
fi
[[ $(snapshot) == "$before" ]]

# Successful retry publishes one coherent set and enables both boot units.
run_installer >/dev/null
cmp -s "$HERE/cutover-sqlite-to-pg.sh" "$ROOT/usr/lib/lmm-api-cutover/cutover-sqlite-to-pg.sh"
[[ -e $TMP/systemctl-state/lmm-api-cutover-reconcile.service.enabled ]]
[[ -e $TMP/systemctl-state/lmm-api-cutover-canary.service.enabled ]]
[[ ! -e $ROOT/etc/lmm-api-cutover/cutover.conf ]]
[[ ! -e $ROOT/etc/lmm-api-cutover/migration.env ]]
[[ ! -e $ROOT/etc/lmm-api-cutover/admin-canary.token ]]
echo 'backend cutover transactional installer tests passed'
