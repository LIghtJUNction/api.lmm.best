# Identity federation route slice

Implemented route coverage:

- `POST /api/oauth/state`
- `GET /api/oauth/{provider}` for GitHub, Discord, OIDC, LinuxDO, and enabled
  custom providers
- `POST /api/oauth/email/bind`
- `GET /api/oauth/wechat`, `POST /api/oauth/wechat/bind`
- `GET /api/oauth/telegram/login`
- `POST /api/oauth/telegram/bind/start`,
  `GET /api/oauth/telegram/bind/{flow_token}`
- `GET|DELETE /api/user/oauth/bindings[/ {provider_id}]`
- `GET|DELETE /api/user/{id}/oauth/bindings[/ {provider_id}]`

`POST /api/oauth/state` persists an `auth_flows` row with a ten-minute expiry,
an HMAC-SHA256 token hash, the requested provider/intent, and the authenticated
user/session for bind intents. Its payload also reserves server-side nonce and
PKCE verifier storage for the paired authorization-request rollout. Standard
callbacks look up and atomically consume the state after upstream exchange;
bind callbacks additionally revalidate the bound dashboard session.

Built-in bindings update only the matching legacy user column; custom bindings
use `user_oauth_bindings` and reject a provider subject already owned by another
user. Telegram validates its widget HMAC, has a five-minute replay claim in
`auth_flows`, and binds through `external_identity_claims` inside the same
transaction as the one-time flow consumption.

## Required listener wiring

`FederationState::with_providers` must receive a production
`FederationProviders` implementation. It must use `oauth2` and `reqwest` for
GitHub, Discord, LinuxDO, WeChat bridge calls, and custom OAuth; it must use
`openidconnect` for OIDC discovery/JWKS, issuer/audience/expiry validation, and
nonce validation. Its login operation must delegate to the shared dashboard
auth service so PostgreSQL `users`/`user_sessions`, Valkey auth/session cache
keys, access tokens, and the refresh-cookie policy remain identical to password
login. The paired browser authorization builders must send the stored PKCE
challenge and nonce before an adapter begins sending the verifier at token
exchange.
