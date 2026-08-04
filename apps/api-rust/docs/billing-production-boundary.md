# Billing route production boundary

`billing_subscriptions` and `billing_payments` are candidate route families.
They intentionally remain unmounted until root-router ownership is changed in
one separately reviewed integration step.

- PostgreSQL is authoritative for plans, orders, subscriptions, wallet quota,
  and callback idempotency. Provider completion locks `subscription_orders` by
  `trade_no`; Valkey is never used as a replay lock.
- Valkey is derived state only. A completed payment removes its subscription
  view, removes the user hash when its group changes, or adjusts an existing
  user hash's `Quota` field. Expired user cache entries are never recreated by
  a post-commit quota delta.
- Checkout, ePay, and Stripe are explicit ports. Composition must provide real
  authenticated/provider adapters; the route modules do not invent credentials
  or return fake checkout data.
- The local billing tests exercise envelopes, methods, authorization, callback
  signatures, and cache boundary logic. The ignored PostgreSQL 18/Valkey tests
  require disposable endpoints through `LMM_BILLING_TEST_DATABASE_URL` and
  `LMM_BILLING_TEST_VALKEY_URL`.

Before mounting, run the frozen Go TCP differential harness plus the ignored
PostgreSQL 18/Valkey tests. Do not point either environment variable at a
production service.
