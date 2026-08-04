# Relay misc migration contract

## Route list

Authenticated pass-through routes:

- `POST /v1/alpha/search` (`OpenAIAlphaSearch`)
- `POST /v1/embeddings` (`Embedding`)
- `POST /v1/rerank` (`Rerank`)
- `POST /v1/moderations` (`OpenAI`)

Authenticated explicit-501 routes:

- `POST /v1/images/variations`
- `GET|POST /v1/files`, `GET|DELETE /v1/files/:id`, `GET /v1/files/:id/content`
- `GET|POST /v1/fine-tunes`, `GET /v1/fine-tunes/:id`, `POST /v1/fine-tunes/:id/cancel`, `GET /v1/fine-tunes/:id/events`

The 501 body is exactly `{"error":{"message":"API not implemented","type":"new_api_error","param":"","code":"api_not_implemented"}}`.

`migration_relay_misc` freezes the complete eleven-method matrix against
`routes/legacy-go-routes.tsv`. Its mock differential proves that each request
reaches token authorization exactly once, returns the exact 501 response only
after authorization succeeds, and never invokes channel distribution or an
upstream relay. A rejected request retains the legacy authentication envelope
and likewise cannot reach relay execution.

`images/variations` and `files*` are deliberately owned here, not by the
opaque media router: legacy authorizes them and then returns this exact 501
envelope. Router construction has a focused duplicate-path guard; composition
must remove these paths from the media slice before merging the routers.

`DELETE /v1/models/:model` is owned by the Anthropic/Gemini router because it
shares Axum's `/v1/models/{*request}` path family with Gemini POST routes.

## Wiring required

Merge `migration_routes::relay_misc::routes(...)` into the `/v1` relay stack
after legacy-equivalent performance checks and before no fallback. The supplied
`RelayMiscService` adapter must perform token auth, PG-authoritative Valkey
cache lookup/fallback, rate limiting, and channel selection before `relay`.
`relay` returns an Axum `Response` directly so streamed SSE and binary upstream
responses, status codes, and headers are preserved.
