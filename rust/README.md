# Rust migration workspace

This native (non-container) workspace is the strangler target for the Go
service. It exposes operational endpoints and implements the first read-only
business slice (`/api/notice`, `/api/about`, and `/api/home_page_content`) for
direct differential testing. The production edge still assigns every `/api/`
route to Go; Rust owns no production business traffic or writes yet.

Required environment variable names are `LMM_RS_LISTEN_ADDR`, `DATABASE_URL`,
`VALKEY_URL`, and `LMM_SCHEMA_CONTRACT`. Optional timeout names are
`LMM_DEPENDENCY_TIMEOUT_SECONDS`, `LMM_DRAIN_TIMEOUT_SECONDS`, and
`LMM_PUBLIC_CONTENT_CACHE_TTL_SECONDS`. Values and credentials must come from
systemd credentials/environment files and must not be committed.

Validation:

```bash
cd rust
cargo fmt --check
cargo clippy --all-targets --all-features --locked -- -D warnings
cargo test --all-targets --all-features --locked
./scripts/check-go-route-manifest.sh
```

`/livez` performs no dependency I/O. `/readyz` requires PostgreSQL, the schema
reader window, and read permission on every table required by an implemented
Rust slice (currently `options`); a generic `SELECT 1` is not sufficient. A
Valkey failure reports `degraded` without rejecting traffic because the cache
is non-authoritative. `/_internal/build` must be restricted by the edge or
bound to the internal deployment network.

The public-content slice reads Valkey first using versioned, bounded-TTL keys,
then falls back to the authoritative PostgreSQL `options` table on a cache miss
or cache failure. Missing and SQL `NULL` values preserve the Go behavior of an
empty string. Cache writes are best-effort and never change request success.
Production ownership cannot move until the final PostgreSQL migration and the
existing Go `GlobalAPIRateLimit` contract have Rust equivalents.
