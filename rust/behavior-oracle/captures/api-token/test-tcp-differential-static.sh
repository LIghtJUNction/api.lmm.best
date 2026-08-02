#!/usr/bin/env bash
# Fast, listener-free coverage guard for tcp-differential.sh.
set -euo pipefail
dir=$(cd -- "$(dirname -- "$0")" && pwd)
script=$dir/tcp-differential.sh
required=(
  disabled-user guest- invalid-identity- malformed-json wrong-field-type
  missing-content-type wrong-content-type bad-integer-query create-missing
  update-missing status-only-missing 'p=-1' 'size=-1' 'size=0' 'size=101'
  'p=wat' '%25%25' '%25%25b' 'keyword=a' '%E5%A4%9A%25' '%21%25' '%21_'
  x-oneapi-request-id token_snapshot matrix_no_effect matrix_effect
)
for needle in "${required[@]}"; do
  grep -Fq -- "$needle" "$script" || { echo "missing TCP oracle case/guard: $needle" >&2; exit 1; }
done
[[ $(grep -Ec '^matrix_(no_effect|effect) ' "$script") -ge 8 ]]
bash -n "$script"
echo 'api-token TCP differential static coverage: passed'
