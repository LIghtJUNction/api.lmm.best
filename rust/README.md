# Rust migration workspace

This native (non-container) workspace is the first strangler slice for the Go
service. It currently exposes only operational endpoints; it owns no business
routes or writes.

Required environment variable names are `LMM_RS_LISTEN_ADDR`, `DATABASE_URL`,
`VALKEY_URL`, and `LMM_SCHEMA_CONTRACT`. Optional timeout names are
`LMM_DEPENDENCY_TIMEOUT_SECONDS` and `LMM_DRAIN_TIMEOUT_SECONDS`. Values and
credentials must come from systemd credentials/environment files and must not
be committed.

Validation:

```bash
cd rust
cargo fmt --check
cargo clippy --all-targets --all-features --locked -- -D warnings
cargo test --all-targets --all-features --locked
./scripts/check-go-route-manifest.sh
```

`/livez` performs no dependency I/O. `/readyz` requires PostgreSQL and the
schema reader window; a Valkey failure reports `degraded` without rejecting
traffic because the cache is non-authoritative. `/_internal/build` must be
restricted by the edge or bound to the internal deployment network.
