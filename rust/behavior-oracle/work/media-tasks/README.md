# Media-task route implementation notes

This slice owns the sixteen static `/mj` rows in `migration-plan.tsv`: public
`GET /mj/image/:id`, twelve submit forms (including the legacy
`/mj/insight-face/swap` form), two task reads, and task list-by-condition.

It also owns static task forms that were previously absent from the Rust
router: `POST /suno/fetch`, `GET /suno/fetch/:id`,
`POST /suno/submit/:action`, Kling image/text-to-video submits and fetches,
and `POST /jimeng/`.

`media_tasks.rs` has a deliberately narrow service boundary.  The HTTP layer
itself rejects missing or malformed `Authorization: Bearer ...` values before
the service is invoked; its shared production adapter must still validate the
credential and provide the following before this router is mounted:

1. Protected routes: legacy TokenAuth and Distribute, then channel selection.
2. Submit routes: sanitize disabled `accountFilter`/`notifyHook`; buffer JSON;
   insert `midjourneys` and apply the PostgreSQL quota/log/user/channel effects
   only after an HTTP 200; replay codes 21 and 22 become client code 1.
3. Read routes: scope `midjourneys` lookup by `(user_id, mj_id)` and make no
   PostgreSQL or Valkey writes.
4. Public image route: lookup by `mj_id`, reject unsafe upstream addresses
   before connecting, and preserve successful binary bytes plus `Content-Type`.
   It is intentionally unauthenticated and has no PostgreSQL/Valkey writes.

No route in this surface is SSE. Differential tests must use loopback-only
mock upstreams and disposable PostgreSQL/Valkey; never point the migration
harness at a real provider, production database, or cache.
