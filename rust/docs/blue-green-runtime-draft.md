# Blue/green runtime operations

This is the operational contract for `lmm-api-rs`; it replaces the former
runtime draft. The detailed installation guide is
[`docs/rust-blue-green.md`](../../docs/rust-blue-green.md). Nginx Rust
ownership remains only loopback internal probes. Route and candidate counts,
their differential state, and production ownership must be read from
`rust/routes/migration-gate.tsv` at the time of an approval; historical
snapshots in this document are not a source of truth. Do not enable production business-route ownership
during these operations.

## Preconditions

The deployer starts the inactive slot in isolation and will not switch nginx
unless all of these pass with bounded deadlines:

1. `/livez`, PostgreSQL 18 connectivity, the schema-reader compatibility
   range, and each mounted route's `SELECT` canary pass through `/readyz`.
2. Valkey passes `PING` when any deployed feature fails closed on it. A
   cache-only deployment may report Valkey as `degraded`; when the candidate
   enables fail-closed limiting, Valkey is required and readiness must fail.
3. The candidate's compiled `LMM_BUILD_REVISION`, slot, and SHA-256 match the
   immutable release requested by the transaction.
4. Read-only status and public-content requests complete to warm the candidate
   request path before nginx changes its upstream.

Apply schema changes separately with expand/contract migrations. The live
`lmm_schema_contract` must accept both the currently active reader and the
candidate reader before either slot is restarted. Never put a migration in
`ExecStartPre` or in `deploy-lmm-api-rs`.

For dashboard cookies, retain the deployed `SESSION_COOKIE_SECURE` and
`SESSION_COOKIE_TRUSTED_URL` names (the namespaced `AUTH_*` variants take
precedence when explicitly present). Secure cookies require one or more exact
HTTPS origins; local HTTP requires secure cookies disabled and no trusted
origin. Invalid mixed or broad configurations prevent candidate startup rather
than creating a blue/green split in CSRF policy.

## Deploy

```bash
cd rust
LMM_BUILD_REVISION="$(git rev-parse HEAD)" cargo build --release --locked -p lmm-api-rs
artifact="$PWD/target/release/lmm-api-rs"
sha256sum "$artifact"

# Read-only plan. It reads the managed upstream only; it does not reconcile a
# journal, start/stop a slot, reload nginx, or switch traffic.
sudo deploy-lmm-api-rs --artifact "$artifact" --sha256 <sha256> \
  --revision "$(git rev-parse HEAD)" --dry-run
```

There is intentionally no default production cutover command. After separate,
written authorization for an **internal-probes-only rehearsal**, a one-shot
approval must be supplied together with the fixed target and exact revision:

```bash
revision="$(git rev-parse HEAD)"
export LMM_RS_CUTOVER_APPROVAL=GO_FREEZE_OVERRIDE_INTERNAL_PROBES
sudo --preserve-env=LMM_RS_CUTOVER_APPROVAL deploy-lmm-api-rs \
  --artifact "$artifact" --sha256 <sha256> --revision "$revision" --systemd-run \
  --approve-cutover --cutover-target internal-probes --cutover-revision "$revision"
unset LMM_RS_CUTOVER_APPROVAL
```

The approval cannot name a production route target, and this script continues
to reject `production-routing.enabled`; it cannot transfer business API
ownership away from Go.

Observe the durable state, rather than a transient unit that may already have
been collected:

```bash
sudo cat /opt/lmm-api-rs/active-slot
sudo find /var/log/lmm-api-rs/deployments -name result -printf '%T@ %p\n' | sort -n | tail -1
sudo journalctl -u 'lmm-api-rs@*.service' -u nginx --since '10 minutes ago'
curl --fail --resolve api.lmm.best:443:127.0.0.1 \
  https://api.lmm.best/_internal/rust/build
```

The process marks itself draining before Axum closes the listener. `/readyz`
then returns 503, new work is rejected, and already accepted requests receive
at most `LMM_DRAIN_TIMEOUT_SECONDS` (default 30, maximum 40). systemd grants
45 seconds, leaving a teardown margin; it does not restart the only active
slot as part of this transaction.

## Roll back

An in-transaction failure automatically restores the old upstream only after
the old slot starts, becomes directly ready, reloads nginx, and passes the TLS
build canary. If that rollback cannot be proven, the deployment retains the
known-good new route and writes `NEEDS_ATTENTION`; do not stop either slot by
hand until the audit directory has been inspected.

For a deliberate rollback after a successful deployment, redeploy the exact
previous immutable artifact through the same detached transaction. Its digest
must match the release's recorded `SHA256SUMS` file:

```bash
previous=<previous-revision>
artifact="/opt/lmm-api-rs/releases/$previous/lmm-api-rs"
sha256="$(awk '$2 == "lmm-api-rs" { print $1 }' \
  "/opt/lmm-api-rs/releases/$previous/SHA256SUMS")"
test -n "$sha256"
export LMM_RS_CUTOVER_APPROVAL=GO_FREEZE_OVERRIDE_INTERNAL_PROBES
sudo --preserve-env=LMM_RS_CUTOVER_APPROVAL deploy-lmm-api-rs \
  --artifact "$artifact" --sha256 "$sha256" --revision "$previous" --systemd-run \
  --approve-cutover --cutover-target internal-probes --cutover-revision "$previous"
unset LMM_RS_CUTOVER_APPROVAL
```

Use the same one-shot approval with `--reconcile-only` after an interrupted
internal-probe transaction. It treats the real nginx TLS canary as authoritative
and either commits the candidate or restores the verified prior upstream; it
never guesses from a stale `active-slot` file. Do not manually stop a slot or
reload nginx after a control-channel loss: inspect the durable audit result,
then use the guarded reconciler with the exact revision. No form of this
rehearsal transfers production API ownership from Go.
