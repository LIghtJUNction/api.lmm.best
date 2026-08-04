# Media route checkpoint

Date: 2026-08-01 (Asia/Shanghai)

## Result

**Not mounted and not eligible for production ownership.** The route slice has
real outbound HTTP components and route-level contracts, but the shared
listener has not injected its token/distribution/accounting service. No route
ledger entry was changed.

## Verified locally

`CARGO_TARGET_DIR=/tmp/lmm-media-check cargo test --offline -p lmm-api-rs --test
migration_media_midjourney --test migration_media_tasks --test
migration_relay_media`

- `migration_media_midjourney`: 7 passed
- `migration_media_tasks`: 5 passed
- `migration_relay_media`: 6 passed

The TCP mock upstream emits two delayed chunked SSE frames. The test verifies
that the client streams their exact bytes, preserves `Content-Type`, removes
the caller bearer token, injects the channel credential, retains a multipart
boundary, and does not retry a non-idempotent timed-out POST. The media router
also rejects variations/files paths instead of forwarding them; their frozen
authenticated-501 owner is `relay_misc`.

A second TCP mock invokes `PgMidjourneyBackend` through its real reqwest
adapter (using a lazy, unopened PostgreSQL pool): it verifies the exact
`POST /submit/imagine` conversion, `mj-api-secret` injection, caller bearer
credential removal, and `Content-Type`/`Accept` forwarding.

## Remaining wiring and differential gaps

1. The main listener must select an eligible channel and inject its id/base
   URL/key/quota into `PgMidjourneyBackend` and `MediaUpstreamClient`; it must never
   accept an upstream target from a client request.
2. The outer service must provide TokenAuth, channel distribution, PostgreSQL
   quota/log/counter rules, and Valkey cache/rate-limit effects for static
   Suno/Kling/Jimeng and OpenAI media paths before they are mounted.
3. Run a real Go/Rust TCP differential using disposable PostgreSQL 18 and
   Valkey for selected channel, invalid/expired token, owner miss, accepted
   replay, upstream 4xx/5xx, timeout/retry, binary image, and delayed SSE.
   There is intentionally no environment-variable skip that marks this pass.
4. Focused strict clippy is currently blocked by unrelated shared crate errors
   in `channel_core`, `identity_admin`, `identity_federation`, and `models`.
   The media files produced no clippy diagnostic before those crate-wide
   blockers were emitted.
