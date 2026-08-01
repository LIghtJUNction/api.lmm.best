#!/usr/bin/env bash
set -Eeuo pipefail

for command_name in awk cmp find git jq mktemp sha256sum sort; do
  command -v "${command_name}" >/dev/null || {
    echo "required provenance command is missing: ${command_name}" >&2
    exit 1
  }
done

crate_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
repo_root=$(cd -- "${crate_dir}/../../.." && pwd)
schema_provenance="${crate_dir}/schema/provenance.json"
verification_tmp=$(mktemp -d "${TMPDIR:-/tmp}/lmm-provenance.XXXXXX")

cleanup() {
  case "${verification_tmp}" in
    "${TMPDIR:-/tmp}"/lmm-provenance.*)
      rm -rf -- "${verification_tmp}"
      ;;
  esac
}
trap cleanup EXIT

fail() {
  echo "provenance verification failed: $*" >&2
  exit 1
}

assert_equal() {
  local actual=$1
  local expected=$2
  local label=$3
  [[ "${actual}" == "${expected}" ]] ||
    fail "${label}: expected ${expected}, got ${actual}"
}

hash_file() {
  sha256sum "$1" | awk '{print $1}'
}

schema_path() {
  local relative_path
  relative_path=$(jq -er "$1" "${schema_provenance}")
  printf '%s/%s\n' "${repo_root}" "${relative_path}"
}

legacy_provenance=$(schema_path '.legacy_source.provenance')
go_manifest=$(schema_path '.legacy_source.go_source_manifest')
contract_manifest=$(schema_path '.legacy_source.contract_assets_manifest')

[[ -f "${legacy_provenance}" ]] || fail "missing ${legacy_provenance}"
[[ -f "${go_manifest}" ]] || fail "missing ${go_manifest}"
[[ -f "${contract_manifest}" ]] || fail "missing ${contract_manifest}"

expected=$(jq -er '.legacy_source.provenance_sha256' "${schema_provenance}")
assert_equal "$(hash_file "${legacy_provenance}")" "${expected}" \
  "legacy provenance hash"

legacy_revision=$(jq -er '.legacy_revision.commit' "${legacy_provenance}")
assert_equal "${legacy_revision}" \
  "$(jq -er '.legacy_source.revision' "${schema_provenance}")" \
  "legacy revision linkage"
assert_equal "$(git -C "${repo_root}" cat-file -t "${legacy_revision}")" commit \
  "legacy revision object type"
assert_equal \
  "$(git -C "${repo_root}" cat-file commit "${legacy_revision}" | sha256sum | awk '{print $1}')" \
  "$(jq -er '.legacy_revision.commit_content_sha256' "${legacy_provenance}")" \
  "legacy commit content hash"

legacy_tree=$(git -C "${repo_root}" rev-parse "${legacy_revision}^{tree}")
assert_equal "${legacy_tree}" \
  "$(jq -er '.legacy_revision.tree' "${legacy_provenance}")" \
  "legacy tree object"
assert_equal \
  "$(git -C "${repo_root}" cat-file tree "${legacy_tree}" | sha256sum | awk '{print $1}')" \
  "$(jq -er '.legacy_revision.tree_content_sha256' "${legacy_provenance}")" \
  "legacy tree content hash"
assert_equal "$(git -C "${repo_root}" rev-parse --show-object-format)" \
  "$(jq -er '.legacy_revision.git_object_format' "${legacy_provenance}")" \
  "Git object format"

go_manifest_hash=$(hash_file "${go_manifest}")
assert_equal "${go_manifest_hash}" \
  "$(jq -er '.archive.manifest_sha256' "${legacy_provenance}")" \
  "Go source manifest hash"
assert_equal "${go_manifest_hash}" \
  "$(jq -er '.legacy_source.go_source_manifest_sha256' "${schema_provenance}")" \
  "schema Go source manifest hash"

expected_header=$'scope\tpath\tmode\tgit_blob\tbytes\tsha256'
IFS= read -r actual_header < "${go_manifest}"
assert_equal "${actual_header}" "${expected_header}" "Go source manifest header"

git -C "${repo_root}" ls-tree -r --name-only "${legacy_revision}" |
  awk '/\.go$/ || /(^|\/)go\.(mod|sum)$/' |
  LC_ALL=C sort > "${verification_tmp}/selected-go-paths"
