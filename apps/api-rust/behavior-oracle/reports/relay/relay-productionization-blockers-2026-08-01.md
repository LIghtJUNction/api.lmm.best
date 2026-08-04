# Relay productionization blockers

Scope: `migration_routes/relay_*.rs`, frozen legacy revision
`5418ce6b6d45ed69167b0aad53f2f595e5bc8de9`.

## Verified low-risk contract

`DELETE /v1/models/:model` is a token-auth-only deterministic 501 route.
The Axum wildcard owner rejects multiple model segments with the legacy 404
shape. The focused Rust test starts an independent TCP listener and verifies
the valid-token 501 status, JSON content type, and exact body. It also proves
that a backend which would return `NoChannel` is not asked to select a channel,
does not record an outcome, and cannot add `x-oneapi-channel-id`.

## Why an end-to-end Go/Rust relay differential is not yet valid

The live Rust listener currently does not mount any relay router. The route
slices require service ports, but no concrete service exists for the complete
legacy lifecycle: PostgreSQL token authentication and channel selection,
Valkey rate-limit/cache behavior with a PostgreSQL fallback, pre-consumption,
retry channel selection with byte replay, provider conversion/streaming,
post-consumption/refund, usage logs, channel health, and affinity. A mock
backend cannot validate those effects and must not be presented as a
production differential.

## Required composition before differential

1. Implement one concrete executor for each relay port using the legacy
   channel/provider adaptor registry and the authoritative PostgreSQL billing
   transaction boundaries.
2. Add the real route stack to `http::router_with_web` with CORS,
   decompression/body storage, performance gate, token auth, model rate limit,
   and distribution in legacy order.
3. Create an isolated PostgreSQL 18 + Valkey fixture and a deterministic local
   upstream that covers JSON, SSE, timeout/cancellation, retry, and channel
   failures.
4. Only then compare Go and Rust TCP listeners for normalized headers/body/SSE
   frames and database/Valkey before-after snapshots.
