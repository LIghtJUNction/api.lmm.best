# Channel TCP differential replay

This is the frozen replay procedure for the production channel boundary. Run it
only after the host has composed the route slice with dashboard identity,
secure-key verification, rate-limit, audit, and legacy-header middleware.

When the host mounts the route slice, run only against disposable backends:

```sh
ROUTE_REQUIRE_EFFECTS=strict \
GO_BASE_URL=http://127.0.0.1:13020 \
RUST_BASE_URL=http://127.0.0.1:33020 \
GO_SQLITE_PATH=/tmp/lmm-channel-go.sqlite \
GO_REDIS_URL=redis://127.0.0.1:16390 \
RUST_POSTGRES_URL=postgresql://lmm_channel@127.0.0.1:55490/channel \
RUST_REDIS_URL=redis://127.0.0.1:56390 \
rust/scripts/run-route-differential.sh rust/behavior-oracle/fixtures/channel
```

Required cases are authenticated CRUD, batch delete, status 1/2, tag mutation,
multi-key replay, malformed/unauthorized inputs, and snapshots of `channels`,
`abilities`, audit rows, and `lmm:channels:generation`. Channel-test, balance,
Ollama, Codex, fetch-model, and upstream-model-update cases additionally need
loopback mock HTTP servers. Never point the replay at a production database,
Valkey, credentials, or third-party provider URLs.