awk -F '\t' 'NR > 1 {print $2}' "${go_manifest}" > \
  "${verification_tmp}/manifest-go-paths"
cmp -s "${verification_tmp}/selected-go-paths" \
  "${verification_tmp}/manifest-go-paths" ||
  fail "Go source manifest does not exactly cover the archive selection"

: > "${verification_tmp}/all-content"
: > "${verification_tmp}/model-all-content"
: > "${verification_tmp}/model-runtime-content"
: > "${verification_tmp}/module-content"
: > "${verification_tmp}/root-module-content"

declare -A seen_go_paths=()
archive_count=0
archive_bytes=0
model_all_count=0
model_all_bytes=0
model_runtime_count=0
model_runtime_bytes=0
module_count=0
module_bytes=0

while IFS=$'\t' read -r scope source_path expected_mode expected_blob \
  expected_bytes expected_sha256 extra; do
  [[ -z "${extra:-}" ]] || fail "unexpected Go manifest columns for ${source_path}"
  [[ -n "${source_path}" ]] || fail "empty path in Go source manifest"
  [[ -z "${seen_go_paths[${source_path}]:-}" ]] ||
    fail "duplicate Go source manifest path: ${source_path}"
  seen_go_paths["${source_path}"]=1

  tree_entry=$(git -C "${repo_root}" ls-tree "${legacy_revision}" -- "${source_path}")
  [[ -n "${tree_entry}" ]] || fail "missing Git tree entry: ${source_path}"
  tree_metadata=${tree_entry%%$'\t'*}
  read -r actual_mode actual_type actual_blob <<< "${tree_metadata}"
  assert_equal "${actual_mode}" "${expected_mode}" "Git mode for ${source_path}"
  assert_equal "${actual_type}" blob "Git object type for ${source_path}"
  assert_equal "${actual_blob}" "${expected_blob}" "Git blob for ${source_path}"
  assert_equal "$(git -C "${repo_root}" cat-file -s "${actual_blob}")" \
    "${expected_bytes}" "byte count for ${source_path}"
  actual_sha256=$(git -C "${repo_root}" cat-file blob "${actual_blob}" |
    sha256sum | awk '{print $1}')
  assert_equal "${actual_sha256}" "${expected_sha256}" \
    "content hash for ${source_path}"

  expected_scope=go-source
  if [[ "${source_path}" =~ ^model/[^/]+\.go$ ]]; then
    expected_scope=model-go
  fi
  case "${source_path}" in
    go.mod|go.sum|relaykit/go.mod|relaykit/go.sum)
      expected_scope=module-input
      ;;
  esac
  assert_equal "${scope}" "${expected_scope}" "scope for ${source_path}"

  printf '%s  %s\n' "${actual_sha256}" "${source_path}" >> \
    "${verification_tmp}/all-content"
  archive_count=$((archive_count + 1))
  archive_bytes=$((archive_bytes + expected_bytes))

  if [[ "${source_path}" =~ ^model/[^/]+\.go$ ]]; then
    printf '%s  %s\n' "${actual_sha256}" "${source_path}" >> \
      "${verification_tmp}/model-all-content"
    model_all_count=$((model_all_count + 1))
    model_all_bytes=$((model_all_bytes + expected_bytes))
    if [[ "${source_path}" != *_test.go ]]; then
      printf '%s  %s\n' "${actual_sha256}" "${source_path}" >> \
        "${verification_tmp}/model-runtime-content"
      model_runtime_count=$((model_runtime_count + 1))
      model_runtime_bytes=$((model_runtime_bytes + expected_bytes))
    fi
  fi

  case "${source_path}" in
    go.mod|go.sum|relaykit/go.mod|relaykit/go.sum)
      printf '%s  %s\n' "${actual_sha256}" "${source_path}" >> \
        "${verification_tmp}/module-content"
      module_count=$((module_count + 1))
      module_bytes=$((module_bytes + expected_bytes))
      ;;
  esac
  case "${source_path}" in
    go.mod|go.sum)
      printf '%s  %s\n' "${actual_sha256}" "${source_path}" >> \
        "${verification_tmp}/root-module-content"
      ;;
  esac
done < <(tail -n +2 "${go_manifest}")

assert_equal "${archive_count}" "$(jq -er '.archive.file_count' "${legacy_provenance}")" \
  "archive file count"
