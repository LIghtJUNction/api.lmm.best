#!/usr/bin/env bash
# Shared authorization guard for the isolated fallback machine.  This is a
# machine identity, not a hostname check: hostnames are intentionally ignored.
set -Eeuo pipefail
umask 077

readonly LMM_RS_FALLBACK_MACHINE_ID_SHA256='a3efa7b252cfa806c67f09cdda170a737a90b6312c62fd1c7f642a9842d72794'

guard_die() {
  printf 'fallback-target-guard: %s\n' "$*" >&2
  exit 1
}

is_sha256() {
  [[ $1 =~ ^[0-9a-f]{64}$ ]]
}

expected_machine_hash=$LMM_RS_FALLBACK_MACHINE_ID_SHA256
machine_id_file=/etc/machine-id
if [[ ${LMM_RS_MOCK:-} == 1 ]]; then
  # Test overrides are deliberately unavailable to root.  A privileged
  # process must always use the checked-in build identity, even if an attacker
  # can set environment variables.
  [[ $EUID -ne 0 ]] || guard_die 'mock machine-identity overrides are non-root only'
  expected_machine_hash=${LMM_RS_GUARD_EXPECTED_MACHINE_ID_SHA256:-$expected_machine_hash}
  machine_id_file=${LMM_RS_GUARD_MACHINE_ID_FILE:-$machine_id_file}
fi

is_sha256 "$expected_machine_hash" || guard_die 'embedded machine identity is invalid'
[[ -f $machine_id_file && ! -L $machine_id_file ]] || guard_die 'machine identity file is unsafe or absent'
actual_machine_hash=$(sha256sum "$machine_id_file" | awk '{print $1}')
[[ $actual_machine_hash == "$expected_machine_hash" ]] || guard_die 'machine identity does not authorize this fallback operation'
