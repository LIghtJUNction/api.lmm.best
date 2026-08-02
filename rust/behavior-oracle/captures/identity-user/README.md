# identity-user legacy behavior capture

## Scope and reproduction

This is a read-only contract capture of the legacy Go revision
`5418ce6b6d45ed69167b0aad53f2f595e5bc8de9`, not a Rust implementation.
It was collected on 2026-08-01 with the existing isolated runner:

```bash
rust/behavior-oracle/run-isolated-oracle.sh bash -lc '<scenario commands>'
```

The runner copies the legacy source to a fresh `/tmp` directory, starts a
dedicated Valkey at `127.0.0.1:16379`, and sets `SQLITE_PATH` to a fresh
database. The scenario registers `oracle_user` with a synthetic password;
that value, issued access tokens, refresh cookies, TOTP secret, QR URI, backup
codes, session IDs, and hash values are deliberately redacted below. Re-run
with a new temporary user; do not use real credentials.

The migration plan contains **67** `identity-user` method/path rows. This
capture exercised **23 distinct paths (34%)**, with 31 request cases including
unauthorized, validation/error, replay, and concurrency cases.

## Observed contracts

All JSON examples are exact shape/value except the explicitly redacted or
dynamic fields. Selected headers not shown were absent. Successful legacy
handlers generally return HTTP 200 even when `success` is `false`.

| Method and path | Request / case | Status and selected headers | JSON / durable effects |
| --- | --- | --- | --- |
| `POST /api/user/register` | JSON `username`, `password`, `password2` | `200`, `Content-Type: application/json; charset=utf-8` | First call: `{"success":true,"message":""}`. Duplicate: `{"success":false,"message":"Username already exists or has been deleted"}`. Inserts a normal enabled user with default group, generated 4-char affiliate code, `auth_version=1`. |
| `POST /api/user/login` | wrong password | `200`, `Cache-Control: no-store, no-cache, must-revalidate, private, max-age=0` | `{"success":false,"message":"Username or password is incorrect, or user has been banned"}`; no session row. |
| `POST /api/user/login` | valid password | `200`, `Cache-Control` as above; `Set-Cookie: new_api_refresh=<REDACTED>; Path=/api/user/auth; Max-Age=2591999; HttpOnly; SameSite=Strict` | `data` has `access_token`, `token_type:"Bearer"`, `access_expires_at`, `session`, and safe user DTO. Creates one `user_sessions` row (`version=1`, `status=active`, refresh hash only) and Valkey session/user cache hashes with TTL 60 seconds. |
| `GET /api/user/self` | no authorization | `401` | `{"success":false,"code":"AUTH_UNAUTHORIZED","message":"Unauthorized, invalid access token"}`. |
| `GET /api/user/self` | `Authorization: Bearer <access>` | `200`, `Auth-Version: <dynamic hash>` | Safe DTO includes identity, quota, affiliation, setting and computed permissions; omits password, access token and remark. No row mutation. |
| `GET /api/user/models?group=missing` | authenticated | `200`, `Auth-Version` | `{"success":true,"message":"","data":[]}` on clean database; an unknown group does not error. |
| `GET /api/user/groups` and `GET /api/user/self/groups` | public / authenticated | `200`; authenticated form also `Auth-Version` | Both returned default and vip groups: `{"default":{"desc":"默认分组","ratio":1},"vip":{"desc":"vip分组","ratio":1}}`. |
| `GET /api/user/aff` | authenticated | `200`, `Auth-Version` | `data` is the user affiliate code string. |
| `PUT /api/user/self` | JSON `{"language":"en"}` | `200`, `Auth-Version`, no-store cache header | `{"success":true,"message":"Update successful","data":null}`. Updates the JSON `setting` column only (adds `language:"en"`). |
| `GET /api/user/sessions` | dashboard access token | `200`, `Auth-Version`, no-store cache header | One safe session object, including `sid`, `current`, method, IP/UA and epoch times; refresh hashes are not returned. |
| `POST /api/user/sessions/revoke-others` | dashboard access token | `200`, `Auth-Version`, no-store cache header | `{"success":true,"message":"","data":{"revoked_count":0}}` with only current session. |
| `POST /api/user/auth/refresh` | refresh cookie plus matching `X-Auth-Session` | `200`, `Cache-Control: no-store`, replacement refresh `Set-Cookie` with same Path/HttpOnly/SameSite | Returns the same bundle shape as login and rotates refresh state. The session row retains the SID and stores current plus previous refresh-hash fields. |
| `POST /api/user/auth/logout` | access token, matching session header, refresh cookie | `200`, `Cache-Control: no-store`, clearing `new_api_refresh` cookie (`Expires=1970`, `Max-Age=0`) | `{"success":true,"message":"","data":{"revoked_sid":"<SID>","cookie_cleared":true}}`. Session status/revocation is persisted; old access token then returns `401 AUTH_SESSION_REVOKED`. |
| `POST /api/user/auth/refresh` | cookie replay after logout | `401`, `Cache-Control: no-store`, clearing cookie | `{"success":false,"code":"AUTH_UNAUTHORIZED","message":"Unauthorized"}`. |
| `GET /api/user/checkin` | authenticated, stock fresh settings | `200`, `Auth-Version` | `{"success":false,"message":"签到功能未启用"}`. No checkin row or quota change. |
| `GET /api/user/` and `GET /api/user/1` | ordinary authenticated user | `403` | `{"success":false,"code":"AUTH_INSUFFICIENT_PRIVILEGE","message":"Unauthorized, insufficient privileges"}`. |
| `GET /api/user/2fa/status` | authenticated before setup | `200`, `Auth-Version` | `{"success":true,"message":"","data":{"enabled":false,"locked":false}}`. |
| `POST /api/user/2fa/setup` | authenticated | `200`, `Auth-Version`, no-store cache header | `data` contains TOTP `secret`, `qr_code_data`, and backup codes (all secret material redacted). Persists pending 2FA/backup-code records; no auth rotation until enable succeeds. |
| `POST /api/user/2fa/enable` | JSON bad code `{"code":"000000"}` | `200`, `Auth-Version`, no-store cache header | `{"success":false,"message":"验证码或备用码错误，请重试"}`; 2FA remains disabled. |
| `POST /api/user/2fa/disable` | JSON bad code before enable | `200`, `Auth-Version`, no-store cache header | `{"success":false,"message":"用户未启用2FA"}`. |
| `GET /api/user/passkey` | authenticated | `200`, `Auth-Version` | `{"success":true,"message":"","data":{"enabled":false}}`; no credential row. |
| `POST /api/user/passkey/register/begin` | no body, stock settings | `200`, `Auth-Version`, no-store cache header | `{"success":false,"message":"管理员未启用 Passkey 登录"}`; no challenge/cache effect. |
| `GET /api/user/oauth/bindings` | authenticated | `200`, `Auth-Version` | `{"success":true,"message":"","data":[]}` on fresh DB. |
| `POST /api/user/aff_transfer` | JSON `{"quota":0}` on stock settings | `200`, `Auth-Version` | `success:false` with the compliance-disabled payment/redemption/subscription/invitation message; no quota mutation. |

