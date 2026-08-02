#!/usr/bin/env bash
set -Eeuo pipefail

HERE=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
SCRIPT="$HERE/generate-release-metadata.sh"
[[ -f $SCRIPT && ! -L $SCRIPT ]] || { echo 'missing generator' >&2; exit 1; }
bash -n "$SCRIPT"

tmp=$(mktemp -d "${TMPDIR:-/tmp}/lmm-release-metadata-test.XXXXXXXX")
trap 'rm -rf -- "$tmp"' EXIT
for file in package api revision migrator baseline manifest catalog contract provenance oracle; do
  printf '%s' "$file" >"$tmp/$file"
done
printf '%s' abcdef123 >"$tmp/revision"
package_sha=$(sha256sum "$tmp/package" | awk '{print $1}')
args=(--revision abcdef123 --release-id abcdef123 --release-package "$tmp/package" --release-sha256 "$package_sha"
  --contract-id 1 --min-reader-version 1 --max-reader-version 1 --min-writer-version 1 --max-writer-version 1
  --output "$tmp/release-metadata.json" --api-server-binary "$tmp/api" --api-server-revision-file "$tmp/revision"
  --db-migrator-binary "$tmp/migrator" --postgresql-baseline "$tmp/baseline" --table-manifest "$tmp/manifest"
  --postgres-catalog-exporter "$tmp/catalog" --platform-contract-sql "$tmp/contract" --migration-provenance "$tmp/provenance"
  --legacy-route-oracle "$tmp/oracle")
"$SCRIPT" "${args[@]}" >/dev/null
[[ $(stat -c '%a' "$tmp/release-metadata.json") == 600 ]]
jq -e '.release_id == "abcdef123" and .release_sha256 == $sha and (.components | length) == 9 and .contract_sha256 == .components["platform-contract-sql"]' --arg sha "$package_sha" "$tmp/release-metadata.json" >/dev/null

bad_id=("${args[@]}")
for index in "${!bad_id[@]}"; do
  [[ ${bad_id[index]} == --release-id ]] && bad_id[index+1]=other-release
done
if "$SCRIPT" "${bad_id[@]}" >/dev/null 2>&1; then echo 'release id mismatch unexpectedly succeeded' >&2; exit 1; fi
bad_sha=("${args[@]}")
for index in "${!bad_sha[@]}"; do [[ ${bad_sha[index]} == "$package_sha" ]] && bad_sha[index]=$(printf '%064d' 0); done
if "$SCRIPT" "${bad_sha[@]}" >/dev/null 2>&1; then echo 'package hash mismatch unexpectedly succeeded' >&2; exit 1; fi
ln -s "$tmp/api" "$tmp/api-link"
link_args=("${args[@]}")
for index in "${!link_args[@]}"; do [[ ${link_args[index]} == "$tmp/api" ]] && link_args[index]="$tmp/api-link"; done
if "$SCRIPT" "${link_args[@]}" >/dev/null 2>&1; then echo 'symlink component unexpectedly succeeded' >&2; exit 1; fi
echo 'release metadata generator verified'
