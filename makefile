WEB_DIR := ./web
RUST_WORKSPACE := ./rust/Cargo.toml
DEV_WEB_PORT ?= 5173
DEV_COMPOSE_FILE := docker-compose.dev.yml
DEV_API_SERVICE := lmm-api-rs
ENV_FILE ?= ./.env
CARGO ?= cargo
BUN ?= bun
DOCKER_COMPOSE ?= docker compose

.PHONY: all build build-api build-api-release build-web build-all-web check check-frontend-split preflight-connections preflight-runtime-env start-api dev dev-api dev-api-rebuild dev-web reset-setup test

all: build

build: build-all-web build-api-release

build-web:
	@echo "Building web frontend..."
	@cd $(WEB_DIR) && $(BUN) install --frozen-lockfile
	@cd $(WEB_DIR) && DISABLE_ESLINT_PLUGIN='true' VITE_REACT_APP_VERSION=$$(cat ../VERSION) $(BUN) run build

build-all-web: build-web

build-api:
	@echo "Building Rust API..."
	@$(CARGO) build --manifest-path $(RUST_WORKSPACE) --locked --package lmm-api-rs

build-api-release:
	@echo "Building release Rust API..."
	@LMM_BUILD_REVISION=$${LMM_BUILD_REVISION:-development} $(CARGO) build --manifest-path $(RUST_WORKSPACE) --locked --release --package lmm-api-rs

check-frontend-split:
	@./deploy/check-frontend-split.sh
	@./deploy/test-frontend-release.sh

check:
	@$(CARGO) check --manifest-path $(RUST_WORKSPACE) --workspace --all-targets --locked
	@$(CARGO) clippy --manifest-path $(RUST_WORKSPACE) --workspace --all-targets --all-features --locked -- -D warnings

preflight-connections:
	@set -eu; \
	[ -r '$(ENV_FILE)' ] || { echo "missing $(ENV_FILE); copy .env.example and populate secrets" >&2; exit 1; }; \
	set -a; . '$(ENV_FILE)'; set +a; \
	: "$${DATABASE_URL:?DATABASE_URL must be a complete PostgreSQL 18 runtime URL}"; \
	: "$${VALKEY_URL:?VALKEY_URL must be a complete dedicated Valkey URL}"; \
	: "$${LMM_DATABASE_SCHEMA:?LMM_DATABASE_SCHEMA must name the migrated schema}"; \
	: "$${LMM_SCHEMA_CONTRACT:?LMM_SCHEMA_CONTRACT must be set}"; \
	case "$$LMM_DATABASE_SCHEMA" in lmm_app_v[1-9]|lmm_app_v[1-9][0-9]*) ;; *) echo "LMM_DATABASE_SCHEMA must be versioned as lmm_app_vN" >&2; exit 1;; esac; \
	expected="options=-csearch_path%3D$${LMM_DATABASE_SCHEMA}%2Cpg_catalog"; \
	case "$$DATABASE_URL" in *"$$expected"*) ;; *) echo "DATABASE_URL must include $$expected" >&2; exit 1;; esac

preflight-runtime-env: preflight-connections
	@set -eu; set -a; . '$(ENV_FILE)'; set +a; \
	: "$${LMM_RS_LISTEN_ADDR:?LMM_RS_LISTEN_ADDR must be set}"; \
	: "$${LMM_RS_SLOT:?LMM_RS_SLOT must be set}"; \
	: "$${LMM_WEB_DIST_DIR:?LMM_WEB_DIST_DIR must be set}"; \
	[ -f "$${LMM_WEB_DIST_DIR}/index.html" ] || { echo "LMM_WEB_DIST_DIR must contain index.html; run make build-web" >&2; exit 1; }

start-api: preflight-runtime-env
	@echo "Starting Rust API dev server..."
	@set -a; . '$(ENV_FILE)'; set +a; \
	LMM_BUILD_REVISION=$${LMM_BUILD_REVISION:-development} exec $(CARGO) run --manifest-path $(RUST_WORKSPACE) --locked --package lmm-api-rs

dev-api:
	@echo "Starting PostgreSQL, Valkey, and the Rust API (docker)..."
	@$(DOCKER_COMPOSE) -f $(DEV_COMPOSE_FILE) up -d

dev-api-rebuild:
	@echo "Rebuilding and starting the Rust API (docker)..."
	@$(DOCKER_COMPOSE) -f $(DEV_COMPOSE_FILE) up -d --build $(DEV_API_SERVICE)

dev-web:
	@echo "Starting web frontend: http://localhost:$(DEV_WEB_PORT)"
	@cd $(WEB_DIR) && $(BUN) install --frozen-lockfile
	@cd $(WEB_DIR) && $(BUN) run dev -- --host 0.0.0.0 --port $(DEV_WEB_PORT)

dev: dev-api dev-web

test:
	@echo "Testing Rust workspace..."
	@$(CARGO) test --manifest-path $(RUST_WORKSPACE) --workspace --all-targets --locked

reset-setup: preflight-connections
	@set -eu; set -a; . '$(ENV_FILE)'; set +a; \
	echo "Removing setup state from PostgreSQL schema $$LMM_DATABASE_SCHEMA..."; \
	PGDATABASE="$$DATABASE_URL" PGOPTIONS="-csearch_path=$$LMM_DATABASE_SCHEMA,pg_catalog" \
		psql -X -v ON_ERROR_STOP=1 \
		-c 'DELETE FROM setups; DELETE FROM users WHERE role = 100; DELETE FROM options WHERE key IN ('\''SelfUseModeEnabled'\'', '\''DemoSiteEnabled'\'');'; \
	if $(DOCKER_COMPOSE) -f $(DEV_COMPOSE_FILE) ps --services --status running | grep -qx '$(DEV_API_SERVICE)'; then \
		$(DOCKER_COMPOSE) -f $(DEV_COMPOSE_FILE) restart $(DEV_API_SERVICE); \
	fi
