#!/usr/bin/env bash
# shellcheck disable=SC1091,SC2034,SC2329
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=deploy-valkey-lmm-api.sh
source "$SCRIPT_DIR/deploy-valkey-lmm-api.sh"

fail() { printf 'test-restore-behavior: %s\n' "$*" >&2; exit 1; }

test_early_failure_preserves_status() (
  local kernel_called=0 unit_called=0 status
  read_unit_state() { RESTORE_ACTIVE='inactive'; RESTORE_ENABLED='enabled'; return 0; }
  systemctl() { return 0; }
  restore_managed_files() { return 23; }
  restore_kernel_state() { kernel_called=1; return 0; }
  restore_unit_state() { unit_called=1; return 0; }

  if restore_steps '/unused/mock-backup'; then
    fail 'early restore failure was reported as success'
  else
    status=$?
  fi
  [[ "$status" == 23 ]] || fail "first restore error was not preserved: $status"
  [[ "$kernel_called" == 0 ]] || fail 'unsafe later kernel restore ran after file restore failure'
  [[ "$unit_called" == 0 ]] || fail 'unsafe unit restore ran after file restore failure'
)

test_invariant_runs_after_restore_failure() (
  local marker status
  marker="$(mktemp)"
  rm -f -- "$marker"
  trap 'rm -f -- "$marker"' EXIT
  restore_steps() { return 29; }
  assert_existing_untouched() { : >"$marker"; return 0; }

  if restore_transaction '/unused/mock-backup'; then
    fail 'restore transaction hid the primary failure'
  else
    status=$?
  fi
  [[ "$status" == 29 ]] || fail "restore transaction lost the primary error: $status"
  [[ -e "$marker" ]] || fail '6379 invariant was skipped after restore failure'
)

test_internal_copy_failure_is_not_masked() (
  local backup marker status
  backup="$(mktemp -d)"
  marker="$backup/mv-called"
  trap 'rm -rf -- "$backup"' EXIT
  printf 'present %s\n' "$CONFIG" >"$backup/manifest"
  : >"$backup/$(basename "$CONFIG")"
  cp() { return 23; }
  mv() { : >"$marker"; return 0; }

  if restore_managed_files "$backup"; then
    fail 'internal cp failure was hidden by a later successful command'
  else
    status=$?
  fi
  [[ "$status" == 23 ]] || fail "internal cp error was not preserved: $status"
  [[ ! -e "$marker" ]] || fail 'mv ran after cp failed'
)

test_early_failure_preserves_status
test_invariant_runs_after_restore_failure
test_internal_copy_failure_is_not_masked
printf 'test-restore-behavior: OK\n'
