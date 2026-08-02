#!/usr/bin/env bash
set -euo pipefail

repo_root=$(git rev-parse --show-toplevel)
checker="$repo_root/rust/scripts/check-behavior-deviations.sh"
ledger="$repo_root/rust/routes/behavior-deviations.tsv"
runtime=$(mktemp -d /tmp/lmm-behavior-deviations.XXXXXX)

cleanup() {
  rm -rf "$runtime"
}
trap cleanup EXIT

bash "$checker" >/dev/null

missing_test="$runtime/missing-test.tsv"
awk -F '\t' 'BEGIN { OFS=FS }
  NR == 1 { print; next }
  !changed { $7="rust/behavior-oracle/tests/does-not-exist.sh"; changed=1 }
  { print }
  END { if (!changed) exit 1 }
' "$ledger" >"$missing_test"
if BEHAVIOR_DEVIATIONS_PATH="$missing_test" bash "$checker" >/dev/null 2>&1; then
  echo "behavior deviation checker accepted a missing regression_test" >&2
  exit 1
fi

absolute_test="$runtime/absolute-test.tsv"
awk -F '\t' 'BEGIN { OFS=FS }
  NR == 1 { print; next }
  !changed { $7="/etc/passwd"; changed=1 }
  { print }
  END { if (!changed) exit 1 }
' "$ledger" >"$absolute_test"
if BEHAVIOR_DEVIATIONS_PATH="$absolute_test" bash "$checker" >/dev/null 2>&1; then
  echo "behavior deviation checker accepted an absolute regression_test path" >&2
  exit 1
fi

invalid_status="$runtime/invalid-status.tsv"
awk -F '\t' 'BEGIN { OFS=FS }
  NR == 1 { print; next }
  !changed { $8="unreviewed"; changed=1 }
  { print }
  END { if (!changed) exit 1 }
' "$ledger" >"$invalid_status"
if BEHAVIOR_DEVIATIONS_PATH="$invalid_status" bash "$checker" >/dev/null 2>&1; then
  echo "behavior deviation checker accepted an invalid status" >&2
  exit 1
fi

echo "behavior deviation checker tests passed"
