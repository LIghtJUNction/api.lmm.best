# Channel listener captures

These are read-only captures of the ignored Go listener at
`5418ce6b6d45ed69167b0aad53f2f595e5bc8de9`.  Each run used
`run-isolated-oracle.sh`, created a fresh SQLite database and an empty,
dedicated Valkey instance, then initialized the synthetic root account through
`POST /api/setup`.  No shared database, cache, credentials, or upstream was
contacted.

`channel-family.json` records the observed authenticated CRUD/status/multi-key
responses and the failure paths that are deterministic without a real upstream.
It deliberately separates observations from source-derived route notes: a route
whose downstream needs a mock HTTP server is not presented as a captured
success response.

Important replay facts:

- All `/api/channel` routes first require dashboard admin authentication; an
  absent or invalid bearer credential is HTTP 401 with the standard JSON error.
- Write paths create an audit log row and rebuild the in-process channel cache.
  This isolated run did not add a channel-named Valkey key.
- Repeating `disable_key` is accepted and returns the same success response;
  the persisted key state remains manually disabled.
- `UpdateChannelBalance` rejects a multi-key channel before making an upstream
  request.  Codex refresh returns HTTP 200 with `success:false` on credential
  refresh failure.

Ollama pull/delete/version and upstream-model detect paths require a local mock
upstream to freeze their success/error body and stream frames.  Their route,
authorization, and persistence boundary are recorded in `pending-upstreams` so
that a later capture cannot silently substitute a live provider.
