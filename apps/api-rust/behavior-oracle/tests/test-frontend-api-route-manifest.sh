#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
DEFAULT_MANIFEST_PATH="${SCRIPT_DIR}/frontend-api-route-manifest.tsv"
REPOSITORY_ROOT="$(cd -- "${SCRIPT_DIR}/../../../.." && pwd -P)"
manifest_path="${1:-${ROUTE_MANIFEST_PATH:-${DEFAULT_MANIFEST_PATH}}}"

if [[ -z "${manifest_path}" ]]; then
  echo "usage: $0 <manifest-file>" >&2
  exit 1
fi

if [[ ! -f "$manifest_path" ]]; then
  echo "ERROR: manifest file not found: $manifest_path" >&2
  exit 1
fi

missing_sources=0
while IFS= read -r frontend_source; do
  [[ -z "$frontend_source" || "$frontend_source" == "unresolved" ]] && continue
  if [[ "$frontend_source" = /* || ! -f "$REPOSITORY_ROOT/$frontend_source" ]]; then
    echo "ERROR: $manifest_path: frontend_source is not an existing repository-relative file: $frontend_source" >&2
    missing_sources=1
  fi
done < <(awk -F '\t' 'NR > 1 { print $1 }' "$manifest_path")

if (( missing_sources != 0 )); then
  exit 1
fi

awk -v path="$manifest_path" '
BEGIN {
  FS = "\t"
  expected_count = 10
  expected[1] = "frontend_source"
  expected[2] = "method"
  expected[3] = "frontend_path"
  expected[4] = "normalized_method_path"
  expected[5] = "legacy_go_present"
  expected[6] = "rust_candidate_present"
  expected[7] = "test_instance_mounted"
  expected[8] = "production_root_mounted"
  expected[9] = "risk"
  expected[10] = "notes"
}

function trim(s,   t) {
  t = s
  sub(/^[[:space:]]+/, "", t)
  sub(/[[:space:]]+$/, "", t)
  return t
}

function fail(msg,   line_number) {
  line_number = NR
  print "ERROR: " path ": line " line_number " " msg > "/dev/stderr"
  error_count++
}

function valid_boolean(v) {
  return v == "yes" || v == "no" || v == "unresolved"
}

function has_unresolved(v1, v2, v3, v4) {
  return v1 == "unresolved" || v2 == "unresolved" || v3 == "unresolved" || v4 == "unresolved"
}

function template_parameter(expression,   candidate, open) {
  candidate = expression
  open = match(candidate, /[A-Za-z_$][A-Za-z0-9_$]*\([^)]*\)/)
  if (open > 0) {
    candidate = substr(candidate, open)
    sub(/^[^(]*\(/, "", candidate)
    sub(/\).*$/, "", candidate)
  }
  if (match(candidate, /[A-Za-z_$][A-Za-z0-9_$]*$/) > 0) {
    candidate = substr(candidate, RSTART, RLENGTH)
  }
  return candidate
}

function expected_normalized(method, frontend_path,   route, query, start, template, expression, tail) {
  route = frontend_path
  query = index(route, "?")
  if (query > 0) route = substr(route, 1, query - 1)
  while ((start = index(route, "${")) > 0) {
    template = substr(route, start + 2)
    expression = template
    sub(/\}.*/, "", expression)
    tail = template
    sub(/^[^}]*/, "", tail)
    route = substr(route, 1, start - 1) ":" template_parameter(expression) substr(tail, 2)
  }
  return method " " route
}

{
  if (NF != expected_count) {
    fail("must contain exactly " expected_count " columns, got " NF)
    if (NR == 1) {
      exit 1
    }
    next
  }

  if (NR == 1) {
    for (i = 1; i <= expected_count; i++) {
      if (trim($i) != expected[i]) {
        fail("header mismatch at column " i ": \"" trim($i) "\" != \"" expected[i] "\"")
      }
    }
    if (error_count > 0) {
      exit 1
    }
    next
  }

  for (i = 1; i <= expected_count; i++) {
    cols[i] = trim($i)
    if (cols[i] == "") {
      fail("empty field in column " i)
    }
  }

  frontend_source = cols[1]
  frontend_path = cols[3]
  method = cols[2]
  normalized_method_path = cols[4]
  legacy_go_present = cols[5]
  rust_candidate_present = cols[6]
  test_instance_mounted = cols[7]
  production_root_mounted = cols[8]
  risk = cols[9]

  if (frontend_source != "unresolved" && substr(frontend_source, 1, 1) == "/") {
    fail("frontend_source must be a relative path, got absolute path: " frontend_source)
  }

  if (method !~ /^(GET|POST|PUT|PATCH|DELETE|HEAD|OPTIONS)$/) {
    fail("invalid method: " method)
  }

  if (normalized_method_path != expected_normalized(method, frontend_path)) {
    fail("normalized_method_path must equal normalized method + frontend path: expected " expected_normalized(method, frontend_path) ", got: " normalized_method_path)
  }

  if (!valid_boolean(legacy_go_present)) {
    fail("legacy_go_present must be one of yes/no/unresolved, got: " legacy_go_present)
  }

  if (!valid_boolean(rust_candidate_present)) {
    fail("rust_candidate_present must be one of yes/no/unresolved, got: " rust_candidate_present)
  }

  if (!valid_boolean(test_instance_mounted)) {
    fail("test_instance_mounted must be one of yes/no/unresolved, got: " test_instance_mounted)
  }

  if (!valid_boolean(production_root_mounted)) {
    fail("production_root_mounted must be one of yes/no/unresolved, got: " production_root_mounted)
  }

  if (risk != "high" && risk != "medium" && risk != "low") {
    fail("risk must be high, medium, or low, got: " risk)
  }

  if (legacy_go_present == "no" && rust_candidate_present == "no" && test_instance_mounted == "no" && risk != "high") {
    fail("risk must be high when legacy_go_present, rust_candidate_present, and test_instance_mounted are all no")
  }

  if (has_unresolved(legacy_go_present, rust_candidate_present, test_instance_mounted, production_root_mounted) && risk != "high") {
    fail("risk must be high when any status column is unresolved")
  }

  dedupe_key = cols[1] SUBSEP cols[2] SUBSEP cols[3]
  if (dedupe_key in seen) {
    fail("duplicate key: " dedupe_key)
  }
  seen[dedupe_key] = 1

  sort_key = cols[4] SUBSEP cols[1]
  if (NR > 2 && sort_key < prev_sort_key) {
    fail("manifest must be sorted by normalized_method_path then frontend_source")
  }
  prev_sort_key = sort_key
  data_count++
}

END {
  if (data_count == 0) {
    print "ERROR: " path ": manifest must contain at least one data row" > "/dev/stderr"
    error_count++
  }
  if (error_count > 0) {
    exit 1
  }
  print "ok: " path
}
' "$manifest_path"
