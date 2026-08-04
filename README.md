<div align="center">

![lmm.best.api](./apps/web/public/logo.png)

# lmm.best.api

**A self-hosted gateway for routing, governing, and accounting for authorized AI API usage.**

[简体中文](./README.zh_CN.md) · [繁體中文](./README.zh_TW.md) · **English** · [Français](./README.fr.md) · [日本語](./README.ja.md)

</div>

## What it is

lmm.best.api is a maintained fork of [New API](https://github.com/QuantumNous/new-api). It gives teams one control plane for multiple model providers while preserving familiar client protocols.

Use it when you need to:

- expose OpenAI-compatible, OpenAI Responses, Claude Messages, Gemini, Realtime, embeddings, image, audio, or rerank routes;
- manage upstream channels, models, keys, groups, quotas, retries, and rate limits;
- inspect request logs, token usage, latency, availability, and cost accounting;
- run the gateway on infrastructure you control with SQLite, MySQL, or PostgreSQL and optional Redis.

This software does not provide upstream accounts or authorization. Operators are responsible for obtaining lawful access to every configured provider and for meeting applicable security, privacy, billing, tax, content-safety, and regulatory obligations.

## Request flow

```text
Applications and SDKs
        │  compatible API request
        ▼
  lmm.best.api gateway
        ├── authentication and policy
        ├── model mapping and route selection
        ├── retry, rate limit, and quota controls
        └── usage, cost, and audit records
        │
        ▼
Authorized upstream model services
```

The repository provides two selectable backends and one shared frontend. Go is the default production backend; Rust is an explicit preview and does not replace the Go image, release, or `latest` tag.

| Path | Role |
| --- | --- |
| [`apps/api-go`](./apps/api-go) | Default production backend; embeds the verified frontend build |
| [`apps/api-rust`](./apps/api-rust) | Optional Rust preview backend and migration/oracle tooling |
| [`apps/web`](./apps/web) | Shared React frontend used by both backend selections |

The default development and Compose infrastructure is PostgreSQL plus Valkey. The Go backend still preserves the upstream New API database compatibility described below.

## Capabilities

| Area | Included |
| --- | --- |
| Protocols | OpenAI Chat Completions and Responses, Claude Messages, Gemini, Realtime, embeddings, image, audio, rerank, and task APIs |
| Routing | Channel priorities and weights, model mapping, retries, load distribution, and custom authorized upstream endpoints |
| Governance | Users, groups, API keys, model restrictions, quotas, rate limits, and administrative permissions |
| Operations | Usage logs, dashboards, channel testing, health information, cost accounting, and multi-instance operation |
| Identity | Password login plus configurable OIDC, Discord, Linux DO, and Telegram authentication |
| Storage | PostgreSQL plus Valkey by default; upstream-compatible SQLite/MySQL support remains in the Go backend |

Provider-specific behavior changes over time. Verify the route and model you need against the implementation and the [upstream New API documentation](https://docs.newapi.pro/en/docs) before production rollout.

## Quick start

The checked-in Compose file builds this repository's default Go image and starts PostgreSQL plus Valkey. The Rust service is isolated behind the explicit `rust-preview` profile.

```bash
git clone https://github.com/LIghtJUNction/api.lmm.best.git
cd api.lmm.best

# Replace every example password and review the environment values first.
docker compose up -d
```

Open <http://localhost:3000> and follow the setup flow. Check service health with:

```bash
curl http://localhost:3000/api/status
docker compose logs -f lmm-api-go
```

Persistent data uses the `postgres_data`, `valkey_data`, and `go_data` volumes.

## Build this fork

Install Go, Bun, Docker Compose, and [`just`](https://just.systems/), then use the repository recipes:

```bash
just setup
just dev
just test
just build
just run
```

`just build` creates `apps/web/dist`, synchronizes it into `apps/api-go/web/dist`, and builds the static Go executable at `apps/api-go/out/lmm-api`. Use `just docker` and `just package` for the default Go image and package.

Rust remains opt-in:

```bash
just dev-rust
just test-rust
just build-rust
just docker-rust
```

These commands produce preview artifacts only. They do not change the default backend or production release ownership.

## Configuration and production safety

Start from [`.env.example`](./.env.example) and the comments in [`docker-compose.yml`](./docker-compose.yml). Important settings include:

| Variable | Purpose |
| --- | --- |
| `SQL_DSN` | Primary MySQL or PostgreSQL connection string; omit for SQLite |
| `REDIS_CONN_STRING` | Optional shared cache and distributed rate-limit backend |
| `SESSION_SECRET` | Session signing secret; must be strong and identical on every node |
| `CRYPTO_SECRET` | Cache-key HMAC secret; shared Redis users must use the same value |
| `SESSION_COOKIE_SECURE` | Enables secure refresh cookies and strict refresh/logout origin checks |
| `SESSION_COOKIE_TRUSTED_URL` | Exact trusted HTTPS origins required by secure-cookie mode |
| `TRUSTED_PROXIES` | Explicit proxy IP/CIDR trust boundary; use `none` for no trusted proxy |
| `STREAMING_TIMEOUT` | Maximum wait for streaming activity |
| `MAX_REQUEST_BODY_MB` | Decompressed request-body limit |

Before exposing the service publicly:

1. Replace all example database and Redis passwords.
2. Set stable random secrets and keep them consistent across replicas.
3. Configure HTTPS at the reverse proxy and explicitly set trusted origins and proxies.
4. Restrict database and Redis ports to private networks.
5. Back up the primary database and test restoration.
6. Review logging, retention, quotas, rate limits, and upstream authorization.

The detailed authentication and session contract is documented in [`docs/authentication.md`](./docs/authentication.md). Additional deployment material inherited from New API is available in [`docs/`](./docs) and the [upstream documentation](https://docs.newapi.pro/en/docs/installation).

## Multi-instance notes

All nodes must share the same primary database, `SESSION_SECRET`, and effective `CRYPTO_SECRET`. A shared Redis instance provides faster session-revocation propagation and shared rate limits. Without shared Redis, database-backed session state still converges, but in-memory limits are per node and aggregate capacity can be higher than a single-node setting.

Use a stable `NODE_NAME` per instance so operational and audit records identify the serving node.

## Repository links

- Source and issues: <https://github.com/LIghtJUNction/api.lmm.best>
- Upstream project: <https://github.com/QuantumNous/new-api>
- Upstream documentation: <https://docs.newapi.pro/en/docs>
- Original One API project: <https://github.com/songquanpeng/one-api>

When reporting a problem, include the fork commit, deployment method, database type, relevant sanitized logs, and a minimal request that reproduces the behavior. Never publish API keys, cookies, session tokens, or provider credentials.

## License and attribution

This repository is licensed under the [GNU Affero General Public License v3.0](./LICENSE). Review [`NOTICE`](./NOTICE) and [`THIRD-PARTY-LICENSES.md`](./THIRD-PARTY-LICENSES.md) before redistribution.

lmm.best.api is derived from [QuantumNous/New API](https://github.com/QuantumNous/new-api), which itself builds on [One API](https://github.com/songquanpeng/one-api). Preserve the required author notices and the visible upstream link when distributing a modified user interface. For the exact additional terms, use the repository's license and notice files as the authoritative source.
