#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
golden_hash_file="${repo_root}/rust/routes/go-routes.sha256"
generated="$(mktemp)"
contract="$(mktemp)"
trap 'rm -f "${generated}" "${contract}"' EXIT

(cd "${repo_root}" && go run ./cmd/route-manifest) >"${generated}"

route_count="$(wc -l <"${generated}")"
if (( route_count < 304 )); then
  echo "route manifest unexpectedly contains ${route_count} routes; expected at least 304" >&2
  exit 1
fi

for required in $'GET\t/v1/realtime\t' $'POST\t/:mode/mj/submit/imagine\t' $'GET\t/api/oauth/:provider\t'; do
  if ! grep -Fq "${required}" "${generated}"; then
    echo "route manifest is missing critical dynamic route: ${required}" >&2
    exit 1
  fi
done

awk -F '\t' '
  FNR == NR {
    if ($0 ~ /^#/ || NF == 0) next
    priority[++rules] = $1 + 0
    kind[rules] = $2
    pattern[rules] = $3
    matched[rules] = 0
    next
  }
  {
    path = $2
    best = -1
    winners = 0
    for (rule = 1; rule <= rules; rule++) {
      applies = (kind[rule] == "exact" && path == pattern[rule]) ||
                (kind[rule] == "prefix" && index(path, pattern[rule]) == 1)
      if (!applies) continue
      if (priority[rule] > best) {
        best = priority[rule]
        winners = 1
        winner = rule
      } else if (priority[rule] == best) {
        winners++
      }
    }
    if (winners == 0) {
      print "unmatched route ownership: " $1 " " path > "/dev/stderr"
      failures++
    } else if (winners > 1) {
      print "ambiguous route ownership at priority " best ": " $1 " " path > "/dev/stderr"
      failures++
    } else {
      matched[winner]++
      assigned++
    }
  }
  END {
    for (rule = 1; rule <= rules; rule++) {
      if (matched[rule] == 0) {
        print "ownership rule matches no routes: " kind[rule] " " pattern[rule] > "/dev/stderr"
        failures++
      }
    }
    if (assigned != 356) {
      print "ownership assigned " assigned " routes; expected 356" > "/dev/stderr"
      failures++
    }
    exit failures != 0
  }
' "${repo_root}/rust/routes/ownership.tsv" "${generated}"

expected_hash="$(awk 'NR == 1 { print $1 }' "${golden_hash_file}")"
{
  cat "${generated}"
  (cd "${repo_root}" && sha256sum router/*.go middleware/*.go | sort)
  cat "${repo_root}/rust/routes/ownership.tsv"
} >"${contract}"
actual_hash="$(sha256sum "${contract}" | awk '{ print $1 }')"
if [[ "${actual_hash}" != "${expected_hash}" ]]; then
  echo "expected route manifest hash ${expected_hash}, got ${actual_hash}" >&2
  echo "Go route surface changed; review ownership and update rust/routes/go-routes.sha256 deliberately" >&2
  exit 1
fi

echo "verified ${route_count} Go routes against the Rust migration baseline"
