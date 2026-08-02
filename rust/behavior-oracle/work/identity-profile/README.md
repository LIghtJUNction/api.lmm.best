# Identity profile migration notes

This slice owns only self-service referral-code, preference, and profile updates
using the listener-provided identity. `/api/user/self` authentication remains
owned by the existing auth module. Administrator CRUD, search, and management
paths are exclusively owned by `identity_admin`; do not merge duplicate routes.

Auth-sensitive account updates advance Valkey's `auth:user:version:{id}` floor and clear the
legacy `user:{id}` hash so cached authorization cannot outlive an account change.

The router has no client-header fallback: `x-user-id` and `x-role` are ignored.
Production composition must inject `Extension<ProfileIdentity>` only after
server-side session/token validation; the focused construction test fails closed
when that listener principal is absent.
