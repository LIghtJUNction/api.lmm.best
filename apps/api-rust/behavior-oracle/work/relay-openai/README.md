# OpenAI priority relay migration notes

The Rust HTTP boundary is `apps/lmm-api-rs/src/migration_routes/relay_openai.rs`.
It parses only the typed Chat Completions and Responses DTOs, converts them to
`lmm_contracts::relay::CanonicalRequest`, and converts completed canonical
responses or canonical stream events back to the caller's OpenAI dialect.

Its `OpenAiRelayService` port is deliberately responsible for the legacy
read-write behavior: token authentication, model rate limit, channel selection
and retry, upstream transport, pre/post billing, usage logging, channel health,
and every PostgreSQL/Valkey effect. The HTTP module does not substitute a
best-effort cache decision for an authoritative database decision.  After
selection, `OpenAiUpstreamClient` is the concrete OpenAI-compatible wire
adapter: it replays the retained bytes to the selected channel, replaces the
tenant credential with the channel credential, streams successful JSON or SSE
without re-encoding it, and maps non-success/transport responses into the
typed failure consumed by the lifecycle owner.

The boundary now includes the legacy `POST /v1/completions` and
`POST /v1/responses/compact` endpoints as distinct executor endpoint values.
Every typed request also carries its original JSON bytes: provider-specific
fields and a byte-exact retry payload are available to the production
executor. Successful JSON output is explicitly `application/json;
charset=utf-8`, rather than Axum's default text response type.

The frozen unauthenticated fixtures remain the acceptance baseline:

* invalid token is `401` with the OpenAI `new_api_error` envelope;
* `x-new-api-version` and `x-oneapi-request-id` are present;
* no relay service call, upstream call, database mutation, or Valkey mutation
  occurs before token authentication rejects the request.

For success paths, the adapter must deliver terminal canonical stream events
and commit/refund its usage side effects before resolving the service future.
Chat streams serialize as `data:` JSON frames followed by `[DONE]`; Responses
streams serialize named `event:` frames followed by `[DONE]`.

## Wire-adapter mock differential

The module-level mock listener tests keep the concrete adapter separate from
the unfinished database lifecycle. They verify that a selected channel receives
the exact original JSON bytes at the matching route, never the tenant bearer
credential, and receives the selected channel credential instead. They also
compare returned bytes exactly for both JSON and `text/event-stream`, so unknown
provider fields and SSE frames cannot be silently re-serialized. A mock 429
OpenAI error verifies status, `error.code`, `error.message`, and `Retry-After`
propagation into the lifecycle-facing failure.

## Composition still required

1. Export `migration_routes::relay_openai` from the library and merge
   `openai_relay_router` into the shared HTTP router.
2. Implement `OpenAiRelayService` with the PostgreSQL/Valkey channel and
   billing adapters, preserving the legacy body-replay/retry order and calling
   `OpenAiUpstreamClient` only after that lifecycle work has selected a target.
3. Extend the disposable oracle with authenticated selected-channel, upstream
   error/retry, and success/usage fixtures before enabling the routes.
