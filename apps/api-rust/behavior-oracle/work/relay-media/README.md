# Relay media migration evidence

The Rust slice keeps media requests opaque until the authenticated relay
service. `MediaUpstreamClient` is a real reqwest/rustls streaming client: it
removes caller Authorization, injects the selected channel credential, retains
multipart boundaries, strips standard and `Connection`-nominated hop-by-hop
request headers, filters hop-by-hop response headers, and exposes the upstream
byte stream without buffering it. It bounds response-header latency and only
retries when the caller has an explicit idempotency policy.

The integration test uses a local TCP upstream to verify delayed chunked SSE,
credential replacement, multipart preservation, and non-idempotent timeout
behaviour. `images/variations` and `files*` are intentionally absent: the
legacy listener authenticates then returns 501 for those paths, owned by
`relay_misc`.

The route-level mock differential enumerates all eleven explicit-501 media,
file, and fine-tune methods and proves this opaque forwarding slice answers
404 without invoking its service for every one. Composition therefore has a
single owner: `relay_misc` supplies their authenticated exact-501 response.

The still-unmounted production service must own legacy token authorization,
PostgreSQL quota/log transaction, and Valkey cache/rate-limit effects before it
calls the selected upstream channel. This slice is not eligible for production
ownership until that shared service is injected and real-listener PG/Valkey
differential cases pass.
