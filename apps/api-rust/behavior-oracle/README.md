# Legacy route behavior oracle

This directory captures observable HTTP contracts from the ignored Go backup at
revision `5418ce6b6d45ed69167b0aad53f2f595e5bc8de9`. The oracle must only run with a
fresh synthetic SQLite database, a dedicated disposable Valkey instance, and
mock upstreams. Production databases, caches, credentials, and upstreams are
out of scope.

Each fixture records status, selected key headers, normalized JSON body or SSE
frames, database row differences, Valkey key differences, and an explicit
allowlist of dynamic fields that may be normalized. A missing normalization rule
is a meaningful contract difference. The capture tool compares row updates by
stable `id`, `sid`, or `key` where available; it does not collapse updates into
an insert/delete pair.

Run `tests/check-fixtures.sh` to validate the eight bootstrap fixtures. Use
`apps/api-rust/scripts/run-route-differential.sh` with distinct loopback `GO_BASE_URL`
and `RUST_BASE_URL` values to replay them against both implementations.

The 27 `external-gateway` rows in `tests/missing-routes-matrix.tsv` have a
separate loopback-only contract in
`tests/missing-routes-external-gateway-fixtures.json`. Run
`tests/test-missing-routes-external-gateway-fixtures.sh` to keep its route
inventory, mock request/response, signature, replay, and durable-effect
expectations aligned with the matrix. It validates fixture shape only; Rust
adapter tests provide the actual local mock HTTP execution evidence.

`run-route-differential.sh` refuses an effectful fixture unless both listeners
have isolated snapshot backends for every required database or Valkey effect.
Set `ROUTE_REQUIRE_EFFECTS=strict` to require snapshots for all declared
observations; this is the only mode suitable for differential verification.
The auth and models listener harnesses provision PostgreSQL 18 plus two isolated
Valkey instances with synthetic values. They do not read developer credentials.
An HTTP-only replay is transport evidence only and cannot create migration or
production ownership credit.

The direct PostgreSQL/Valkey Rust tests are deliberately ignored during a
normal Cargo test run. Use apps/api-rust/scripts/run-real-integration-gates.sh for
auth, models, or api-token; it requires loopback-only isolated URLs (and the
auth reset acknowledgement) before invoking the ignored test. Missing
environment is a failure, never a skipped green result.
