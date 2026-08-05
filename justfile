set shell := ["bash", "-eu", "-o", "pipefail", "-c"]

default: dev

# Install workspace dependencies from the committed lockfile.
setup:
    bun install --frozen-lockfile

# Start only the default PostgreSQL and Valkey development infrastructure.
infra-up:
    docker compose -f docker-compose.dev.yml up -d postgres valkey

# Stop only the default PostgreSQL and Valkey development infrastructure.
infra-down:
    docker compose -f docker-compose.dev.yml stop postgres valkey

# Start PostgreSQL, Valkey, the Go API, and the shared web frontend.
dev: infra-up
    #!/usr/bin/env bash
    set -euo pipefail
    pids=()
    cleanup() { for pid in "${pids[@]}"; do kill "$pid" 2>/dev/null || true; done; }
    trap cleanup EXIT INT TERM
    bun run dev:go & pids+=("$!")
    bun run dev:web & pids+=("$!")
    wait -n "${pids[@]}"

# Start only the Go API development process.
dev-go:
    bun run dev:go

# Start only the shared web development process.
dev-web:
    bun run dev:web

# Start the isolated Rust preview profile and shared web frontend without Go.
dev-rust:
    #!/usr/bin/env bash
    set -euo pipefail
    docker compose -f docker-compose.dev.yml --profile rust-preview up -d postgres valkey lmm-api-rs-preview
    exec bun run dev:web

# Build and run the default static Go production binary.
run: build
    exec apps/api-go/out/lmm-api

# Run an already-built Go production binary.
run-go:
    @test -x apps/api-go/out/lmm-api || { echo "error: apps/api-go/out/lmm-api is missing; run 'just build'" >&2; exit 1; }
    exec apps/api-go/out/lmm-api

# Run the explicit Rust backend with standardized infrastructure.
run-rust: infra-up
    bun run dev:rust

# Build the frontend and default Go backend as independent artifacts.
build: build-web build-go

# Build the shared web frontend.
build-web:
    VITE_REACT_APP_VERSION="$(cat VERSION)" bun run build:web
    @test -f apps/web/dist/index.html || { echo "error: apps/web/dist/index.html was not produced" >&2; exit 1; }

# Build the static Go production binary independently.
build-go:
    bun run build:go
    @test -x apps/api-go/out/lmm-api || { echo "error: static Go binary was not produced" >&2; exit 1; }

# Build the explicit Rust backend.
build-rust:
    bun run build:rust

# Build the default Go production artifact and the optional Rust backend.
build-all: build build-rust

# Test the default Go backend and shared web frontend.
test: test-go test-web

test-go:
    bun run test:go

test-web:
    bun run test:web

test-rust:
    bun run test:rust

# Test both selectable backends and the shared frontend.
test-all: test test-rust

# Run default Go and web quality gates.
check: format-check lint typecheck test check-deploy

# Verify atomic frontend publication and the protected Go deployment contract.
check-deploy:
    bash deploy/test-frontend-release.sh
    bash deploy/production/test-go-deploy-contract.sh

format: format-go format-web

format-go:
    bun run format:go

format-web:
    bun run format:web

format-rust:
    bun run format:rust

format-check: format-check-go format-check-web

format-check-go:
    bun run format-check:go

format-check-web:
    bun run format-check:web

format-check-rust:
    bun run format-check:rust

lint: lint-go lint-web

lint-go:
    bun run lint:go

lint-web:
    bun run lint:web

lint-rust:
    bun run lint:rust

typecheck: typecheck-go typecheck-web

typecheck-go:
    bun run typecheck:go

typecheck-web:
    bun run typecheck:web

typecheck-rust:
    bun run typecheck:rust

# Remove generated build and task-runner output only.
clean-generated:
    rm -rf .turbo apps/web/.turbo apps/api-go/out apps/api-rust/target apps/web/dist

# Build the default Go image from the root Dockerfile.
docker: docker-go

docker-go:
    docker build -f Dockerfile -t "lmm-api-go:${LMM_IMAGE_TAG:-local}" .

docker-rust:
    docker build -f Dockerfile.rust -t "lmm-api-rs-preview:${LMM_IMAGE_TAG:-local}" .

# Build the default Go production package.
package: package-go

package-go:
    @grep -Fqx 'LMM_API_BACKEND=go' packaging/aur/lmm-api/backend.conf || { echo "error: canonical package backend.conf must select go" >&2; exit 1; }
    bash packaging/aur/lmm-api/build-local-package.sh

package-rust:
    bash packaging/aur/lmm-api-rs-bin/build-local-package.sh

# Validate the public AUR package that consumes prebuilt release assets.
test-package-bin:
    bash packaging/aur/lmm-api-bin/test-package.sh

# Deploy Go production only after explicit backend and site confirmation.
deploy-production:
    @if [[ "${CONFIRM_PRODUCTION:-}" != "api.lmm.best" || "${LMM_API_BACKEND:-}" != "go" ]]; then echo "error: set CONFIRM_PRODUCTION=api.lmm.best and LMM_API_BACKEND=go" >&2; exit 1; fi
    @script="deploy/production/deploy-go.sh"; if [[ ! -x "$script" ]]; then echo "error: $script is required before production deployment is available" >&2; exit 1; fi; "$script"

# Deploy Rust production only through its explicit guarded recipe.
deploy-production-rust:
    @if [[ "${CONFIRM_PRODUCTION:-}" != "api.lmm.best" || "${LMM_API_BACKEND:-}" != "rust" ]]; then echo "error: set CONFIRM_PRODUCTION=api.lmm.best and LMM_API_BACKEND=rust" >&2; exit 1; fi
    @script="deploy/production/deploy-rust.sh"; if [[ ! -x "$script" ]]; then echo "error: $script is required before Rust production deployment is available" >&2; exit 1; fi; "$script"
