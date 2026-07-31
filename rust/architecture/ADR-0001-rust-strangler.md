# ADR-0001: Rust strangler and state ownership

Status: accepted for the migration period

## Decision

The Go and Rust services coexist behind one same-origin edge. Routes move one
vertical slice at a time and the tracked Gin route manifest is the migration
ledger. A route has exactly one active implementation and one write owner;
traffic splitting never causes both versions to execute a mutation.

The route baseline records method, path, final Gin handler, explicit ownership
metadata, and hashes of all router/middleware source. Gin does not expose its
full middleware chain through `Routes()`, so auth, body-limit and streaming
changes are detected conservatively through source drift and require a human
ownership review; the manifest does not claim semantic middleware parsing.
Ownership rules have explicit priorities and exact/prefix match semantics. CI
requires every registered Go route to have exactly one highest-priority owner;
unmatched routes, same-priority ambiguity, and dead rules fail validation.

PostgreSQL is the sole durable source of truth. Valkey is non-authoritative:
cache loss must affect latency, never correctness, identity, quota, or billing.
Every cache value is namespaced, versioned, bounded by TTL where appropriate,
and reconstructible from PostgreSQL.

Database changes use expand/contract migrations compatible with the active and
previous binary. The migration runner is a separate singleton; neither blue nor
green application instance runs schema migration at startup. Readiness checks
PG, Valkey and the `lmm_schema_contract` reader window before the edge can route
traffic. Liveness checks process health only.

Background writers and schedulers retain a single leased owner until they are
explicitly migrated. A blue/green switch first warms and verifies green, moves
new requests atomically, drains in-flight HTTP/SSE/WebSocket work, then retires
blue. The edge does not retry non-idempotent requests.

## Consequences

- Go remains the compatibility fallback while Rust gains routes.
- Shared-table writes require an explicit ownership handoff and rollback plan.
- Valkey cannot sit transactionally “between” the API and PG; cache-aside and
  durable outbox/invalidation patterns preserve PG authority instead.
- Schema compatibility is machine-checkable rather than inferred from process
  startup.
