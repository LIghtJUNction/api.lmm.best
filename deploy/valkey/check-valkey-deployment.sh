#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
DEPLOYER="$SCRIPT_DIR/deploy-valkey-lmm-api.sh"
CONFIG="$SCRIPT_DIR/lmm-api.conf"
UNIT="$SCRIPT_DIR/valkey-lmm-api.service"
SYSCTL_CONFIG="$SCRIPT_DIR/70-valkey-lmm-api.conf"
TMPFILES_CONFIG="$SCRIPT_DIR/valkey-lmm-api.tmpfiles.conf"

fail() { printf 'check-valkey-deployment: %s\n' "$*" >&2; exit 1; }
expect_line() { grep -Fxq -- "$1" "$2" || fail "missing '$1' in $(basename "$2")"; }

bash -n "$DEPLOYER" "$0"
if command -v shellcheck >/dev/null; then
  shellcheck "$DEPLOYER" "$0" "$SCRIPT_DIR/test-restore-behavior.sh"
fi
if command -v systemd-analyze >/dev/null; then
  systemd-analyze verify "$UNIT"
fi

expect_line 'bind 127.0.0.1 -::1' "$CONFIG"
expect_line 'protected-mode yes' "$CONFIG"
expect_line 'port 6380' "$CONFIG"
expect_line 'maxmemory 64mb' "$CONFIG"
expect_line 'maxmemory-policy noeviction' "$CONFIG"
expect_line 'appendonly yes' "$CONFIG"
expect_line 'appendfsync everysec' "$CONFIG"
expect_line 'MemoryMax=112M' "$UNIT"
expect_line 'MemorySwapMax=32M' "$UNIT"
expect_line 'vm.overcommit_memory = 1' "$SYSCTL_CONFIG"
expect_line 'w /sys/kernel/mm/transparent_hugepage/enabled - - - - madvise' "$TMPFILES_CONFIG"

grep -Fq "ss -ltnH 'sport = :6379'" "$DEPLOYER" || fail 'protected 6379 invariant is absent'
grep -Fq "restore_transaction \"\$RESTORE_ON_EXIT\"" "$DEPLOYER" || fail 'automatic restore is absent'
grep -Fq "systemctl stop \"\$SERVICE\"" "$DEPLOYER" || fail 'rollback does not stop before restore'
grep -Fq "restore_kernel_state \"\$backup_dir\"" "$DEPLOYER" || fail 'rollback does not restore runtime kernel state'
grep -Fq 'valkey-server --check-system' "$DEPLOYER" || fail 'Valkey system preflight is absent'
grep -Fq "if ! overcommit=\"\$(sysctl -n vm.overcommit_memory)\"" "$DEPLOYER" || fail 'overcommit capture does not check command failure'
grep -Fq "if ! thp=\"\$(current_thp_mode)\"" "$DEPLOYER" || fail 'THP capture does not check command failure'
grep -Fq "mv -fT -- \"\$kernel_state_tmp\" \"\$backup_dir/kernel-state\"" "$DEPLOYER" || fail 'kernel metadata is not atomically published'
grep -Fq "mv -fT -- \"\$manifest_tmp\" \"\$backup_dir/manifest\"" "$DEPLOYER" || fail 'backup manifest is not published last and atomically'
restore_body="$(sed -n '/^restore_transaction()/,/^}/p' "$DEPLOYER")"
grep -Fq ') || restore_status=$?' <<<"$restore_body" || fail 'restore failure is not captured independently'
grep -Fq '(assert_existing_untouched) || invariant_status=$?' <<<"$restore_body" || fail '6379 invariant is not checked independently after restore'
grep -Fq "return \"\$restore_status\"" <<<"$restore_body" || fail 'primary restore failure is not preserved'
"$SCRIPT_DIR/test-restore-behavior.sh"
install_branch="$(sed -n '/^[[:space:]]*install)$/,/^[[:space:]]*;;$/p' "$DEPLOYER")"
rollback_branch="$(sed -n '/^[[:space:]]*rollback)/p' "$DEPLOYER")"
grep -Fq 'capture_dedicated_state' <<<"$install_branch" || fail 'install does not validate the current dedicated-unit state'
if grep -Fq 'capture_dedicated_state' <<<"$rollback_branch"; then
  fail 'rollback incorrectly depends on the current dedicated-unit state'
fi
grep -Fq 'rollback_instance' <<<"$rollback_branch" || fail 'rollback dispatch is missing'
if grep -Fq 'enable --now' "$DEPLOYER"; then
  fail 'redundant enable --now remains'
fi

valid_id='20260801T010203Z-123456789-a1b2c3d4e5f60708'
invalid_ids=(
  '20260801T010203Z'
  '../20260801T010203Z-123456789-a1b2c3d4e5f60708'
  '20260801T010203Z-12345678-a1b2c3d4e5f60708'
  '20260801T010203Z-123456789-A1B2C3D4E5F60708'
)
regex='^[0-9]{8}T[0-9]{6}Z-[0-9]{9}-[0-9a-f]{16}$'
[[ "$valid_id" =~ $regex ]] || fail 'valid backup ID rejected by test regex'
for invalid_id in "${invalid_ids[@]}"; do
  [[ ! "$invalid_id" =~ $regex ]] || fail "unsafe backup ID accepted: $invalid_id"
done

printf 'check-valkey-deployment: OK\n'
