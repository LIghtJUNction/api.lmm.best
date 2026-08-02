#!/usr/bin/env bash
set -Eeuo pipefail

readonly DEFAULT_ROOT=/srv/lmm-api-frontend
readonly DEFAULT_KEEP=3

usage() {
  cat <<'EOF'
Usage:
  frontend-release.sh publish --source DIR --release ID [--root DIR] [--keep N] [--dry-run]
  frontend-release.sh rollback [--release ID] [--root DIR] [--dry-run]

Publishes a pre-built frontend using a same-filesystem staging directory and an
atomic `current` symlink replacement. Run as a user allowed to write ROOT.
EOF
}

die() { printf 'frontend-release: %s\n' "$*" >&2; exit 1; }
run() { if (( dry_run )); then printf '+ '; printf '%q ' "$@"; printf '\n'; else "$@"; fi; }

validate_id() {
  [[ $1 =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$ ]] ||
    die "invalid release id: $1"
}

validate_tree() {
  local tree=$1 ref path
  [[ -f $tree/index.html ]] || die "missing index.html in $tree"
  if find "$tree" -type l -print -quit | grep -q .; then
    die 'release trees must not contain symlinks'
  fi
  while IFS= read -r ref; do
    ref=${ref%%\?*}; ref=${ref%%\#*}; ref=${ref#/}
    [[ -z $ref || $ref == http:* || $ref == https:* || $ref == data:* || $ref == //* ]] && continue
    path=$tree/$ref
    [[ -f $path ]] || die "index.html references missing file: $ref"
    case $(realpath -m -- "$path") in "$tree"/*) ;; *) die "reference escapes release: $ref";; esac
  done < <(grep -oE "(src|href)=[\"'][^\"']+[\"']" "$tree/index.html" | sed -E "s/^[^=]+=[\"'](.*)[\"']$/\\1/")
}

root=$DEFAULT_ROOT keep=$DEFAULT_KEEP source='' release='' dry_run=0
[[ $# -gt 0 ]] || { usage; exit 2; }
action=$1; shift
while [[ $# -gt 0 ]]; do
  case $1 in
    --source) [[ $# -ge 2 ]] || die '--source needs a value'; source=$2; shift 2 ;;
    --release) [[ $# -ge 2 ]] || die '--release needs a value'; release=$2; shift 2 ;;
    --root) [[ $# -ge 2 ]] || die '--root needs a value'; root=$2; shift 2 ;;
    --keep) [[ $# -ge 2 ]] || die '--keep needs a value'; keep=$2; shift 2 ;;
    --dry-run) dry_run=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown argument: $1" ;;
  esac
done

[[ $root = /* && $root != / ]] || die '--root must be an absolute, non-root path'
[[ $keep =~ ^[1-9][0-9]*$ ]] || die '--keep must be a positive integer'

releases=$root/releases
staging_root=$root/.staging
lock_file=$root/.release.lock
run mkdir -p -- "$releases" "$staging_root"
if (( dry_run )); then exec 9>/dev/null; else exec 9>"$lock_file"; fi
flock -n 9 || die 'another frontend release operation is running'

switch_current() {
  local target=$1 temp=$root/.current.$$
  run ln -s -- "releases/$target" "$temp"
  run mv -Tf -- "$temp" "$root/current"
}

preflight_assets() {
  local source_static=$1 asset rel destination
  [[ -d $source_static ]] || return 0
  while IFS= read -r -d '' asset; do
    rel=${asset#"$source_static"/}
    destination=$root/assets/$rel
    if [[ -e $destination ]]; then
      cmp -s -- "$asset" "$destination" ||
        die "immutable asset collision with different content: static/$rel"
    fi
  done < <(find "$source_static" -type f -print0)
}

publish_assets() {
  local source_static=$1 asset rel destination temp parent probe installed_count=0 i
  local -a installed=() created_dirs=()
  rollback_installed_assets() {
    rm -f -- "${installed[@]}"
    for ((i=0; i<${#created_dirs[@]}; i++)); do
      rmdir -- "${created_dirs[i]}" 2>/dev/null || true
    done
  }
  [[ -d $source_static ]] || return 0
  while IFS= read -r -d '' asset; do
    rel=${asset#"$source_static"/}
    destination=$root/assets/$rel
    [[ -e $destination ]] && continue
    parent=$(dirname -- "$destination")
    probe=$parent
    while [[ ! -d $probe && $probe == "$root/assets"/* ]]; do
      created_dirs+=("$probe")
      probe=$(dirname -- "$probe")
    done
    if ! run mkdir -p -- "$parent"; then
      (( dry_run )) || rollback_installed_assets
      return 1
    fi
    temp=$destination.tmp.$$
    if ! run cp -- "$asset" "$temp" ||
       ! run chmod a=r -- "$temp" ||
       ! run mv -T -- "$temp" "$destination"; then
      if (( ! dry_run )); then rm -f -- "$temp"; rollback_installed_assets; fi
      return 1
    fi
    installed+=("$destination")
    ((installed_count += 1))
    if [[ ${LMM_FRONTEND_TEST_FAIL_AFTER_ASSETS:-} == "$installed_count" ]]; then
      (( dry_run )) || rollback_installed_assets
      die "injected asset publish failure after $installed_count files"
    fi
  done < <(find "$source_static" -type f -print0)
}

case $action in
  publish)
    [[ -n $source && -n $release ]] || die 'publish requires --source and --release'
    validate_id "$release"
    source=$(realpath -- "$source")
    validate_tree "$source"
    target=$releases/$release
    [[ ! -e $target ]] || die "release already exists: $release"
    stage=$staging_root/$release.$$
    run mkdir -- "$stage"
    run cp -a -- "$source/." "$stage/"
    if (( ! dry_run )); then validate_tree "$stage"; fi
    if (( dry_run )); then
      preflight_assets "$source/static"
      publish_assets "$source/static"
    else
      preflight_assets "$stage/static"
      publish_assets "$stage/static"
    fi
    run mv -T -- "$stage" "$target"
    run chmod -R a=rX -- "$target"
    run find "$target" -type d -exec chmod u+w {} +
    switch_current "$release"
    ;;
  rollback)
    if [[ -z $release ]]; then
      current=
      [[ -L $root/current ]] && current=$(basename -- "$(readlink -- "$root/current")")
      mapfile -t candidates < <(find "$releases" -mindepth 1 -maxdepth 1 -type d -printf '%T@ %f\n' | sort -nr | awk -v current="$current" '$2 != current { print $2 }')
      [[ ${#candidates[@]} -gt 0 ]] || die 'no previous release is available'
      release=${candidates[0]}
    fi
    validate_id "$release"
    [[ -d $releases/$release ]] || die "unknown release: $release"
    validate_tree "$releases/$release"
    switch_current "$release"
    ;;
  *) usage; die "unknown action: $action" ;;
esac

if (( ! dry_run )); then
  current=$(basename -- "$(readlink -- "$root/current")")
  mapfile -t stale < <(find "$releases" -mindepth 1 -maxdepth 1 -type d -printf '%T@ %f\n' | sort -nr | awk -v keep="$keep" -v current="$current" '$2 != current { seen++; if (seen >= keep) print $2 }')
  for old in "${stale[@]}"; do rm -rf -- "${releases:?}/$old"; done
  printf 'current=%s\n' "$current"
fi
