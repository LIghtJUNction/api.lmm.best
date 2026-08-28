# First-party OAuth provider

The site is the OAuth authority for the fixed public client `lmm-api-rs`.
There is no dynamic client registration and no client secret.

## Protocol surface

```text
GET  /.well-known/oauth-authorization-server
GET  /oauth/authorize
POST /oauth/device/code
POST /oauth/token
POST /oauth/revoke
```

The authority supports:

- Authorization Code with mandatory S256 PKCE;
- Device Authorization Grant with polling backoff;
- rotating refresh tokens with family-wide revocation on replay;
- short-lived bearer access tokens;
- explicit revocation.

Only these scopes exist:

```text
api_keys:list
api_keys:create
api_keys:reveal
cc_switch:import
```

Authorization callbacks must be exact, uncredentialed HTTP loopback URLs:

```text
http://127.0.0.1:<1024-65535>/oauth/callback
http://[::1]:<1024-65535>/oauth/callback
```

Aliases such as `localhost`, other `127/8` addresses, IPv4-mapped IPv6,
privileged ports, extra query parameters, fragments, and alternate paths are
rejected. OAuth state and PKCE values are bounded URL-safe opaque values.

## Browser surface

```text
GET /oauth/consent?request=<one-time opaque request>
GET /oauth/device?user_code=<optional device code>
```

These are SPA routes and require a normal dashboard login. The request token
contains no authorization code, access token, refresh token, or API Key. The
browser displays the client, requested scopes, account, and loopback target;
it issues a credential only after explicit Allow or Connect. A second Web
validator blocks any decision response that is not an exact loopback result
containing either `code + state` or `error=access_denied + state`.

OAuth bootstrap resource endpoints are bearer-token APIs:

```text
GET  /api/oauth/bootstrap/keys
POST /api/oauth/bootstrap/keys
POST /api/oauth/bootstrap/keys/:id/reveal
```

They return JSON directly rather than the legacy dashboard envelope so the
Rust CLI can consume them without importing browser-session behavior.

## Storage and secret handling

PostgreSQL schema contract 4 owns `oauth_device_grants` and
`oauth_grant_tokens`; one-time authorization requests/codes reuse
`auth_flows`. Database rows store only HMAC-SHA256 hashes of device codes,
user codes, authorization requests/codes, access tokens, and refresh tokens.
Raw values exist only in the request that creates or exchanges them.

Refresh tokens belong to a UUID family. A consumed-token replay revokes every
access and refresh token in that family in the same transaction. Device
polling, authorization-code consumption, refresh rotation, API Key limits,
and user ownership are serialized with PostgreSQL row locks.

The CLI stores refresh tokens only in the OS Keyring. API Keys are revealed
only after the user selects one and are handed directly to CC Switch; they are
not printed or persisted by `lmm-api-rs`.

## Go/Rust and Nginx ownership

Go and Rust providers implement the same HMAC, PKCE, grant, scope, response,
and schema contracts. New HMAC/PKCE vectors are asserted in both languages.
The Rust implementation is mounted only on the normal server, never the test
instance.

Nginx sends the five protocol endpoints above to the selected backend through
exact locations. `/oauth/consent` and `/oauth/device` remain under the SPA
`/oauth/` location. This split is covered by static gates and a real Nginx
container test.

Do not publish OAuth metadata until schema contract 4 is installed and both
selectable providers have passed their grant/token/resource tests. Changing
`lmm-api` to point at another provider is still a separate explicit backend
cutover; installers do not switch it automatically.
