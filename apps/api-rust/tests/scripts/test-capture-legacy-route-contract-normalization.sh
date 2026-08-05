#!/usr/bin/env bash
# A declared JSON normalization path may be absent because an error body is raw text.
set -euo pipefail

repo_root=$(git rev-parse --show-toplevel)
runtime=$(mktemp -d /tmp/lmm-capture-normalization.XXXXXX)
cleanup() { rm -rf "$runtime"; }
trap cleanup EXIT

mkdir -p "$runtime/bin"
cat >"$runtime/bin/curl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
while (($#)); do
  case "$1" in
    --dump-header) headers=$2; shift 2 ;;
    --output) body=$2; shift 2 ;;
    *) shift ;;
  esac
done
printf 'HTTP/1.1 401 Unauthorized\r\nContent-Type: text/plain\r\n\r\n' >"$headers"
printf 'unauthorized' >"$body"
EOF
chmod +x "$runtime/bin/curl"

cat >"$runtime/request.json" <<'EOF'
{"route":{"id":"GET /synthetic"},"request":{"method":"GET","path":"/synthetic","headers":{},"body":null},"observe":{"db_tables":[],"valkey_patterns":[]},"capture_headers":["content-type"],"normalization":{"rules":[{"path":"$.response.body.error.message","operation":"regex_replace","pattern":"request id: [^)]+","replacement":"request id: <REQUEST_ID>"}]}}
EOF

PATH="$runtime/bin:$PATH" "$repo_root/apps/api-rust/tests/scripts/capture-legacy-route-contract.sh" \
  --base-url http://127.0.0.1:13017 --request "$runtime/request.json" --output "$runtime/fixture.json" >/dev/null
jq -e '.response.status == 401 and .response.body == "unauthorized"' "$runtime/fixture.json" >/dev/null
