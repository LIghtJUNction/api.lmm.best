#!/bin/sh
# Install the lmm-api-rs client/server binary. This script never changes the
# /usr/bin/lmm-api backend-selection symlink.
set -eu

VERSION="${LMM_API_RS_VERSION:-0.1.6}"
REPOSITORY="${LMM_API_RS_REPOSITORY:-https://github.com/LIghtJUNction/api.lmm.best}"
INSTALL_DIR="${LMM_API_RS_INSTALL_DIR:-${HOME:-}/.local/bin}"
METHOD="${LMM_API_RS_INSTALL_METHOD:-auto}"
DRY_RUN=false

usage() {
  cat <<'USAGE'
Usage: install.sh [--version VERSION] [--install-dir DIR]
                  [--method auto|aur|cargo|release] [--dry-run]

Installs lmm-api-rs. It does not create or replace the lmm-api symlink.
USAGE
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --version)
      [ "$#" -ge 2 ] || { echo "--version requires a value" >&2; exit 2; }
      VERSION=$2
      shift 2
      ;;
    --install-dir)
      [ "$#" -ge 2 ] || { echo "--install-dir requires a value" >&2; exit 2; }
      INSTALL_DIR=$2
      shift 2
      ;;
    --method)
      [ "$#" -ge 2 ] || { echo "--method requires a value" >&2; exit 2; }
      METHOD=$2
      shift 2
      ;;
    --dry-run)
      DRY_RUN=true
      shift
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    *)
      echo "unknown argument: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

case "$VERSION" in
  ''|*[!0-9A-Za-z.-]*) echo "invalid version: $VERSION" >&2; exit 2 ;;
esac
case "$METHOD" in
  auto|aur|cargo|release) ;;
  *) echo "invalid installation method: $METHOD" >&2; exit 2 ;;
esac
[ -n "$INSTALL_DIR" ] || { echo "install directory is empty" >&2; exit 2; }

command_exists() {
  command -v "$1" >/dev/null 2>&1
}

arch_family_linux() {
  [ "$(uname -s)" = Linux ] || return 1
  [ -r /etc/os-release ] || return 1
  # shellcheck disable=SC1091
  . /etc/os-release
  [ "${ID:-}" = arch ] || case " ${ID_LIKE:-} " in *' arch '*) return 0;; *) return 1;; esac
}

aur_helper() {
  if command_exists paru; then
    printf '%s\n' paru
  elif command_exists yay; then
    printf '%s\n' yay
  else
    return 1
  fi
}

select_method() {
  if [ "$METHOD" != auto ]; then
    printf '%s\n' "$METHOD"
  elif arch_family_linux && aur_helper >/dev/null 2>&1; then
    printf '%s\n' aur
  elif command_exists cargo; then
    printf '%s\n' cargo
  else
    printf '%s\n' release
  fi
}

release_platform() {
  os=$(uname -s)
  machine=$(uname -m)
  case "$os:$machine" in
    Linux:x86_64|Linux:amd64) printf '%s\n' linux-amd64 ;;
    Linux:aarch64|Linux:arm64) printf '%s\n' linux-arm64 ;;
    Darwin:x86_64|Darwin:amd64) printf '%s\n' darwin-amd64 ;;
    Darwin:aarch64|Darwin:arm64) printf '%s\n' darwin-arm64 ;;
    *) echo "unsupported release target: $os/$machine" >&2; return 1 ;;
  esac
}

download() {
  url=$1
  output=$2
  if command_exists curl; then
    curl --fail --silent --show-error --location --proto '=https' --tlsv1.2 \
      --connect-timeout 10 --max-time 600 "$url" --output "$output"
  elif command_exists wget; then
    wget --https-only --timeout=600 --tries=1 --output-document="$output" "$url"
  else
    echo "curl or wget is required for release installation" >&2
    return 1
  fi
}

verify_checksum() {
  checksum_archive=$1
  checksum_file=$2
  checksum_archive_name=$3
  expected=$(awk -v name="$checksum_archive_name" '$2 == name || $2 == "*" name { print $1; exit }' "$checksum_file")
  case "$expected" in
    ????????????????????????????????????????????????????????????????) ;;
    *) echo "release checksum file did not contain $checksum_archive_name" >&2; return 1 ;;
  esac
  case "$expected" in *[!0-9A-Fa-f]*) echo "invalid SHA-256 digest" >&2; return 1;; esac
  if command_exists sha256sum; then
    actual=$(sha256sum "$checksum_archive" | awk '{print $1}')
  elif command_exists shasum; then
    actual=$(shasum -a 256 "$checksum_archive" | awk '{print $1}')
  elif command_exists openssl; then
    actual=$(openssl dgst -sha256 "$checksum_archive" | awk '{print $NF}')
  else
    echo "sha256sum, shasum, or openssl is required" >&2
    return 1
  fi
  [ "$actual" = "$expected" ] || { echo "release checksum mismatch" >&2; return 1; }
}

