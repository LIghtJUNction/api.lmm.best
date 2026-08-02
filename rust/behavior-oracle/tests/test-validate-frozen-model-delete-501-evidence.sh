#!/usr/bin/env bash
set -euo pipefail

repo_root=$(git rev-parse --show-toplevel)
validator="$repo_root/rust/behavior-oracle/tests/validate-frozen-model-delete-501-evidence.sh"
runtime=$(mktemp -d "${TMPDIR:-/tmp}/lmm-frozen-501-evidence.XXXXXX")
trap 'rm -rf "$runtime"' EXIT

write_evidence() {
  local target=$1 auth_case=$2 owner=${3:-'github.com/QuantumNous/new-api/controller.RelayNotImplemented'}
  jq -n --arg auth_case "$auth_case" --arg owner "$owner" '
    {
      test:"frozen-model-delete-501-tcp-differential",
      approval_credit:true,
      transport:"tcp",
      auth_case:$auth_case,
      route:{method:"DELETE",frozen_path:"/v1/models/:model",normalized_rust_path:"/v1/models/{model}",legacy_handler:$owner},
      go_listener:"http://127.0.0.1:18081",
      rust_listener:"http://127.0.0.1:18082",
      go:{status:501,content_type:"application/json",body_sha256:"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"},
      rust:{status:501,content_type:"application/json",body_sha256:"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"},
      status_body_parity:true
    }
  ' >"$target"
}

valid="$runtime/valid.json"
write_evidence "$valid" valid-token
bash "$validator" "$valid" >/dev/null

anonymous="$runtime/anonymous.json"
write_evidence "$anonymous" transport-anonymous
if bash "$validator" "$anonymous" >/dev/null 2>&1; then
  echo "validator accepted anonymous evidence" >&2
  exit 1
fi

wrong_owner="$runtime/wrong-owner.json"
write_evidence "$wrong_owner" valid-token 'controller.RelayNotImplemented'
if bash "$validator" "$wrong_owner" >/dev/null 2>&1; then
  echo "validator accepted a non-exact Go owner" >&2
  exit 1
fi

wrong_body="$runtime/wrong-body.json"
write_evidence "$wrong_body" valid-token
jq '.rust.body_sha256 = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"' "$wrong_body" >"$wrong_body.next"
mv "$wrong_body.next" "$wrong_body"
if bash "$validator" "$wrong_body" >/dev/null 2>&1; then
  echo "validator accepted status/body divergence" >&2
  exit 1
fi

echo "frozen DELETE 501 evidence validator tests passed"
