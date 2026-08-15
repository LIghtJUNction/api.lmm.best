#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

readonly EXPECTED_HOST=arch-dmit
readonly WORK_ROOT=/var/lib/lmm-api-go-deploy/work

die() { printf 'capture-precutover-payload: %s\n' "$*" >&2; exit 2; }

WORKSPACE=''
OUTPUT=''
while (($#)); do
  case $1 in
    --workspace) (($# >= 2)) || die '--workspace requires a value'; WORKSPACE=$2; shift 2 ;;
    --output) (($# >= 2)) || die '--output requires a value'; OUTPUT=$2; shift 2 ;;
    -h|--help)
      printf '%s\n' 'Usage: capture-precutover-payload.sh --workspace PATH --output PATH'
      exit 0
      ;;
    *) die "unknown argument: $1" ;;
  esac
done

[[ $EUID -eq 0 || ${LMM_DEPLOY_TEST_MODE:-0} == 1 ]] || die 'must run as root'
observed_host=${LMM_DEPLOY_OBSERVED_HOST:-$(hostnamectl --static)}
[[ $observed_host == "$EXPECTED_HOST" ]] || die 'production host identity mismatch'
[[ $WORKSPACE == "$WORK_ROOT"/* && -d $WORKSPACE && ! -L $WORKSPACE ]] || die 'unsafe workspace'
[[ -f $WORKSPACE/.lmm-deploy-workspace && ! -L $WORKSPACE/.lmm-deploy-workspace ]] || die 'workspace marker is missing'
[[ $OUTPUT == "$WORKSPACE"/staging/* && ! -e $OUTPUT && ! -L $OUTPUT ]] || die 'unsafe or pre-existing output'
for command in cp find install pacman realpath sha256sum stat systemctl tar; do
  command -v "$command" >/dev/null 2>&1 || die "required command is unavailable: $command"
done
[[ $(pacman -Qq lmm-api) == lmm-api && $(pacman -Qq lmm-api-go) == lmm-api-go ]] || \
  die 'pre-cutover split packages are not installed'

capture_root=$(mktemp -d "$WORKSPACE/staging/precutover-capture.XXXXXXXX")
cleanup() { rm -rf -- "$capture_root"; rm -f -- "$OUTPUT.new"; }
trap cleanup EXIT
mkdir -p "$capture_root/metadata" "$capture_root/core-root" "$capture_root/go-root"

copy_package_payload() {
  local package=$1 destination=$2 source relative
  while IFS= read -r source; do
    [[ $source == /* && $source != *$'\n'* ]] || die 'package contains an unsafe path'
    case "$package:$source" in
      lmm-api:/etc/lmm-api/lmm-api.env)
        install -Dm0600 /dev/null "$destination/etc/lmm-api/lmm-api.env"
        continue
        ;;
      lmm-api:/etc/|lmm-api:/etc/lmm-api/|lmm-api:/etc/lmm-api/*|\
      lmm-api:/usr/|lmm-api:/usr/bin/|lmm-api:/usr/bin/lmm-api|lmm-api:/usr/bin/lmm-api-select|\
      lmm-api:/usr/lib/|lmm-api:/usr/lib/systemd/|lmm-api:/usr/lib/systemd/system/|\
      lmm-api:/usr/lib/systemd/system/lmm-api.service|lmm-api:/usr/share/doc/lmm-api/*|\
      lmm-api:/usr/share/|lmm-api:/usr/share/doc/|lmm-api:/usr/share/licenses/|\
      lmm-api:/usr/share/licenses/lmm-api/*|lmm-api-go:/usr/|lmm-api-go:/usr/lib/|\
      lmm-api-go:/usr/lib/lmm-api/*) ;;
      *) die "package exposes an unexpected path: $package:$source" ;;
    esac
    relative=${source#/}
    if [[ -d $source && ! -L $source ]]; then
      install -d -m0755 "$destination/$relative"
    elif [[ -f $source && ! -L $source ]]; then
      install -d -m0755 "$(dirname -- "$destination/$relative")"
      cp -a -- "$source" "$destination/$relative"
    else
      die "package path is missing or unsupported: $source"
    fi
  done < <(pacman -Qlq "$package")
}

copy_package_payload lmm-api "$capture_root/core-root"
copy_package_payload lmm-api-go "$capture_root/go-root"
[[ ! -s $capture_root/core-root/etc/lmm-api/lmm-api.env ]] || die 'secret environment data entered the payload'
if find "$capture_root/core-root" "$capture_root/go-root" -type l -print -quit | grep -q .; then
  die 'captured package payload contains a symlink'
fi

for package in lmm-api lmm-api-go; do
  read -r name version < <(pacman -Q "$package")
  [[ $name == "$package" && $version =~ ^[0-9][0-9A-Za-z._+:-]*-[1-9][0-9.]*$ ]] || \
    die "invalid installed package identity: $package"
  printf '%s\t%s\n' "$name" "$version" >>"$capture_root/metadata/packages.tsv"
done
sha256sum "$capture_root/go-root/usr/lib/lmm-api/backends/go/lmm-api" >"$capture_root/metadata/actual-go.sha256"
printf 'service_active=%s\nservice_enabled=%s\n' \
  "$(systemctl is-active lmm-api.service)" "$(systemctl is-enabled lmm-api.service)" \
  >"$capture_root/metadata/service.env"

tar --sort=name --mtime='UTC 1970-01-01' --owner=0 --group=0 --numeric-owner \
  -C "$capture_root" -cf "$OUTPUT.new" .
chmod 0600 "$OUTPUT.new"
mv -T -- "$OUTPUT.new" "$OUTPUT"
sha256sum "$OUTPUT" >"$OUTPUT.sha256"
printf 'precutover_payload=%s\n' "$OUTPUT"
