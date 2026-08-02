# API-token route captures

These contracts were observed against the legacy Go listener at revision
`5418ce6b6d45ed69167b0aad53f2f595e5bc8de9`, started with the parent
`run-isolated-oracle.sh` harness. The harness creates a fresh synthetic SQLite
database and a disposable Valkey instance; it does not contact production.

`capture-live.sh` creates one synthetic dashboard user, authenticates through
the real login endpoint, and uses the resulting bearer token only in memory.
It creates disposable tokens to exercise all nine routes. It redacts dashboard
JWTs and token keys before output. Do not paste the raw listener output into a
fixture: token keys are deliberately only represented by `<REDACTED_TOKEN_KEY>`.

Run from the repository root:

```bash
bash rust/behavior-oracle/run-isolated-oracle.sh \
  bash rust/behavior-oracle/captures/api-token/capture-live.sh
```

The endpoint listener supports SQLite in the existing isolation harness. The
contracts therefore specify PostgreSQL deltas in logical row terms (table,
primary-key scope, and changed columns), which are portable to PostgreSQL; a
PostgreSQL-backed listener capture is intentionally not claimed here.

`run-local-tcp-differential.sh` is the self-contained promotion gate. It
builds a frozen Go listener and the Rust listener, then starts isolated
PostgreSQL 18 and two Valkey instances. It creates independent synthetic
dashboard sessions locally; it accepts no listener URL or bearer token, so it
cannot reach production. It also seeds non-default `QuotaPerUnit=2` and
`token_setting.max_user_tokens=2` before startup.

```bash
bash rust/behavior-oracle/captures/api-token/run-local-tcp-differential.sh
```

`tcp-differential.sh` is the inner, already-running-listener probe. It drives
the real Go and Rust TCP listeners with independent synthetic dashboard
sessions, compares the redacted response sequence, and asserts the secret-read
no-store headers:

```bash
GO_BASE_URL=http://127.0.0.1:13001 RUST_BASE_URL=http://127.0.0.1:33001 \
GO_AUTH_BEARER="$go_token" RUST_AUTH_BEARER="$rust_token" \
bash rust/behavior-oracle/captures/api-token/tcp-differential.sh
```

The candidate's storage contract can be exercised before promotion with a
native disposable PostgreSQL 18 and Valkey pair:

```bash
bash rust/behavior-oracle/captures/api-token/run-pg18-valkey-integration.sh
```

It runs each ignored integration test in a fresh logical database state and
checks cache HMAC layout, TTL reset, atomic hash fields, delete replay,
owner-scope token limits, and a real PostgreSQL batch-lookup fault.

The TCP gate deliberately refuses a Rust `404` preflight. It needs the shared
listener to mount `api_token_router` behind a verified dashboard-session
extractor and to expose a separate synthetic Rust dashboard bearer token. This
is currently a production-wiring blocker, not a passing differential result.
