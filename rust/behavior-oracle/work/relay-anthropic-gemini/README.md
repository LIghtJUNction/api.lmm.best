# Anthropic and Gemini relay contract notes

This slice covers the migration-plan relay rows for `POST /v1/messages` and
the stable/beta Gemini `:generateContent` and `:streamGenerateContent` forms.
It has no permissive production default. Composition must provide a
`RelayBackend` that authenticates legacy tokens, selects enabled abilities,
performs retrying upstream transport, translates provider events, and commits
usage/channel-health outcomes. Tests define an explicit in-memory backend;
there is no `StubRelayBackend` available for production wiring.

The HTTP boundary includes the legacy `POST /v1/engines/:model/embeddings`
Gemini form in addition to the dynamic `/v1/models/*` and `/v1beta/models/*`
wildcards. It authenticates before consuming or parsing the request body. The
wildcard is intentionally not limited to `generateContent`: it derives the
model from the segment after `/models/`, preserves the exact credential-free
request path for the executor, and lets the selected channel/provider adapter
handle the action. This matches the legacy router and keeps operations such as
`countTokens`, `embedContent`, and future provider actions from becoming an
HTTP-layer 400.

The `/v1/models/{*request}` Axum method router is also the sole owner of
`DELETE /v1/models/:model`: DELETE accepts exactly one model segment, runs the
token-auth boundary only, then returns the frozen OpenAI 501 envelope. It must
not select a channel, record a channel outcome, or add the channel response
header. This prevents an overlapping wildcard route during final router
composition.

## TCP differential status

The slice has a real-TCP Rust test for the frozen valid-token DELETE 501
envelope, including status, content type, and body. A real Go-versus-Rust
listener differential is blocked deliberately: `main`/`http` do not yet mount
any relay router, and the production PostgreSQL/Valkey relay executor is not
implemented. Such a test must be added only after composition supplies the
real auth, channel, billing, retry, and streaming dependencies; an in-memory
test backend is not evidence of those production effects.
Gemini accepts `Authorization: Bearer`, `x-goog-api-key`, and the legacy
`?key=` query credential; Anthropic also accepts `x-api-key`. The executor
receives the decoded JSON plus original bytes so each retry can replay the
caller payload exactly. Named Anthropic SSE event names are retained alongside
their JSON `data:` payloads. Gemini requests are streaming for either a
`streamGenerateContent` action or `alt=sse`, precisely as the frozen Go
`GeminiChatRequest.IsStream` implementation specifies. JSON `null` values are
not coerced or rejected by this boundary; they are passed to the executor or
framed as `data: null` for an SSE reply.

`captures/relay/anthropic-gemini-contract.json` records the source-traced
dynamic-route, stream, nullable-value, and protocol-error expectations. The
Rust integration tests use a capturing backend to compare that boundary
metadata without claiming that a mock has exercised PostgreSQL, Valkey, billing,
or a real upstream.
