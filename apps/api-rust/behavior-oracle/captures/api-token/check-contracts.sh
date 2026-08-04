#!/usr/bin/env bash
set -euo pipefail
dir=$(cd -- "$(dirname -- "$0")" && pwd)
jq -e '
  .source.listener == "real Go listener" and
  (.contracts | length == 9) and
  ([.contracts[].id] | unique | length == 9) and
  all(.contracts[]; (.response.status | type == "number") and
    (.response.headers | has("content-type")) and
    (.postgresql | keys == ["deleted", "inserted", "updated"]) and
    (.valkey | keys == ["added", "changed", "removed"]) and
    (.cases | keys == ["auth", "dependency", "input", "replay"])) and
  (tostring | contains("<REDACTED_TOKEN_KEY>")) and
  (tostring | test("eyJ[a-zA-Z0-9_-]+\\."; "i") | not)
' "$dir/contracts.json" >/dev/null
echo 'api-token behavior contracts valid: 9 routes'
