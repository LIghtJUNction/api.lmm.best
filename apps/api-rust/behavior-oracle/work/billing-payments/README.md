# Billing payments migration work

This slice implements the captured subscription pay/callback routes through
required trait-backed production adapters. There is no fallback authorizer,
checkout client, verifier, or cache implementation in the route module: the
listener composition must supply dashboard authentication, provider clients,
and Valkey invalidation explicitly. Test doubles live only in the integration
test target.

The PostgreSQL completion path locks `subscription_orders` with `FOR UPDATE`.
This is the cross-process idempotency boundary; Valkey is limited to best-effort
subscription-cache invalidation after a committed completion.

The remaining shared composition work is intentional and must be completed
before mounting: an adapter must bind ePay/FastPay/Stripe/Creem/Waffo-Pancake
credentials from the persisted payment settings, invoke each provider over its
documented API, and expose the wallet-ledger balance purchase transaction.

`HttpCheckoutProvider` is the only generic transport supplied by this slice.
It requires an explicit endpoint for each enabled provider and rejects missing
configuration, malformed endpoint URLs, transport failure, non-success HTTP,
and malformed checkout data. The loopback provider test exercises that
transport without credentials or charges. It is not evidence that any external
provider protocol is safe to enable: ePay, FastPay, Stripe, Creem, and
Waffo-Pancake each remain fail-closed until their credentialed, documented
adapter is composed and verified against that provider's sandbox.

The isolated `migration_billing_pg_valkey` test is deliberately ignored by
default and requires `LMM_BILLING_TEST_DATABASE_URL` and
`LMM_BILLING_TEST_VALKEY_URL`; invoking it without either variable fails, not
passes. The harness must point only at a disposable PostgreSQL 18 database and
Valkey. It proves that wallet balance purchase has no Valkey idempotency or
lock key: completion correctness is the PostgreSQL row-lock transaction.
