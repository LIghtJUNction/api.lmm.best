#!/usr/bin/env bash
set -Eeuo pipefail

repo=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
work=$(mktemp -d)
trap 'rm -rf -- "$work"' EXIT

make_build() {
  local name=$1 asset=$2 body=$3
  mkdir -p -- "$work/$name/static/js"
  printf '<script src="/static/js/%s"></script>\n' "$asset" >"$work/$name/index.html"
  printf '%s\n' "$body" >"$work/$name/static/js/$asset"
}

snapshot_store() {
  find "$work/root/assets" -printf '%y %P\n'
  find "$work/root/assets" -type f -exec sha256sum {} +
}

make_build first old.111.js old
make_build second new.222.js new

"$repo/deploy/frontend-release.sh" publish --root "$work/root" --source "$work/first" --release first --keep 2
"$repo/deploy/frontend-release.sh" publish --root "$work/root" --source "$work/second" --release second --keep 2

[[ $(readlink -- "$work/root/current") == releases/second ]]
[[ $(<"$work/root/assets/js/old.111.js") == old ]]
[[ $(<"$work/root/assets/js/new.222.js") == new ]]

# A browser holding the old index can still lazy-load its old hashed chunk.
grep -Fq '/static/js/old.111.js' "$work/root/releases/first/index.html"

"$repo/deploy/frontend-release.sh" rollback --root "$work/root" --release first --keep 2
[[ $(readlink -- "$work/root/current") == releases/first ]]

make_build collision old.111.js changed
printf 'new-before-conflict\n' >"$work/collision/static/js/aaa.000.js"
before_collision=$(snapshot_store | sort)
if "$repo/deploy/frontend-release.sh" publish --root "$work/root" --source "$work/collision" --release collision --keep 2 >"$work/out" 2>"$work/err"; then
  printf 'expected immutable asset collision to fail\n' >&2
  exit 1
fi
grep -Fq 'immutable asset collision with different content' "$work/err"
[[ $(readlink -- "$work/root/current") == releases/first ]]
[[ ! -e $work/root/releases/collision ]]
after_collision=$(snapshot_store | sort)
[[ $before_collision == "$after_collision" ]]

# A failure after one successful asset installation rolls back the whole batch.
make_build injected injected.333.js injected
mkdir -p "$work/injected/static/lazy/deep"
printf 'another\n' >"$work/injected/static/lazy/deep/another.444.js"
before_injected=$(snapshot_store | sort)
if LMM_FRONTEND_TEST_FAIL_AFTER_ASSETS=2 \
  "$repo/deploy/frontend-release.sh" publish --root "$work/root" --source "$work/injected" --release injected --keep 2 >"$work/out" 2>"$work/err"; then
  printf 'expected injected asset failure\n' >&2
  exit 1
fi
grep -Fq 'injected asset publish failure' "$work/err"
after_injected=$(snapshot_store | sort)
[[ $before_injected == "$after_injected" ]]
[[ $(readlink -- "$work/root/current") == releases/first ]]
[[ ! -e $work/root/releases/injected ]]

printf 'frontend release integration tests passed\n'
