# Autonomous SQLite → PostgreSQL backend cutover

This transaction is the controlled bridge and reconciliation path from a
single Go/SQLite process to Go on PostgreSQL 18 plus the dedicated Valkey. It
is native systemd automation; Docker is not used. It is a rehearsable
coordinator, not an authorization to migrate or to switch Rust business
ownership. A target may already run Go with PostgreSQL after a historical
cutover; that runtime fact is not acceptance until the current schema,
forward-only boundary, authenticated canaries, final maintenance evidence, and
operator approval are reverified. The route gate currently keeps production
ownership on Go.

## Current production-state rule

The 2026-08-09 read-only audit found the production Go process using PostgreSQL
and the dedicated Valkey listener on port `6380`. Historical cutover logs contain
a `SUCCESS_POSTGRES` result, but the retained post-cutover verification is
`failed/contract` and no current `PG_WRITE_BOUNDARY`/journal was present. Treat
this as an unverified PostgreSQL runtime: do not run a fresh SQLite copy, change
the backend, or manually edit the environment. First inspect the live process,
active schema, cutover artifacts, and canaries, then reconcile through the
coordinator or obtain an explicit reviewed recovery decision.

## State and rollback law

The transaction runs outside the initiating SSH/API connection and writes a
strict, non-secret durable journal under `/var/lib/lmm-api-cutover` plus private
results under `/var/log/lmm-api-cutover/<transaction>/`. Every non-dry-run path
first copies the candidate environment into the root-owned
`/var/lib/lmm-api-cutover/artifacts/` directory and verifies its SHA-256. The
journal records only a version, generated transaction ID, phase, revision,
schema, and the candidate/saved-environment hashes; it is parsed defensively and
is never sourced.

1. `PREFLIGHT`: validate exact assets, current health, candidate environment,
   PostgreSQL/Valkey services, DSN identity, and a fresh admin canary token.
2. `GATED`: durably create `cutover-in-progress`. The installed
   `lmm-api.service` `ExecCondition` prevents an ordinary start while the
   transaction direction is ambiguous.
3. `FREEZING_WRITES`: stop the only Go writer and confirm it is inactive.
4. Run an offline WAL checkpoint, reject remaining SQLite sidecars, run
   `quick_check`, and create a hash-verified private SQLite backup.
5. `COPYING_TO_POSTGRES`: transactionally create a fresh versioned PostgreSQL
   18 schema,
   COPY all 34 tables, set 29 sequences, validate the catalog, and independently
   compare counts, BLAKE3 hashes, and financial aggregates.
6. Durably write `PG_WRITE_BOUNDARY` **before** publishing any environment that
   can start Go on PostgreSQL. Startup may execute GORM migrations and
   background jobs; from this exact marker onward SQLite is no longer a legal
   automatic rollback target.
7. Hash-verify and atomically publish the staged candidate environment, clear
   the gate only after the direction is unambiguous, then start Go.
8. Require public `/api/status` and authenticated `/api/user/self` canaries,
   then publish `SUCCESS_POSTGRES`.

Any failure before `PG_WRITE_BOUNDARY` atomically restores the old environment,
starts Go on SQLite, and verifies health. Any failure at or after the marker
hash-verifies and publishes only the PostgreSQL environment, starts Go, and runs
both canaries; it never touches the SQLite environment. A current environment
whose hash equals the durable candidate is also treated as evidence that
PostgreSQL may have been activated, even if an older coordinator left no marker;
reconciliation first recreates the marker and proceeds only forward. A marker
permanently blocks rerunning an automatic SQLite cutover.

`lmm-api-cutover --reconcile-only` is an explicit, idempotent manual recovery
entry point. It needs no candidate path, revision, or schema from the initiating
shell: those identities come from the strictly validated journal and generated
state paths. Before the marker it restores the exact hash-verified saved SQLite
environment and health. At or after the marker it converges only forward to the
immutable candidate, service health, public canary, authenticated canary, and a
durable result. Repeating reconciliation after either `ROLLED_BACK_SQLITE` or
`COMPLETE` is safe.

If a historical run left PostgreSQL active but no durable boundary or journal,
reconciliation must first establish which exact candidate environment and
schema are active from hashes and service evidence. Never recreate a generic
marker, point the service back to SQLite, or treat a successful historical
result as permission to continue forward without that identity check.

The installer enables `lmm-api-cutover-reconcile.service` before
`lmm-api.service` at boot. A second oneshot runs after the API starts to finish
health and authenticated canaries. If boot-time preparation cannot parse or
verify the state, the gate remains present and `lmm-api.service` cannot start;
the API cannot race ahead of reconciliation after reboot. Transient cutover
failure independently triggers `lmm-api-cutover-recover.service`, a full
reconciler that is separate from the already-completed boot prepare unit.

The `lmm-api.service` start condition also enforces the activation law on every
start, even when no in-progress gate exists. PostgreSQL in the active Go
environment is rejected without a boundary. When a boundary exists it must be
a root-owned private regular file in the exact strict metadata format, and the
active environment SHA-256 must equal its `candidate_sha256`; a symlink,
malformed marker, unsafe mode, SQLite environment, or hash mismatch blocks the
start without echoing marker or environment contents.