verify_sigstore_if_available() {
  sigstore_archive=$1
  sigstore_bundle=$2
  if command_exists cosign; then
    cosign verify-blob \
      --bundle "$sigstore_bundle" \
      --certificate-identity-regexp '^https://github.com/LIghtJUNction/api\.lmm\.best/\.github/workflows/release\.yml@refs/tags/v[0-9A-Za-z.-]+$' \
      --certificate-oidc-issuer 'https://token.actions.githubusercontent.com' \
      "$sigstore_archive" >/dev/null
  else
    echo "warning: cosign is unavailable; SHA-256 verified, Sigstore verification skipped" >&2
  fi
}

install_release() {
  platform=$(release_platform)
  artifact="lmm-api-rs-${VERSION}-${platform}"
  archive="${artifact}.tar.gz"
  base="${REPOSITORY}/releases/download/v${VERSION}"
  tmp=$(mktemp -d "${TMPDIR:-/tmp}/lmm-api-rs-install.XXXXXXXX")
  trap 'rm -rf -- "$tmp"' EXIT HUP INT TERM
  download "$base/$archive" "$tmp/$archive"
  download "$base/$archive.sha256" "$tmp/$archive.sha256"
  download "$base/$archive.sigstore.json" "$tmp/$archive.sigstore.json"
  verify_checksum "$tmp/$archive" "$tmp/$archive.sha256" "$archive"
  verify_sigstore_if_available "$tmp/$archive" "$tmp/$archive.sigstore.json"

  listing=$(tar -tzf "$tmp/$archive")
  printf '%s\n' "$listing" | awk -v root="$artifact/" '
    index($0, root) != 1 || $0 ~ /(^|\/)\.\.($|\/)/ || $0 ~ /^\// { exit 1 }
  ' || { echo "unsafe release archive layout" >&2; return 1; }
  tar -xzf "$tmp/$archive" -C "$tmp"
  [ -f "$tmp/$artifact/lmm-api-rs" ] || { echo "release binary is missing" >&2; return 1; }
  if [ -L "$INSTALL_DIR" ]; then
    echo "refusing to install through symlinked directory: $INSTALL_DIR" >&2
    return 1
  fi
  mkdir -p "$INSTALL_DIR"
  install -m 0755 "$tmp/$artifact/lmm-api-rs" "$INSTALL_DIR/lmm-api-rs"
  rm -rf -- "$tmp"
  trap - EXIT HUP INT TERM
}

install_cargo() {
  command_exists cargo || { echo "cargo is unavailable" >&2; return 1; }
  tmp=$(mktemp -d "${TMPDIR:-/tmp}/lmm-api-rs-cargo.XXXXXXXX")
  trap 'rm -rf -- "$tmp"' EXIT HUP INT TERM
  cargo install --locked --git "$REPOSITORY" --tag "v$VERSION" \
    --root "$tmp/root" lmm-api-rs
  [ -f "$tmp/root/bin/lmm-api-rs" ] || { echo "cargo did not produce lmm-api-rs" >&2; return 1; }
  if [ -L "$INSTALL_DIR" ]; then
    echo "refusing to install through symlinked directory: $INSTALL_DIR" >&2
    return 1
  fi
  mkdir -p "$INSTALL_DIR"
  install -m 0755 "$tmp/root/bin/lmm-api-rs" "$INSTALL_DIR/lmm-api-rs"
  rm -rf -- "$tmp"
  trap - EXIT HUP INT TERM
}

install_aur() {
  arch_family_linux || { echo "AUR installation requires an Arch-family system" >&2; return 1; }
  helper=$(aur_helper) || { echo "paru or yay is required for AUR installation" >&2; return 1; }
  "$helper" -S --needed lmm-api-rs-bin
}

selected=$(select_method)
if $DRY_RUN; then
  case "$selected" in
    aur) printf '%s -S --needed lmm-api-rs-bin\n' "$(aur_helper 2>/dev/null || printf '<paru-or-yay>')" ;;
    cargo) printf 'cargo install --locked --git %s --tag v%s lmm-api-rs\n' "$REPOSITORY" "$VERSION" ;;
    release) printf 'download and verify lmm-api-rs-%s-%s.tar.gz\n' "$VERSION" "$(release_platform)" ;;
  esac
  printf 'lmm-api symlink: unchanged\n'
  exit 0
fi

case "$selected" in
  aur) install_aur ;;
  cargo) install_cargo ;;
  release) install_release ;;
esac

if command_exists lmm-api-rs; then
  installed=$(command -v lmm-api-rs)
elif [ -x "$INSTALL_DIR/lmm-api-rs" ]; then
  installed="$INSTALL_DIR/lmm-api-rs"
else
  echo "lmm-api-rs installation completed but the binary was not found" >&2
  exit 1
fi
printf 'Installed lmm-api-rs: %s\n' "$installed"
printf 'The lmm-api backend-selection symlink was not changed.\n'
"$installed" doctor
