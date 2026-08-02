# Control-public implementation evidence

This work slice implements the frozen anonymous routes omitted from the status
and generic public-content migration slices:

- `GET /api/uptime/status`
- `GET /api/user-agreement`
- `GET /api/privacy-policy`

The routes must be merged beneath the shared `/api` request boundary so the
legacy global rate limiter, generated request headers, and JSON content type
still apply. They do not mutate PostgreSQL or Valkey.

`/api/uptime/status` reads `console_setting.uptime_kuma_groups`. Missing or
malformed configuration returns `data: []`. Groups run concurrently, retain
their configured order, and each group fetches the status page and heartbeat
page concurrently. A timeout, transport failure, non-200 response, or decode
failure leaves only that group's `monitors: []`; the aggregate remains
`200 {success:true,message:"",data:[...]}`. The per-request deadline is 30 s;
each Uptime Kuma request has a 10 s deadline.

The legal routes read `legal.user_agreement` and `legal.privacy_policy` and
return an empty string for an absent option, matching the Go settings defaults.
An authoritative option-store failure is a Rust readiness/dependency failure
and returns a 500 JSON failure instead of serving stale cache data.
