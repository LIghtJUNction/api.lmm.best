# Midjourney dynamic media-task migration evidence

The Rust slice owns every `/:mode/mj` path from the migration plan.  It buffers
task JSON (never SSE), authenticates every task route, and keeps `image/:id`
public only after a persisted URL passes the local SSRF guard.

`PgMidjourneyBackend` is the production adapter. Its constructor requires a
PostgreSQL 18 pool, a `reqwest` rustls client, the selected channel's id/base
URL/key/per-submit quota, a response-header timeout, and a bounded response size. It validates
the bearer token against active token/user rows, scopes task reads by
`(user_id, mj_id)`, forwards only `Content-Type`/`Accept` plus server-side
`mj-api-secret`, and records accepted submits in one PostgreSQL transaction.
Midjourney deliberately creates no task-specific Valkey keys; the outer
token/distribution layer remains responsible for its Valkey cache and limits.

The adapter is deliberately still unmounted. Wiring must inject the channel
selected by the shared distributor; it must not create this adapter with an
arbitrary client-supplied base URL or register these routes as completed.

The integration tests cover replay normalization (`21`/`22` becomes `1`), no
effect on non-200 upstream responses, concurrent duplicate submissions, binary
image preservation, and protected task reads. Their mock backend is test-only;
no stub backend is exported by the deployed route module.
