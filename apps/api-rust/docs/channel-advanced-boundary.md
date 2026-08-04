# Advanced channel provider boundary

`migration_routes/channel_advanced.rs` remains unmounted while the legacy
oracle is completed.  Its production composition is deliberately split into:

- `PgChannelAdvancedStore`, which loads the authoritative PostgreSQL channel
  row, including its credential, only after route authorization succeeds.
- `ReqwestChannelAdvancedUpstream`, the production HTTP implementation of the
  upstream boundary. It uses a finite timeout, disables redirects, caps
  buffered replies at 2 MiB, removes hop-by-hop headers from streamed replies,
  and derives every upstream URL and credential from the loaded channel—not a
  request body. It covers Ollama tags/version/pull/delete/pull-stream and the
  Codex WHAM usage endpoints. A PostgreSQL pool is required when persisting a
  refreshed Codex credential.
- `StoreBackedChannelAdvancedProvider`, which requires a stored channel for
  channel-addressed work and rejects invalid channel types before the upstream
  boundary is called.

The frozen Go behavior requires Codex usage operations to reject non-Codex or
multi-key channels, Ollama operations to reject non-Ollama channels, and the
root-only key route to read the stored key without contacting an upstream.
`POST /api/channel/fetch_models` is the exception: `channel_id` zero or absent
is a preview request and must not be treated as a persisted channel lookup.

This slice must not be mounted until its remaining bulk test/balance and
upstream-update operations have their PostgreSQL/Valkey post-commit semantics
implemented and the aggregate route gate approves it.
