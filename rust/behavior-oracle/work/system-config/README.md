# system-config migration oracle

Scope is exactly migration-plan rows 122-133 and 160-161.  The route module
requires an injected root-dashboard-session authorizer; API tokens must not be
accepted as a substitute.  `GET /api/setup` and `POST /api/setup` remain public.

Replay invariants: setup creates the root row only once and reports the legacy
already-initialized response after the setup marker exists; option writes and
Pancake saves use PostgreSQL upserts/transactions and invalidate the five-second
Valkey option cache only after commit.  Cache-clear is idempotent.

Host integration is explicit: the router is constructed with a root-session
authorizer, a bounded project-update client, and a Pancake gateway.  The update
client must pin the frozen GitHub main-commit endpoint and enforce the Go
controller's timeout, response-size, redirect, and response-shape policy; the
route must not use a disabled fallback.  Valkey is a cache only for option
reads: PostgreSQL remains authoritative during a cache outage, and writes log
cache-invalidation failures after their committed PostgreSQL mutation.

## Isolated replay harness

The route remains intentionally unmounted until the shared listener supplies
the dashboard-auth adapter and response-header middleware.  Its real storage
replay is explicit rather than silently skipped:

```sh
LMM_SYSTEM_CONFIG_TEST_DATABASE_URL=postgres://... \
LMM_SYSTEM_CONFIG_TEST_VALKEY_URL=redis://... \
cargo test --offline -p lmm-api-rs --test migration_system_config -- --ignored
```

The harness requires isolated PostgreSQL 18 and Valkey endpoints.  It seeds a
stale option cache, writes through the root route, verifies the PostgreSQL row
and Valkey deletion, then verifies the next read repopulates Valkey from
PostgreSQL.  The frozen Go TCP capture remains the comparison source for JSON
shape and shared headers; a Rust TCP capture is deliberately deferred until
the listener can mount the shared auth and header middleware without a test
bypass.
