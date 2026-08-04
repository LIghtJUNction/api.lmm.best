# Identity Profile and 2FA Draft Boundary

This note records the local implementation boundary for the frozen Go profile
and 2FA routes. It is not a migration ledger and does not authorize a
production cutover.

## Covered route surface

| Route | Boundary |
| --- | --- |
| `GET /api/user/aff` | Verified dashboard identity, PostgreSQL affiliate-code read/create, best-effort Valkey user-cache invalidation. |
| `PUT /api/user/self` | Authentication before body parsing; profile and sidebar/language preference writes use PostgreSQL. Password rotation stays owned by the session-auth component. |
| `DELETE /api/user/self` | PostgreSQL soft deletion, session revocation, auth-version increment, then Valkey auth-floor publication. |
| `PUT /api/user/setting` | Authentication before body parsing; validates the frozen notification setting fields and persists JSON settings in PostgreSQL. |
| `/api/user/2fa/*` | Parent-authenticated actor, PostgreSQL row locks and backup-code storage, auth-version advancement, Valkey publication, and a PgValkey dashboard-session rotation. The current SID, client metadata, and cookie policy must arrive in listener-injected `Identity2FASession`; no request JSON field can choose a session. |
| `GET /api/user/2fa/stats` and `DELETE /api/user/{id}/2fa` | Parent-authenticated administrator, role checks, PostgreSQL storage mutation and session revocation. |

## Current local evidence

- Auth is checked before JSON parsing for profile writes and 2FA code writes.
- Malformed unauthenticated writes retain their authentication failure envelope.
- Invalid notification settings fail before PostgreSQL access.
- 2FA enable distinguishes a missing pending enrollment from an already-enabled
  factor, matching the frozen Go handler's user-visible branch.
- A successful security change replaces the authenticated current session's
  refresh secret, increments its session version, binds it to the new
  auth-version, returns a new auth bundle, and emits the HttpOnly refresh
  cookie.  The old refresh token has no replay grace; other sessions retain the
  former auth-version and are rejected by the ordinary PostgreSQL/Valkey check.

## Still required before strict acceptance

- Isolated PostgreSQL/Valkey tests for the durable rotation success path and
  cache-publication failure fence.
- Listener wiring that injects `Identity2FASession` only after access-token
  validation; candidate routes remain test-only until that boundary is mounted.
- Frozen Go/Rust TCP differential captures for every route and error branch.
- Listener integration and production traffic ownership are outside this note.
