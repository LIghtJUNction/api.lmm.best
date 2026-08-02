# Worker 37: relay/media streaming audit

Date: 2026-08-01 (Asia/Shanghai)

Scope: read-only audit of the Rust migration relay/media surfaces.  No source,
fixture, manifest, ledger, or Git state was changed.  Test services are local
in-process stubs; no production credentials, databases, Valkey instances, or
external upstreams were contacted.

## Result

**BLOCKED / not ready for real-listener validation.**  The executable listener
does not mount either the OpenAI relay router or the media relay router, so the
only actual TCP listener cannot expose these routes.  Separately,
`migration_relay_openai` does not compile due to syntax errors in
`relay_openai.rs`.  As a result, real-listener checks for SSE framing,
disconnect/backpressure, upstream-error mapping, and concurrent relay clients
could not truthfully be performed.

## Evidence and findings

1. **P0: relay and media routes are not integrated into the production listener.**
   `main.rs` starts `axum::serve` with `http::router_with_web`.  That router
   merges only dashboard auth and models routers; it does not import or merge
   `openai_relay_router`, `relay_media_router`, or `relay_misc::routes`.
   Therefore a real TCP request to any audited `/v1` relay/media path reaches
   the fallback rather than a safe relay stub.  This blocks all requested
   real-listener cases, including disconnect and slow-reader/backpressure
   behavior.

   Relevant source observed:

   - `rust/apps/lmm-api-rs/src/main.rs:68-73`
   - `rust/apps/lmm-api-rs/src/http.rs:76-97`
   - `rust/apps/lmm-api-rs/src/migration_routes/relay_media.rs:45-60`

2. **P0: OpenAI relay integration test target currently fails to compile.**
   The attempted test command reports parser errors at
   `relay_openai.rs:222` and `:238`; both are `return legacy_error(...)` calls
   closed with `);` rather than the required expression terminator.  The same
   compilation also reported an invalid `?` use in `serialize_complete` at the
   then-current line 260.  The source changed during this shared-workspace
   audit, so this finding is tied to the exact command output below rather than
   presented as a stable line snapshot.

3. **PASS (limited, in-process): opaque media parity.**
   `migration_relay_media` passed all four tests using an in-memory upstream
   stub.  Coverage confirms one multipart image-edit request retained its
   original bytes, multipart boundary, and Authorization header, and confirms
   binary audio/file response bodies plus status and an upstream request-id
   header pass through.  It also covers the eight declared audio/image/file
   route-method combinations.  This is not TCP-level streaming coverage; the
   stub consumes the request body fully and returns buffered bodies.

4. **PASS (limited, in-process): misc binary error forwarding.**
   `migration_relay_misc` passed three tests, including an authorized upstream
   `502` with `audio/mpeg`, `x-upstream-request-id`, and arbitrary binary
   bytes.  This demonstrates response pass-through at that adapter boundary,
   not an actual upstream HTTP connection.

5. **PASS (contract conversion only): ordered canonical stream conversion.**
   The contracts crate passed all eight tests matching `stream`, including
   frame-order, response-event sequence, tool/error/cancellation, and rich
   inbound response tests.  These do not exercise HTTP SSE flushing,
   disconnect propagation, or client backpressure.

6. **PASS (limited, in-process): Anthropic/Gemini route basics.**
   Two adapter tests pass: Anthropic streaming returns an SSE content type and
   channel header; Gemini rejects a missing token.  The tests do not consume
   and order actual emitted frame bytes.

## Exact commands and logs

```text
cwd=/home/lightjunction/Documents/GITHUB/api.lmm.best
codegraph explore "Integrated relay and media routes streaming SSE multipart binary handlers tests"
codegraph explore "rust lmm-api-rs integrated relay media routes upstream SSE forwarding multipart binary request headers errors disconnect tests"

cwd=/home/lightjunction/Documents/GITHUB/api.lmm.best/rust
cargo test -p lmm-api-rs --test migration_relay_media --test migration_relay_openai --test migration_relay_anthropic_gemini -- --nocapture
  FAIL: migration_relay_openai compile errors:
    expected one of `)`, `,`, `.`, `?`, or an operator ... relay_openai.rs:222:22
    expected one of `.`, `;`, `?`, `}`, or an operator ... relay_openai.rs:238:22
    E0277: `?` cannot be applied to Converted<OpenAiChatResponse> ... relay_openai.rs:260:52

cargo test -p lmm-api-rs --test migration_relay_media -- --nocapture
  PASS: 4 passed; 0 failed

cargo test -p lmm-api-rs --test migration_relay_misc -- --nocapture
  PASS: 3 passed; 0 failed

cargo test -p lmm-contracts stream -- --nocapture
  PASS: 8 passed; 0 failed; 13 filtered out

cargo test -p lmm-api-rs --test migration_relay_anthropic_gemini -- --nocapture
  PASS: 2 passed; 0 failed
```

## Required follow-up to make the requested audit executable

1. Assemble the relay/media routers in the real `router_with_web` path, with
   explicit dependency-injected authorization/relay services.
2. Restore compilation of `migration_relay_openai`.
3. Add a disposable TCP-listener test harness with a local stub upstream.  It
   should capture header/body parity, emit delayed SSE frames, simulate a
   mid-stream upstream failure, observe client disconnect cancellation, and
   issue concurrent requests with isolated request IDs.  Only then can
   ordering, `[DONE]` termination, flushing, disconnect/backpressure, and
   error mapping be asserted end-to-end.
