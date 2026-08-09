#!/usr/bin/env bash
# Regenerate the frozen legacy openAIModelsMap without adding Go to the Rust runtime.
set -euo pipefail

repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../../../../" && pwd)
legacy_revision=5418ce6b6d45ed69167b0aad53f2f595e5bc8de9
legacy_root=${LMM_GO_ORACLE_ROOT:-}
[[ -n $legacy_root ]] || { echo "LMM_GO_ORACLE_ROOT is required; set it to an absolute external immutable Go oracle tree ($legacy_revision)" >&2; exit 2; }
[[ $legacy_root == /* && -d $legacy_root && ! -L $legacy_root ]] || { echo 'LMM_GO_ORACLE_ROOT must be an absolute, non-symlink directory' >&2; exit 2; }
legacy_root=$(realpath -e -- "$legacy_root")
case "$legacy_root" in "$repo_root"|"$repo_root"/*) echo 'LMM_GO_ORACLE_ROOT must be external to the current repository' >&2; exit 2 ;; esac
runtime=$(mktemp -d "${TMPDIR:-/tmp}/lmm-go-oracle-catalog.XXXXXX")
cleanup() {
  case "$runtime" in "${TMPDIR:-/tmp}"/lmm-go-oracle-catalog.*) rm -rf -- "$runtime" ;; esac
}
trap cleanup EXIT
worktree="$runtime/go-source"
cp -a -- "$legacy_root/." "$worktree"
controller_dir="$worktree/controller"
output="$repo_root/apps/api-rust/assets/legacy-static-model-catalog.json"
test_file="$controller_dir/catalog_dump_generated_test.go"

if [[ -e "$test_file" ]]; then
  printf 'refusing to overwrite %s\n' "$test_file" >&2
  exit 1
fi

cat >"$test_file" <<'EOF'
package controller

import (
  "encoding/json"
  "os"
  "sort"
  "testing"
  "github.com/QuantumNous/new-api/relaykit/dto"
)

func TestDumpFrozenStaticModelCatalog(t *testing.T) {
  keys := make([]string, 0, len(openAIModelsMap))
  for key := range openAIModelsMap { keys = append(keys, key) }
  sort.Strings(keys)
  models := make([]dto.OpenAIModels, 0, len(keys))
  for _, key := range keys { models = append(models, openAIModelsMap[key]) }
  encoder := json.NewEncoder(os.Stdout)
  encoder.SetEscapeHTML(false)
  if err := encoder.Encode(models); err != nil { t.Fatal(err) }
}
EOF

mkdir -p -- "$(dirname -- "$output")"
cd -- "$worktree"
go test ./controller -run '^TestDumpFrozenStaticModelCatalog$' -count=1 -v 2>&1 \
  | sed -n '/^\[/{p;}' >"$output"

jq -e 'type == "array" and length > 0' "$output" >/dev/null
jq -S . "$output" >"$output.tmp"
mv -- "$output.tmp" "$output"
