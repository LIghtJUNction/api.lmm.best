# Autonomous SQLite → PostgreSQL backend cutover

This transaction is the production bridge from the single Go/SQLite process to
Go on PostgreSQL plus the dedicated Valkey. It is native systemd automation;
Docker is not used. The script is implemented and fault-tested, but production
execution remains prohibited until a fresh authenticated canary token, target
database role, final maintenance window, and operator approval are present.

## State and rollback law

The transaction runs outside the initiating SSH/API connection and writes a
durable journal under `/var/lib/lmm-api-cutover` plus private results under
`/var/log/lmm-api-cutover/<transaction>/`.

1. `PREFLIGHT`: validate exact assets, current health, candidate environment,
   PostgreSQL/Valkey services, DSN identity, and a fresh admin canary token.
2. `FREEZING_WRITES`: stop the only Go writer and confirm it is inactive.
3. Run an offline WAL checkpoint, reject remaining SQLite sidecars, run
   `quick_check`, and create a hash-verified private SQLite backup.
4. `COPYING_TO_POSTGRES`: transactionally create a fresh versioned schema,
   COPY all 34 tables, set 29 sequences, validate the catalog, and independently
   compare counts, BLAKE3 hashes, and financial aggregates.
5. Atomically install the full candidate Go environment. The preparer permits
   only `SQL_DSN` and `REDIS_CONN_STRING` to differ from the current environment.
6. Durably write `PG_WRITE_BOUNDARY`, then start Go. Startup may execute GORM
   migrations and background jobs; from this exact marker onward SQLite is no
   longer a legal automatic rollback target.
7. Require public `/api/status` and authenticated `/api/user/self` canaries,
   then publish `SUCCESS_POSTGRES`.

Any failure before `PG_WRITE_BOUNDARY` atomically restores the old environment,
starts Go on SQLite, and verifies health. Any failure after the marker retains
the PostgreSQL environment, attempts forward restart, writes
`FAILED_FORWARD_ONLY`, and creates `NEEDS_ATTENTION`. The marker permanently
blocks rerunning an automatic SQLite cutover.

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

## Required rehearsal before production

Run the repository fault tests, then repeat the complete transaction against an
isolated SQLite fixture and isolated PostgreSQL database on ArchDmit. Prove at
least: migration failure restores SQLite, candidate-env failure restores SQLite,
post-boundary start/canary failure never restores SQLite, loss of the initiating
connection does not stop progress, Go and Rust share Valkey counters, and every
audit artifact contains no DSN, token, row value, or financial value.
