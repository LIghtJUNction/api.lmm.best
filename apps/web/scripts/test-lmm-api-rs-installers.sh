#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../../.." && pwd)
installer="$repo_root/apps/web/public/install.sh"
[[ -x $installer ]] || chmod +x "$installer"

fixture=$(mktemp -d "${TMPDIR:-/tmp}/lmm-api-rs-installer-test.XXXXXXXX")
cleanup() {
  rm -rf -- "$fixture"
}
trap cleanup EXIT

fake_bin="$fixture/bin"
system_path=$PATH
mkdir -p "$fake_bin"
real_tar=$(command -v tar)
real_sha256sum=$(command -v sha256sum)
real_awk=$(command -v awk)
real_install=$(command -v install)
real_mkdir=$(command -v mkdir)
real_mktemp=$(command -v mktemp)
real_rm=$(command -v rm)
real_uname=$(command -v uname)
for command_path in "$real_tar" "$real_sha256sum" "$real_awk" "$real_install" "$real_mkdir" "$real_mktemp" "$real_rm" "$real_uname"; do
  ln -s "$command_path" "$fake_bin/$(basename "$command_path")"
done

cargo_log="$fixture/cargo.log"
cat >"$fake_bin/cargo" <<'CARGO'
#!/bin/sh
set -eu
printf '%s\n' "$*" >"$CARGO_LOG"
root=
while [ "$#" -gt 0 ]; do
  if [ "$1" = --root ]; then
    root=$2
    shift 2
  else
    shift
  fi
done
[ -n "$root" ]
mkdir -p "$root/bin"
cat >"$root/bin/lmm-api-rs" <<'BINARY'
#!/bin/sh
[ "${1:-}" = doctor ] && exit 0
exit 2
BINARY
chmod +x "$root/bin/lmm-api-rs"
CARGO
chmod +x "$fake_bin/cargo"

cargo_destination="$fixture/cargo-destination"
CARGO_LOG="$cargo_log" PATH="$fake_bin:$system_path" HOME="$fixture/home" \
  "$installer" --method cargo --version 9.8.7 --install-dir "$cargo_destination"
[[ -x $cargo_destination/lmm-api-rs ]]
[[ ! -e $cargo_destination/lmm-api && ! -L $cargo_destination/lmm-api ]]
grep -F -- '--locked --git https://github.com/LIghtJUNction/api.lmm.best --tag cli-v9.8.7' "$cargo_log" >/dev/null

dry_output=$(PATH="$fake_bin:$system_path" HOME="$fixture/home" "$installer" \
  --method cargo --version 9.8.7 --install-dir "$fixture/dry" --dry-run)
grep -F 'cargo install --locked' <<<"$dry_output" >/dev/null
grep -F 'lmm-api symlink: unchanged' <<<"$dry_output" >/dev/null
[[ ! -e $fixture/dry ]]

artifact=lmm-api-rs-9.8.7-linux-amd64
release_root="$fixture/release"
mkdir -p "$release_root/$artifact"
cat >"$release_root/$artifact/lmm-api-rs" <<'BINARY'
#!/bin/sh
[ "${1:-}" = doctor ] && exit 0
exit 2
BINARY
chmod +x "$release_root/$artifact/lmm-api-rs"
"$real_tar" -czf "$release_root/$artifact.tar.gz" -C "$release_root" "$artifact"
(
  cd "$release_root"
  "$real_sha256sum" "$artifact.tar.gz" >"$artifact.tar.gz.sha256"
)
printf '{}\n' >"$release_root/$artifact.tar.gz.sigstore.json"

cat >"$fake_bin/curl" <<'CURL'
#!/bin/sh
set -eu
url=
output=
while [ "$#" -gt 0 ]; do
  case "$1" in
    --output) output=$2; shift 2 ;;
    http://*|https://*) url=$1; shift ;;
    *) shift ;;
  esac
done
[ -n "$url" ] && [ -n "$output" ]
cp "$RELEASE_FIXTURE/${url##*/}" "$output"
CURL
cat >"$fake_bin/cosign" <<'COSIGN'
#!/bin/sh
[ "${1:-}" = verify-blob ]
COSIGN
chmod +x "$fake_bin/curl" "$fake_bin/cosign"

release_destination="$fixture/release-destination"
RELEASE_FIXTURE="$release_root" PATH="$fake_bin:$system_path" HOME="$fixture/home" \
  "$installer" --method release --version 9.8.7 --install-dir "$release_destination"
[[ -x $release_destination/lmm-api-rs ]]
[[ ! -e $release_destination/lmm-api && ! -L $release_destination/lmm-api ]]

release_dry=$(PATH="$fake_bin:$system_path" HOME="$fixture/home" "$installer" \
  --method release --version 9.8.7 --install-dir "$fixture/release-dry" --dry-run)
grep -F 'lmm-api-rs-9.8.7-linux-amd64.tar.gz' <<<"$release_dry" >/dev/null
grep -F 'lmm-api symlink: unchanged' <<<"$release_dry" >/dev/null

echo 'lmm-api-rs installer contracts passed'
