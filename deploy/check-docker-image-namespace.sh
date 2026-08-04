#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
workflows=("$@")
if ((${#workflows[@]} == 0)); then
  workflows=(
    "$repo_root/.github/workflows/docker-build.yml"
    "$repo_root/.github/workflows/docker-image-branch.yml"
  )
fi

for workflow in "${workflows[@]}"; do
  [[ -f "$workflow" ]] || { echo "missing workflow: $workflow" >&2; exit 1; }
  if grep -Eq '(^|[[:space:]])calciumion/new-api([:@]|$)' "$workflow"; then
    echo "workflow still targets the upstream Docker repository: $workflow" >&2
    exit 1
  fi
  if ! grep -Fq 'DOCKER_IMAGE_REPOSITORY' "$workflow"; then
    echo "workflow does not require DOCKER_IMAGE_REPOSITORY: $workflow" >&2
    exit 1
  fi
done

echo "docker publish workflows use a fork-owned Docker repository"