assert_equal "${archive_bytes}" "$(jq -er '.archive.byte_count' "${legacy_provenance}")" \
  "archive byte count"
assert_equal "$(hash_file "${verification_tmp}/all-content")" \
  "$(jq -er '.archive.content_aggregate_sha256' "${legacy_provenance}")" \
  "archive content aggregate"
assert_equal "${model_all_count}" \
  "$(jq -er '.subsets.model_go_all.file_count' "${legacy_provenance}")" \
  "model Go file count"
assert_equal "${model_all_bytes}" \
  "$(jq -er '.subsets.model_go_all.byte_count' "${legacy_provenance}")" \
  "model Go byte count"
assert_equal "$(hash_file "${verification_tmp}/model-all-content")" \
  "$(jq -er '.subsets.model_go_all.content_aggregate_sha256' "${legacy_provenance}")" \
  "model Go content aggregate"
assert_equal "${model_runtime_count}" \
  "$(jq -er '.subsets.model_go_runtime.file_count' "${legacy_provenance}")" \
  "runtime model Go file count"
assert_equal "${model_runtime_bytes}" \
  "$(jq -er '.subsets.model_go_runtime.byte_count' "${legacy_provenance}")" \
  "runtime model Go byte count"
model_runtime_aggregate=$(hash_file "${verification_tmp}/model-runtime-content")
assert_equal "${model_runtime_aggregate}" \
  "$(jq -er '.subsets.model_go_runtime.content_aggregate_sha256' "${legacy_provenance}")" \
  "runtime model Go content aggregate"
assert_equal "${module_count}" \
  "$(jq -er '.subsets.module_inputs.file_count' "${legacy_provenance}")" \
  "Go module input count"
assert_equal "${module_bytes}" \
  "$(jq -er '.subsets.module_inputs.byte_count' "${legacy_provenance}")" \
  "Go module input byte count"
assert_equal "$(hash_file "${verification_tmp}/module-content")" \
  "$(jq -er '.subsets.module_inputs.content_aggregate_sha256' "${legacy_provenance}")" \
  "Go module content aggregate"
root_module_aggregate=$(hash_file "${verification_tmp}/root-module-content")
assert_equal "${root_module_aggregate}" \
  "$(jq -er '.subsets.root_module_inputs.content_aggregate_sha256' "${legacy_provenance}")" \
  "root Go module content aggregate"

assert_equal "${model_runtime_aggregate}" \
  "$(jq -er '.generator_inputs.model_go_aggregate_sha256' "${schema_provenance}")" \
  "PostgreSQL baseline model input"
assert_equal "${root_module_aggregate}" \
  "$(jq -er '.generator_inputs.go_module_aggregate_sha256' "${schema_provenance}")" \
  "PostgreSQL baseline Go module input"

contract_manifest_hash=$(hash_file "${contract_manifest}")
assert_equal "${contract_manifest_hash}" \
  "$(jq -er '.frozen_contracts.manifest_sha256' "${legacy_provenance}")" \
  "contract asset manifest hash"
assert_equal "${contract_manifest_hash}" \
  "$(jq -er '.legacy_source.contract_assets_manifest_sha256' "${schema_provenance}")" \
  "schema contract asset manifest hash"

expected_header=$'source_path\tfrozen_path\tmode\tgit_blob\tbytes\tsha256'
IFS= read -r actual_header < "${contract_manifest}"
assert_equal "${actual_header}" "${expected_header}" "contract asset manifest header"

{
  printf '%s\n' \
    common/limiter/lua/rate_limit.lua \
    i18n/locales/en.yaml \
    i18n/locales/zh-CN.yaml \
    i18n/locales/zh-TW.yaml \
    pkg/billingexpr/expr.md \
    relaykit/README.md
  git -C "${repo_root}" ls-tree -r --name-only "${legacy_revision}" -- \
    relaykit/relayconvert/testdata/golden
} | LC_ALL=C sort > "${verification_tmp}/selected-contract-paths"
awk -F '\t' 'NR > 1 {print $1}' "${contract_manifest}" |
  LC_ALL=C sort > "${verification_tmp}/manifest-contract-paths"
cmp -s "${verification_tmp}/selected-contract-paths" \
  "${verification_tmp}/manifest-contract-paths" ||
  fail "contract manifest does not exactly cover the selected compatibility assets"

