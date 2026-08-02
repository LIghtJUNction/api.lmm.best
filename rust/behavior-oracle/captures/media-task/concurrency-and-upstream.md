# Replay, concurrency, and upstream-failure probes

Use the real Go listener with one disposable channel pointing at a loopback
stub.  Seed one user/token/channel and collect relational-table and Valkey
key diffs before and after every request.  The following checks complement the
JSON route fixtures because each has two requests or a fault injection point.

1. Send the same valid imagine request twice, sequentially, while the stub
   returns code 21. Expect two `midjourneys` rows (no idempotency/dedup guard),
   two quota charges/logs/counter updates, and a client-facing code of 1 on
   both requests.
2. Send two valid imagine requests concurrently with a barrier in the stub.
   Expect two upstream requests and two insert attempts.  Record database
   uniqueness failure if the deployment schema added an external unique index;
   the Go `Midjourney` model itself defines no unique constraint.
3. Return a timeout/dial failure from the submit stub. Expect HTTP 400 from
   `RelayMidjourney`, JSON `{code:5, description:"do_request_failed ",
   type:"upstream_error"}`, and no task/quota/log/counter writes.
4. Return a syntactically invalid upstream body. Expect HTTP 400, code 5,
   description `unmarshal_response_body_failed `, no writes.
5. For image proxy, return 503 with `temporary image failure`. Expect 503
   JSON `{error:"temporary image failure"}` and no writes. Return a dial
   failure and expect 500 `{error:"http_get_image_failed"}`. Both remain
   unauthenticated routes, but URL validation must run before the upstream GET.
6. Seed an in-progress task and fetch it twice. Expect no writes; when
   `MjForwardUrlEnabled` is true, each response has an image URL ending in a
   different `?rand=<nanoseconds>` value. Normalize that query value only.

The submit helper buffers the upstream JSON (`io.ReadAll`) and writes it once;
there are no streaming/SSE frames to preserve.  It also drops `notifyHook` and
`accountFilter` unless their feature flags are enabled; assert their absence
at the stub rather than relying on client response shape.
