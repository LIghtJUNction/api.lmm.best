# API-token frozen contract

The following migration-plan routes use the legacy envelope `{"success":bool,"message":string,"data":...}`:

| Method | Path | secret response |
| --- | --- | --- |
| GET | `/api/token/` | masked `key` |
| POST | `/api/token/` | never returns generated key |
| PUT | `/api/token/` | masked `key` |
| DELETE | `/api/token/:id` | no key |
| GET | `/api/token/:id` | masked `key` |
| POST | `/api/token/:id/key` | full key under `data.key` |
| POST | `/api/token/batch` | no key |
| POST | `/api/token/batch/keys` | full keys only under `data.keys` |
| GET | `/api/token/search` | masked `key` |

All SQL selectors and mutations include `user_id` and `deleted_at IS NULL`.
Valkey cache names are `token:HMAC-SHA256(CRYPTO_SECRET, key)`, never raw
credentials. Legacy update writes a cleaned hash under that key and resets its
`SYNC_FREQUENCY` TTL; delete paths asynchronously issue an idempotent `DEL`.
Those cache side effects are best effort and never rewrite a committed database
mutation into a failure envelope.

Archived Go routing uses `UserAuth`, not `AdminAuth`. The Rust module therefore
accepts every verified dashboard user with a positive `user_id` and leaves the
application router responsible for attaching a verified `ApiTokenPrincipal`.
The two secret-read routes require the legacy no-store headers; the application
router must also provide critical/search rate limiting and the authenticated
`auth-version` response header before these unmounted routes can be promoted.
