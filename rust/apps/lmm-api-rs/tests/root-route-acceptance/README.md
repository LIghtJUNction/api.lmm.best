# Rust root-route acceptance gate

This opt-in harness sends in-process requests through the production Rust root
router. It reads the frozen 356-route inventory from
`rust/routes/legacy-go-routes.tsv` and the expected authentication class from
`rust/routes/migration-plan.tsv`.

Run the fast inventory and script self-tests with:

```sh
bash rust/scripts/test-root-route-acceptance.sh
```

Run the deliberately strict production-root gate with:

```sh
bash rust/scripts/run-root-route-acceptance.sh
```

The strict gate succeeds only after all 356 method/path shapes match their
exact Axum route pattern, required identities cross the expected authentication
boundary, an unused method returns the standardized 405 response for every
path, and an unknown path returns the standardized 404 response.

Required user, token, and admin classes are checked with both an anonymous
rejection and fixed synthetic identities. Public-or-user routes check both
anonymous and synthetic-user admission. Public and webhook routes use an
identity-invariance check, so handler-level failures such as a missing refresh
cookie or webhook signature are allowed while an accidentally mounted
dashboard/token authorization layer still fails the gate.

All identities are fixed synthetic values. PostgreSQL and Valkey clients are
lazy, point only at loopback port 1, and have short timeouts. The harness does
not read environment credentials, response bodies other than 404/405 error
envelopes, or contact production services.