## Target ownership

`LMM_MIGRATE_DATABASE_URL` must authenticate as the future application role.
That role creates and owns the versioned schema and its objects, allowing the
same Go binary to run compatible expand migrations after startup. The candidate
`SQL_DSN` must be exactly that DSN with
`options=-csearch_path%3D<versioned_schema>` appended. This equality is checked
without printing either DSN.

Go and Rust must use the same dedicated Valkey 6380 URL. The candidate generator
reads the existing root-only Valkey ACL and never prints the credential.

## Build and install

```bash
cd rust
cargo build --release --locked -p lmm-db-migrate

sudo deploy/backend-cutover/install-lmm-api-cutover.sh \
  --migrator "$PWD/target/release/lmm-db-migrate"
```

Installation stages and validates every managed script, schema asset, example,
unit, drop-in, and command link beside its destination before publication. It
backs up the exact prior presence, bytes, type, ownership, and mode, uses
same-filesystem atomic replacements, then reloads systemd and enables the two
boot units. A publish, daemon-reload, or enable failure restores all managed
paths and their previous enablement state and reloads the restored systemd
view. Actual `cutover.conf`, `migration.env`, candidate environments, and canary
tokens are never installer-managed and are not overwritten.

Create `/etc/lmm-api-cutover/migration.env` and `cutover.conf` from the checked-in
examples with mode `0600 root:root`. Store a newly issued admin bearer token in
`/etc/lmm-api-cutover/admin-canary.token`, also `0600 root:root`. Do not reuse a
token pasted into chat, logs, shell history, or another deployment.

Generate the full candidate environment atomically:

```bash
sudo lmm-api-prepare-cutover-env \
  --schema lmm_prod_v1 \
  --output /etc/lmm-api-cutover/candidate.env
```

The schema identifier is immutable for an attempt. A failed pre-boundary COPY
leaves no committed schema; a failure after COPY but before the write boundary
may leave a verified but unused schema, so retry with a new versioned identifier.

## Dry-run and autonomous execution

```bash
sudo lmm-api-cutover \
  --candidate-env /etc/lmm-api-cutover/candidate.env \
  --revision "$(git rev-parse HEAD)" \
  --schema lmm_prod_v1 \
  --dry-run

sudo lmm-api-cutover \
  --candidate-env /etc/lmm-api-cutover/candidate.env \
  --revision "$(git rev-parse HEAD)" \
  --schema lmm_prod_v1 \
  --systemd-run
```

The systemd entry returns immediately. Treat the durable result, journal,
service health, active database identity, and authenticated canary as evidence;
do not rely on a transient unit that may already have been collected.

If a transient unit or its initiating control channel is lost, inspect and, if
needed, invoke the independent reconciler:

```bash
sudo lmm-api-cutover --reconcile-only
```

Systemd detachment makes the maintenance transaction survive loss of SSH or an
API control channel. It does **not** make this one-time SQLite freeze a
zero-downtime deployment: stopping the only Go process disconnects active HTTP,
SSE, and WebSocket connections, which clients must retry or reconnect.

## Required rehearsal before production

Run the repository fault tests, then repeat the complete transaction against an
isolated SQLite fixture and isolated PostgreSQL database on ArchDmit. Prove at
least: death after gate/stop/backup and immediately before the marker restores
SQLite; death at the marker, candidate publication, service start, or either
canary never restores SQLite; boot ordering cannot bypass the gate; loss of the
initiating connection does not stop progress; Go and Rust share Valkey counters;
and every audit artifact contains no DSN, token, row value, or financial value.
Repository fake-systemd tests are necessary but not production authorization.
The migration transaction remains prohibited until this isolated rehearsal
passes and the operator explicitly approves the maintenance or reconciliation
window. A live PostgreSQL process without current boundary and canary evidence
is not a completed cutover.

## Connection-loss and rollback operator checklist

Do not execute a production cutover from an interactive shell. First run the
documented `--dry-run`; only an approved maintenance transaction may use
`--systemd-run`, so the coordinator can outlive SSH/API disconnects. Record the
transaction identifier without copying its environment, DSN, canary token, or
journal contents into chat.

After a disconnect or failed transient unit, inspect the durable result and
recover through the coordinator rather than restarting `lmm-api.service` by
hand:

```bash
sudo lmm-api-cutover --reconcile-only
sudo systemctl status lmm-api.service --no-pager
sudo journalctl -u lmm-api-cutover-reconcile.service -u lmm-api.service --since '30 minutes ago'
```

Before `PG_WRITE_BOUNDARY`, reconciliation restores the saved SQLite
environment. At or after that boundary it only converges forward to the exact
hash-verified PostgreSQL candidate; manual SQLite rollback is prohibited. This
one-time database move is maintenance downtime, not blue/green traffic
switching. It does not authorize Rust production ownership.
