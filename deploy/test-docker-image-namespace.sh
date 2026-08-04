#!/usr/bin/env bash
set -euo pipefail

checker="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/deploy/check-docker-image-namespace.sh"
runtime="$(mktemp -d "${TMPDIR:-/tmp}/lmm-docker-namespace.XXXXXX")"
cleanup() { rm -rf -- "$runtime"; }
trap cleanup EXIT

printf 'push: true\ntags:\n  - calciumion/new-api:latest\n' >"$runtime/upstream.yml"
if "$checker" "$runtime/upstream.yml" >/dev/null 2>&1; then
  echo "upstream Docker repository fixture unexpectedly passed" >&2
  exit 1
fi

printf 'push: true\ntags:\n  - lightjunction/lmm-api:latest\n' >"$runtime/no-variable.yml"
if "$checker" "$runtime/no-variable.yml" >/dev/null 2>&1; then
  echo "missing DOCKER_IMAGE_REPOSITORY fixture unexpectedly passed" >&2
  exit 1
fi

cat >"$runtime/fork-owned.yml" <<'YAML'
push: true
tags:
  - ${{ vars.DOCKER_IMAGE_REPOSITORY }}:latest
YAML
"$checker" "$runtime/fork-owned.yml" >/dev/null

echo "docker image namespace check passes"