# Rust migration workspace

This native (non-container) workspace is the strangler target for the Go
service. Its root router currently mounts 20 frozen method/path pairs across
public content, status, authentication, model discovery, and API-token slices.
Additional migration modules are compiled as candidates without being mounted.
The production edge still assigns all 356 frozen routes to Go; Rust owns no
production business traffic or writes yet.

Required environment variable names are `LMM_RS_LISTEN_ADDR`, `DATABASE_URL`,
`VALKEY_URL`, and `LMM_SCHEMA_CONTRACT`. `DATABASE_URL` must select the exact
versioned application schema with
`options=-csearch_path%3D<versioned_schema>`; the schema-contract installer
rejects `public`. Optional timeout names are
`LMM_DEPENDENCY_TIMEOUT_SECONDS`, `LMM_DRAIN_TIMEOUT_SECONDS`, and
`LMM_PUBLIC_CONTENT_CACHE_TTL_SECONDS`. The public-content cache TTL must be an
integer from 1 through 5 seconds; zero, larger values, and malformed values
fail configuration loading instead of being silently clamped. Values and
credentials must come from systemd credentials/environment files and must not
be committed.

The public `/api` migration boundary also consumes the Go-compatible
`GLOBAL_API_RATE_LIMIT_ENABLE`, `GLOBAL_API_RATE_LIMIT`, and
`GLOBAL_API_RATE_LIMIT_DURATION` settings (defaults: enabled, 360 requests,
180 seconds).

Validation:

```bash
cd rust
cargo fmt --check
cargo clippy --all-targets --all-features --locked -- -D warnings
cargo test --all-targets --all-features --locked
./scripts/check-go-route-manifest.sh
./scripts/check-draft-route-coverage.sh
```

`routes/legacy-go-routes.tsv` is the immutable 356-route compatibility oracle
frozen from the final indexed Go router. Its SHA-256 is tracked separately, so
route validation remains Go-independent after the source moves to the ignored
local backup. `routes/rust-implemented-routes.tsv` records implementation
coverage; it does not claim production traffic ownership.

The draft coverage checker currently finds Rust handlers for 300 of the 356
frozen method/path pairs (84.3%), leaving 56 without a candidate. This is only
static implementation evidence: it does not grant differential-verification
credit, root mounting, or production ownership. Run it after every candidate
wave instead of copying this snapshot into an ownership decision.

`/livez` performs no dependency I/O. `/readyz` always requires PostgreSQL, the
schema reader window, and read/capability checks for every currently mounted
slice: public/status tables (`options`, `custom_oauth_providers`, `setups`) and
auth tables (`users`, `user_sessions`, `two_fas`, `casbin_rule`) plus prepared
`auth_flows` insert/update capability. The mounted API-token routes additionally
require the complete `tokens` column shape and prepared `INSERT` (including the
owned ID-sequence default), `UPDATE`, and `DELETE` capability. These are all
`EXPLAIN` checks and therefore never write readiness rows. A generic `SELECT 1`
is not sufficient.
Valkey is also required when global API rate limiting is enabled,
because that policy fails closed; a Valkey failure then returns HTTP 503. When
the limiter is disabled, Valkey is only non-authoritative cache acceleration,
so its failure returns HTTP 200 with `degraded`. All checks run concurrently.
`/_internal/build` must be restricted by the edge or bound to the internal
deployment network.

The public-content slice reads Valkey first using versioned, bounded-TTL keys,
then falls back to the authoritative PostgreSQL `options` table on a cache miss
or cache failure. Missing and SQL `NULL` values preserve the Go behavior of an
empty string. `LMM_DEPENDENCY_TIMEOUT_SECONDS` bounds each complete cache get,
authoritative PostgreSQL read, and best-effort cache put operation. Cache get
timeouts fall back to PostgreSQL, PostgreSQL timeouts return the existing safe
public-content error, and cache put timeouts never change request success.
Production ownership cannot move until the final PostgreSQL migration and a
shared-Valkey differential rehearsal prove the Go and Rust limiter boundaries
operate as one policy.

The Rust global API limiter now uses the same Valkey fixed-window Lua behavior,
`rateLimit:v2:ip:GA:<client-ip>` namespace, empty 429 response, and
`Retry-After` semantics as Go. Valkey errors fail closed with the same empty
500 response. The dependency timeout bounds the enabled limiter's complete
Valkey connection plus Lua operation; a timeout also produces the empty 500.
The disabled limiter returns `Allowed` before touching Valkey. Only a loopback
peer may supply `X-Real-IP`; other peers are keyed by their socket address and
cannot spoof the proxy header. Partial route ownership still requires Go and
Rust to use the same dedicated Valkey instance so one client cannot receive
independent allowances from each backend.

Deterministic unit tests exercise timeout behavior with pending futures. A
server-backed half-open Valkey fault-injection test is still a staging
integration gate; the repository test suite does not claim to emulate that
network condition.
