#!/usr/bin/env bash
# Determinism and rejection tests for build-source-manifest.sh.
set -Eeuo pipefail

HERE=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
readonly SCRIPT="$HERE/build-source-manifest.sh"

die() {
  printf 'test-source-manifest: %s\n' "$*" >&2
  exit 1
}

[[ -x $SCRIPT && ! -L $SCRIPT ]] || die 'manifest builder is missing or not executable'
tmp=$(mktemp -d "${TMPDIR:-/tmp}/lmm-source-manifest-test.XXXXXXXX")
cleanup() { rm -rf -- "$tmp"; }
trap cleanup EXIT
root="$tmp/root"
mkdir -p "$root/declared" "$root/ignored"
printf '%s\n' alpha >"$root/declared/a.txt"
printf '%s\n' beta >"$root/declared/b.txt"
printf '%s\n' top >"$root/top.txt"
printf '%s\n' unrelated >"$root/ignored/unrelated.txt"
chmod 0644 "$root/declared/a.txt" "$root/top.txt"
chmod 0755 "$root/declared/b.txt"

run_manifest() {
  local output=$1 hash=$2
  shift 2
  bash "$SCRIPT" --root "$root" --output "$output" --sha256-output "$hash" "$@"
}

run_manifest "$tmp/one.tsv" "$tmp/one.sha" \
  --path declared --path top.txt
run_manifest "$tmp/two.tsv" "$tmp/two.sha" \
  --path top.txt --path declared
cmp -s "$tmp/one.tsv" "$tmp/two.tsv" || die 'input order changed manifest rows'
cmp -s "$tmp/one.sha" "$tmp/two.sha" || die 'input order changed aggregate SHA'
awk -F $'\t' 'NF != 3 || ($1 !~ /^declared\// && $1 !~ /^top[.]txt$/) || $2 !~ /^[0-9]{4}$/ || $3 !~ /^[0-9a-f]{64}$/ { exit 1 }' "$tmp/one.tsv" || \
  die 'manifest row format is invalid'

baseline=$(<"$tmp/one.sha")
printf '%s\n' changed >"$root/declared/a.txt"
run_manifest "$tmp/content.tsv" "$tmp/content.sha" --path declared --path top.txt
[[ $(<"$tmp/content.sha") != "$baseline" ]] || die 'content change did not change aggregate SHA'

printf '%s\n' beta >"$root/declared/b.txt"
chmod 0644 "$root/declared/b.txt"
run_manifest "$tmp/mode.tsv" "$tmp/mode.sha" --path declared --path top.txt
[[ $(<"$tmp/mode.sha") != $(<"$tmp/content.sha") ]] || die 'mode change did not change aggregate SHA'

cp "$tmp/mode.tsv" "$tmp/unrelated-before.tsv"
cp "$tmp/mode.sha" "$tmp/unrelated-before.sha"
printf '%s\n' another-unrelated >"$root/ignored/new.txt"
run_manifest "$tmp/unrelated-after.tsv" "$tmp/unrelated-after.sha" --path declared --path top.txt
cmp -s "$tmp/unrelated-before.tsv" "$tmp/unrelated-after.tsv" || die 'undeclared file changed manifest rows'
cmp -s "$tmp/unrelated-before.sha" "$tmp/unrelated-after.sha" || die 'undeclared file changed aggregate SHA'

ln -s a.txt "$root/declared/forbidden-link"
if run_manifest "$tmp/symlink.tsv" "$tmp/symlink.sha" --path declared --path top.txt; then
  die 'symlink input was accepted'
fi
rm -f "$root/declared/forbidden-link"

printf '%s\n' 'source manifest determinism contract verified'
