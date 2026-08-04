# Midjourney media-task contract capture

Source: legacy Go listener revision `5418ce6b6d45ed69167b0aad53f2f595e5bc8de9`.

This capture is intentionally safe: run it only with a fresh synthetic SQLite
database, a disposable Valkey, and loopback HTTP stubs.  It must never contact
a Midjourney provider, a production PostgreSQL/Valkey instance, or an account
proxy.  The fixtures are source-frozen probes for the real listener: they
define the expected observable result that the isolated listener harness must
record before a Rust differential run is accepted.

## Isolated-listener observation

The supplied isolated launcher was run on 2026-08-01.  Its host CPU sample was
98.8%, above the default 90% threshold, so `SystemPerformanceCheck` preempted
both the public image and protected task probes with the normalized 503 capture
in `isolation-performance-gate.json`.  That is a real listener observation,
not a route-handler result.  Disable the synthetic listener's performance
monitor through its isolated configuration before recording the handler-level
fixtures below; never alter host-wide limits or production configuration.

## Route boundary

All `/mj` routes first pass `RouteTag(relay)` and `SystemPerformanceCheck`.
`GET /mj/image/:id` is registered **before** `TokenAuth` and `Distribute`; it
looks up the task by `mj_id`, validates the persisted image URL for SSRF, then
streams only a 200 upstream response.  Task routes are protected by
`TokenAuth` then `Distribute`.  The supported task reads are `GET
/mj/task/:id/fetch`, `GET /mj/task/:id/image-seed`, and `POST
/mj/task/list-by-condition`; submits include `POST /mj/submit/imagine` and
the other registered `submit/*` variants.

## Stub scenarios required by the isolated harness

| Scenario | Stub result | Contract to retain |
| --- | --- | --- |
| submit success | `200 {"code":1,"description":"ok","result":"stub-job-1"}` | inserts one `midjourneys` row; charges, consume log, user/channel counters only after HTTP 200 |
| replay | `200 {"code":21,"description":"exists","result":"stub-job-1","properties":{"status":"SUCCESS","imageUrl":"http://stub/image.png"}}` | response body rewrites `code:21` to `code:1`, inserts a new task row, and charges once for this request |
| queue replay | `200 {"code":22,"description":"queued","result":"stub-job-1"}` | response body rewrites `code:22` to `code:1`, inserts a new task row, and charges once |
| upstream status | non-200 JSON body | listener preserves HTTP status/body for submit, then only inserts/charges if `code` permits and the upstream HTTP status is 200 |
| image binary | `200 Content-Type: image/png` plus fixed bytes | listener streams exact bytes and preserves only Content-Type |
| image upstream failure | non-200 body or dial failure | body is JSON `{error:<upstream-body>}` with upstream status, or 500 `{error:"http_get_image_failed"}`; no writes |

No Midjourney route is an SSE route: the service buffers JSON before writing.
`sse_frames` is consequently always empty.

## State and concurrency observations

The `Midjourney` model is persisted in the relational database; these routes
do not deliberately write Valkey keys.  Submission uses plain `Insert()` with
no unique constraint or idempotency key.  Two simultaneous identical submits
can therefore reach the stub twice and create two rows.  Task fetches are
scoped by `(user_id, mj_id)`, whereas public image lookup is scoped only by
`mj_id`.  Notify/poller updates use `Save()`; the model has a separate
`UpdateWithStatus` CAS helper, but the notify path does not use it.

The listener removes `accountFilter` and `notifyHook` before dispatch unless
their corresponding settings are enabled.  It forwards `Content-Type`,
`Accept`, and the selected channel key as `mj-api-secret`; it does not forward
the caller Authorization header upstream.
