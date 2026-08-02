# Deployment migration contract

The deployment slice owns the 19 legacy `/api/deployments` routes from the
migration plan. All are administrator-only. The listener must install
`DeploymentActor` only after the shared session/token extractor has validated
the request; caller JSON must never determine the role.

Responses retain the legacy HTTP 200 envelope for both outcomes:

```json
{"success":true,"message":"","data":{}}
```

```json
{"success":false,"message":"..."}
```

`DeploymentProvider` is the integration boundary. Its production adapter must:

1. read enabled/key state from PostgreSQL without returning the key;
2. serialize writes with a short Valkey lock;
3. persist `(actor, operation, idempotency_key) -> response` in PostgreSQL
   before lock release, returning that result for an identical retry;
4. return `InProgress` for a distinct concurrent write and never silently issue
   a second upstream create/delete/extend/rename request; and
5. treat Valkey as optional only for read caching, while persistence and the
   idempotency ledger remain authoritative in PostgreSQL.

The current module is intentionally unwired: it has no io.net client and does
not contact a provider, PostgreSQL, or Valkey. The host router needs to mount
`deployment::router(DeploymentState::new(provider))` behind the existing admin
authentication extractor, and the application layer needs to supply the
production provider adapter.
