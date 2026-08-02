# API-token candidate validation

`run-pg18-valkey-integration.sh` passed on 2026-08-01 against a disposable
native PostgreSQL 18 cluster and Valkey instance. It ran the Rust candidate's
real PostgreSQL/Valkey tests serially and covered:

- masked-list/key reveal, HMAC cache namespace, cleaned cache hash fields,
  TTL reset, and deletion invalidation;
- competing and replayed deletion;
- per-user token limit and cross-user owner scoping;
- a dropped-`tokens` PostgreSQL fault on batch key retrieval, which produced a
  failure envelope rather than a successful partial map.

The isolated frozen Go listener was also replayed on 2026-08-01 with
`capture-live.sh`: all nine route requests returned the expected success
statuses and no-store headers for key reads. That replay confirmed that token
views include `DeletedAt: null` and that a full PUT omitting `allow_ips`
returns `allow_ips: null`; the candidate and its PG18 test now encode both
details.

The Go/Rust TCP differential is present at `captures/api-token/tcp-differential.sh`
but is **not validated or claimed as passing**. The shared listener has no
`api_token_router` mount and no production dashboard-session-to-
`ApiTokenPrincipal` boundary. Its preflight explicitly rejects that `404`.
Promotion requires shared wiring to mount the route after verified dashboard
authentication, inject the principal and auth-version header, provide the
legacy rate limit layers, and configure `CRYPTO_SECRET`, cache TTL, and token
limit settings.
