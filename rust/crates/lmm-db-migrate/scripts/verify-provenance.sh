#!/usr/bin/env bash
set -Eeuo pipefail

for command in jq rg sha256sum; do
  command -v "${command}" >/dev/null || {
    echo "required provenance command is missing: ${command}" >&2
    exit 1
  }
done

crate_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
repo_root=$(cd -- "${crate_dir}/../../.." && pwd)
provenance="${crate_dir}/schema/provenance.json"

expected_model=$(jq -er '.generator_inputs.model_go_aggregate_sha256' "${provenance}")
actual_model=$(
  cd -- "${repo_root}"
  rg --files model -g '*.go' -g '!*_test.go' |
    LC_ALL=C sort |
    xargs sha256sum |
    sha256sum |
    awk '{print $1}'
)

expected_module=$(jq -er '.generator_inputs.go_module_aggregate_sha256' "${provenance}")
actual_module=$(
  cd -- "${repo_root}"
  sha256sum go.mod go.sum | sha256sum | awk '{print $1}'
)

[[ "${actual_model}" == "${expected_model}" ]] || {
  echo "Go model inputs changed; regenerate and review the PostgreSQL baseline" >&2
  exit 1
}
[[ "${actual_module}" == "${expected_module}" ]] || {
  echo "Go module inputs changed; regenerate and review the PostgreSQL baseline" >&2
  exit 1
}

for artifact in export-postgres-catalog.sql postgresql-baseline.sql table-map.json; do
  expected=$(jq -er --arg artifact "${artifact}" '.artifacts[$artifact]' "${provenance}")
  actual=$(sha256sum "${crate_dir}/schema/${artifact}" | awk '{print $1}')
  [[ "${actual}" == "${expected}" ]] || {
    echo "migration artifact hash mismatch: ${artifact}" >&2
    exit 1
  }
done

echo "migration provenance hashes verified"