## Replay and concurrency result

Two `POST /api/user/auth/refresh` requests were sent concurrently with the
same original refresh cookie and matching `X-Auth-Session`. **Both returned
200** with a rotated bundle. This is an intentional/observable previous-token
grace behavior, not a single-winner compare-and-swap. A subsequent replay after
explicit logout returned the `401` contract above.

## Storage observations and limitations

The provided safe oracle intentionally uses SQLite, not PostgreSQL. Therefore
the row effects above are verified against SQLite tables (`users`,
`user_sessions`, `two_fas`, `two_fa_backup_codes`, `passkey_credentials`, and
`user_oauth_bindings`) as a schema-compatible proxy; **PostgreSQL query plans,
row locks, and exact PG-only effects are not captured**.

Observed Valkey keys after login included:

```text
auth:session:<sha256>    hash, TTL 60
user:1                   hash, TTL 60
auth:user:version:1      string, TTL -1
rateLimit:v2:ip:CT:::1   string, TTL 1200
```

`auth:session:<sha256>` is a hash with fields `CacheSchema`, `CreatedAt`,
`ExpiresAt`, `IP`, `LastActiveAt`, `LoginMethod`, `RevokedAt`,
`RevokedReason`, `SID`, `Status`, `UserAgent`, `UserAuthVersion`, `UserID`,
and `Version`; values are redacted because they contain session identity and
client metadata. The non-secret capture values were `auth:user:version:1=1`
and the login rate-limit counter was `2`. The runner's cache TTLs are volatile;
assert the key families/types and obtain TTL at capture time rather than
hard-coding an exact remaining-second value.

## Uncaptured migration-plan families / blockers

Not exercised: administrator success mutations and listing/search, self/admin
delete, full 2FA enable/disable/backup rotation and 2FA login, passkey WebAuthn
begin/finish/verify/delete, OAuth unbind, settings/sidebar variants, access
token generation, topups and all payment-provider endpoints/webhooks. These
need either a seeded admin plus deterministic service options, or mock payment
providers/webhook signatures and browser/WebAuthn fixtures. Check-in success
needs an enabled check-in configuration and a CAPTCHA policy fixture. None of
those shared fixtures or settings were changed by this capture.

## Frozen TCP promotion gate

`tcp-differential.sh` drives independent real Go and Rust TCP listeners through
the 2FA status, self affiliation, and administrator listing paths. It compares
redacted JSON bodies and does not print dashboard tokens. It is intentionally a
promotion gate, not an assertion that the currently unmounted migration routers
are production reachable.

```bash
GO_BASE_URL=http://127.0.0.1:13001 RUST_BASE_URL=http://127.0.0.1:33001 \
GO_USER_BEARER="$go_user" RUST_USER_BEARER="$rust_user" \
GO_ADMIN_BEARER="$go_admin" RUST_ADMIN_BEARER="$rust_admin" \
bash rust/behavior-oracle/captures/identity-user/tcp-differential.sh
```
