#!/usr/bin/env bash
set -euo pipefail

repo_root=$(git rev-parse --show-toplevel)
legacy="$repo_root/apps/api-rust/routes/legacy-go-routes.tsv"
deviations="${BEHAVIOR_DEVIATIONS_PATH:-$repo_root/apps/api-rust/routes/behavior-deviations.tsv}"
expected_header=$'method\tpath\tfield\tlegacy_behavior\trust_behavior\trationale\tregression_test\tstatus'

[[ -f "$deviations" ]] || { echo "missing behavior deviation ledger: $deviations" >&2; exit 1; }
[[ $(head -n 1 "$deviations") == "$expected_header" ]] || { echo "invalid behavior-deviations header" >&2; exit 1; }

awk -F '\t' '
  NR == FNR { legacy[$1 "\t" $2]=1; next }
  FNR == 1 { next }
  NF != 8 { printf "line %d: expected 8 tab-separated fields, got %d\n", FNR, NF > "/dev/stderr"; failed=1; next }
  !legacy[$1 "\t" $2] { printf "line %d: route is not in legacy manifest: %s %s\n", FNR, $1, $2 > "/dev/stderr"; failed=1 }
  $3 == "" || $4 == "" || $5 == "" || $6 == "" || $7 == "" { printf "line %d: deviation evidence fields must be non-empty\n", FNR > "/dev/stderr"; failed=1 }
  $8 !~ /^(accepted|temporary)$/ { printf "line %d: status must be accepted or temporary\n", FNR > "/dev/stderr"; failed=1 }
  { key=$1 "\t" $2 "\t" $3; if (seen[key]++) { printf "line %d: duplicate route field deviation\n", FNR > "/dev/stderr"; failed=1 } }
  END { exit failed }
' "$legacy" "$deviations"

while IFS=$'\t' read -r method path _ _ _ _ regression_test status; do
  [[ $method == method && $path == path ]] && continue
  case $regression_test in
    ''|/*|*'..'*)
      echo "invalid regression_test path for $method $path: $regression_test" >&2
      exit 1
      ;;
  esac
  [[ -f "$repo_root/$regression_test" ]] || {
    echo "missing regression_test for $method $path: $regression_test" >&2
    exit 1
  }
  case $status in
    accepted|temporary) ;;
    *)
      echo "invalid deviation status for $method $path: $status" >&2
      exit 1
      ;;
  esac
done <"$deviations"

echo "behavior deviation ledger valid"