: > "${verification_tmp}/contract-content"
declare -A seen_contract_sources=()
declare -A seen_contract_targets=()
contract_count=0
contract_bytes=0
golden_count=0

while IFS=$'\t' read -r source_path frozen_path expected_mode expected_blob \
  expected_bytes expected_sha256 extra; do
  [[ -z "${extra:-}" ]] || fail "unexpected contract manifest columns for ${source_path}"
  [[ -z "${seen_contract_sources[${source_path}]:-}" ]] ||
    fail "duplicate contract source: ${source_path}"
  [[ -z "${seen_contract_targets[${frozen_path}]:-}" ]] ||
    fail "duplicate frozen contract target: ${frozen_path}"
  seen_contract_sources["${source_path}"]=1
  seen_contract_targets["${frozen_path}"]=1
  case "${frozen_path}" in
    rust/contracts/legacy/*|rust/fixtures/legacy-relayconvert/*) ;;
    *) fail "contract target escapes approved roots: ${frozen_path}" ;;
  esac

  tree_entry=$(git -C "${repo_root}" ls-tree "${legacy_revision}" -- "${source_path}")
  [[ -n "${tree_entry}" ]] || fail "missing contract Git tree entry: ${source_path}"
  tree_metadata=${tree_entry%%$'\t'*}
  read -r actual_mode actual_type actual_blob <<< "${tree_metadata}"
  assert_equal "${actual_mode}" "${expected_mode}" "Git mode for ${source_path}"
  assert_equal "${actual_type}" blob "Git object type for ${source_path}"
  assert_equal "${actual_blob}" "${expected_blob}" "Git blob for ${source_path}"
  assert_equal "$(git -C "${repo_root}" cat-file -s "${actual_blob}")" \
    "${expected_bytes}" "byte count for ${source_path}"
  actual_sha256=$(git -C "${repo_root}" cat-file blob "${actual_blob}" |
    sha256sum | awk '{print $1}')
  assert_equal "${actual_sha256}" "${expected_sha256}" \
    "source contract hash for ${source_path}"
  [[ -f "${repo_root}/${frozen_path}" ]] || fail "missing frozen contract: ${frozen_path}"
  assert_equal "$(hash_file "${repo_root}/${frozen_path}")" "${expected_sha256}" \
    "frozen contract hash for ${frozen_path}"

  printf '%s  %s -> %s\n' "${actual_sha256}" "${source_path}" "${frozen_path}" >> \
    "${verification_tmp}/contract-content"
  contract_count=$((contract_count + 1))
  contract_bytes=$((contract_bytes + expected_bytes))
  if [[ "${source_path}" == relaykit/relayconvert/testdata/golden/*.golden.json ]]; then
    golden_count=$((golden_count + 1))
  fi
done < <(tail -n +2 "${contract_manifest}")

assert_equal "${contract_count}" \
  "$(jq -er '.frozen_contracts.file_count' "${legacy_provenance}")" \
  "frozen contract count"
assert_equal "${contract_bytes}" \
  "$(jq -er '.frozen_contracts.byte_count' "${legacy_provenance}")" \
  "frozen contract byte count"
assert_equal "$(hash_file "${verification_tmp}/contract-content")" \
  "$(jq -er '.frozen_contracts.content_aggregate_sha256' "${legacy_provenance}")" \
  "frozen contract content aggregate"
assert_equal "${golden_count}" \
  "$(jq -er '.frozen_contracts.relayconvert_golden_count' "${legacy_provenance}")" \
  "RelayKit golden fixture count"
actual_golden_count=$(find "${repo_root}/rust/fixtures/legacy-relayconvert/golden" \
  -type f -name '*.golden.json' -print | wc -l | awk '{print $1}')
assert_equal "${actual_golden_count}" "${golden_count}" \
  "copied RelayKit golden fixture count"

for artifact in export-postgres-catalog.sql postgresql-baseline.sql table-map.json; do
  expected=$(jq -er --arg artifact "${artifact}" '.artifacts[$artifact]' \
    "${schema_provenance}")
  actual=$(hash_file "${crate_dir}/schema/${artifact}")
  assert_equal "${actual}" "${expected}" "migration artifact hash for ${artifact}"
done

echo "migration provenance, Git objects, and frozen contracts verified"
