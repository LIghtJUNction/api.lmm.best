#!/usr/bin/env bash
# Emit a deterministic manifest for an explicitly declared set of files.
set -Eeuo pipefail
umask 022

die() {
  printf 'build-source-manifest: %s\n' "$*" >&2
  exit 1
}

usage() {
  cat <<'EOF'
Usage: build-source-manifest.sh --root ROOT --output MANIFEST [--sha256-output FILE]
  --path RELATIVE_PATH                 add a file or recursive tree below ROOT
  --path-override LABEL=ABSOLUTE_PATH  use ABSOLUTE_PATH, record LABEL
  --exclude RELATIVE_PATH              exclude a subtree from recursive paths

Every declared input must be a regular non-symlink file. Recursive paths are
walked without following symlinks, and each manifest row is:

  relative/path<TAB>mode<TAB>file-sha256

Rows and the optional aggregate SHA-256 are stable under input reordering.
EOF
}

ROOT=
OUTPUT=
SHA256_OUTPUT=
declare -a DECLARED_PATHS=()
declare -a DECLARED_OVERRIDES=()
declare -a EXCLUDES=()

while (($#)); do
  case $1 in
    --root)
      (($# >= 2)) || die '--root requires a directory'
      ROOT=$2
      shift 2
      ;;
    --output)
      (($# >= 2)) || die '--output requires a file'
      OUTPUT=$2
      shift 2
      ;;
    --sha256-output)
      (($# >= 2)) || die '--sha256-output requires a file'
      SHA256_OUTPUT=$2
      shift 2
      ;;
    --path)
      (($# >= 2)) || die '--path requires a relative path'
      DECLARED_PATHS+=("$2")
      shift 2
      ;;
    --path-override)
      (($# >= 2)) || die '--path-override requires LABEL=ABSOLUTE_PATH'
      DECLARED_OVERRIDES+=("$2")
      shift 2
      ;;
    --exclude)
      (($# >= 2)) || die '--exclude requires a relative path'
      EXCLUDES+=("$2")
      shift 2
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    *) die "unknown argument: $1" ;;
  esac
done

[[ -n $ROOT && -d $ROOT && ! -L $ROOT ]] || die 'root must be a directory, not a symlink'
[[ -n $OUTPUT ]] || die '--output is required'
ROOT=$(cd -- "$ROOT" && pwd -P)

relative_path_is_safe() {
  local value=$1
  [[ -n $value && $value != /* && $value != . && $value != .. &&
    $value != ../* && $value != */../* && $value != */.. &&
    $value != ./* && $value != */./* &&
    $value != *$'\n'* && $value != *$'\r'* ]]
}

for path in "${DECLARED_PATHS[@]}" "${EXCLUDES[@]}"; do
  relative_path_is_safe "$path" || die "unsafe relative path: $path"
done

is_excluded() {
  local candidate=$1 exclude
  for exclude in "${EXCLUDES[@]}"; do
    if [[ $candidate == "$exclude" || $candidate == "$exclude"/* ]]; then
      return 0
    fi
  done
  return 1
}

declare -A SOURCE_BY_LABEL=()
declare -a LABELS=()

add_file() {
  local label=$1 source=$2
  relative_path_is_safe "$label" || die "unsafe manifest label: $label"
  [[ -f $source && ! -L $source ]] || die "input is not a regular non-symlink file: $source"
  if [[ -v SOURCE_BY_LABEL[$label] ]]; then
    [[ ${SOURCE_BY_LABEL[$label]} == "$source" ]] || \
      die "manifest label has multiple sources: $label"
    return
  fi
  SOURCE_BY_LABEL[$label]=$source
  LABELS+=("$label")
}

walk_tree() {
  local source=$1 entry relative
  [[ -d $source && ! -L $source ]] || die "input tree is not a directory: $source"

  while IFS= read -r -d '' entry; do
    relative=${entry#"$ROOT/"}
    if is_excluded "$relative"; then
      continue
    fi
    [[ ! -L $entry ]] || die "symlink input is forbidden: $relative"
    if [[ -f $entry ]]; then
      add_file "$relative" "$entry"
    elif [[ -d $entry ]]; then
      continue
    else
      die "non-regular input is forbidden: $relative"
    fi
  done < <(find -P "$source" -print0)
}

for path in "${DECLARED_PATHS[@]}"; do
  source="$ROOT/$path"
  if [[ -d $source && ! -L $source ]]; then
    walk_tree "$source"
  else
    add_file "$path" "$source"
  fi
done

for override in "${DECLARED_OVERRIDES[@]}"; do
  [[ $override == *=* ]] || die "--path-override must be LABEL=ABSOLUTE_PATH: $override"
  label=${override%%=*}
  source=${override#*=}
  [[ $source == /* ]] || die "override source must be absolute: $source"
  add_file "$label" "$source"
done

((${#LABELS[@]} > 0)) || die 'no input files were declared'

output_dir=$(dirname -- "$OUTPUT")
mkdir -p -- "$output_dir"
temporary_manifest=$(mktemp "$output_dir/.source-manifest.XXXXXXXX")
temporary_hash=
cleanup() {
  rm -f -- "$temporary_manifest"
  [[ -z ${temporary_hash:-} ]] || rm -f -- "$temporary_hash"
}
trap cleanup EXIT

for label in "${LABELS[@]}"; do
  source=${SOURCE_BY_LABEL[$label]}
  mode_raw=$(stat -c '%a' -- "$source") || die "cannot read mode: $source"
  printf -v mode '%04d' "$mode_raw"
  hash=$(sha256sum -- "$source" | awk '{print $1}') || die "cannot hash: $source"
  [[ $hash =~ ^[0-9a-f]{64}$ ]] || die "invalid SHA-256 for: $source"
  printf '%s\t%s\t%s\n' "$label" "$mode" "$hash"
done | LC_ALL=C sort -t $'\t' -k1,1 >"$temporary_manifest"

mv -f -- "$temporary_manifest" "$OUTPUT"
chmod 0644 -- "$OUTPUT"

if [[ -n $SHA256_OUTPUT ]]; then
  hash_dir=$(dirname -- "$SHA256_OUTPUT")
  mkdir -p -- "$hash_dir"
  temporary_hash=$(mktemp "$hash_dir/.source-manifest-sha256.XXXXXXXX")
  sha256sum -- "$OUTPUT" | awk '{print $1}' >"$temporary_hash"
  chmod 0644 -- "$temporary_hash"
  mv -f -- "$temporary_hash" "$SHA256_OUTPUT"
  temporary_hash=
fi
