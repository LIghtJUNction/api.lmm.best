# SQLite to PostgreSQL migration contract

This document describes the auditable offline rehearsal and verification
workflow for the PostgreSQL 18 target. It does not authorize or implement a
production cutover. Production may already be running Go with PostgreSQL after
a historical coordinator run, but that runtime fact does not replace current
boundary, schema, canary, backup, and operator evidence.

The fresh contract-1 PostgreSQL baseline requires `users.console_activated_at BIGINT NOT NULL DEFAULT 0`. This fresh-schema contract does not upgrade an existing PostgreSQL schema; contract-2 apply remains blocked until a separately reviewed forward migration exists and passes an isolated rehearsal.

## Evidence and scope

The versioned manifest contains exactly 34 application tables and explicitly lists source and target columns, primary keys, indexes, converters, sequence ownership, and the verifier algorithm. The PostgreSQL 18 baseline was generated from the current Go/GORM models on an empty native cluster. `schema/provenance.json` binds the offline SQLite evidence, model inputs, manifest, baseline, and catalog query with SHA-256 hashes.

CI verifies provenance and hard-runs a native PostgreSQL 18 cluster. It validates all 34 tables, 422 columns, 172 indexes, and 29 owned sequences. Docker is not used.

## Commands

Run from `apps/api-rust/`:

```bash
cargo run -p lmm-db-migrate -- manifest-validate \
  --manifest crates/lmm-db-migrate/schema/table-map.json

cargo run -p lmm-db-migrate -- inspect \
  --sqlite /path/to/offline/one-api.db \
  --manifest crates/lmm-db-migrate/schema/table-map.json \
  --report /path/to/audit/inspect.json

export LMM_MIGRATE_DATABASE_URL='postgresql://migration-role@/database?host=/run/postgresql'

cargo run -p lmm-db-migrate -- rehearse \
  --sqlite /path/to/offline/one-api.db \
  --manifest crates/lmm-db-migrate/schema/table-map.json \
  --baseline crates/lmm-db-migrate/schema/postgresql-baseline.sql \
  --catalog-sql crates/lmm-db-migrate/schema/export-postgres-catalog.sql \
  --schema lmm_rehearsal_20260801 \
  --report /path/to/audit/rehearse.json

cargo run -p lmm-db-migrate -- verify \
  --sqlite /path/to/offline/one-api.db \
  --manifest crates/lmm-db-migrate/schema/table-map.json \
  --schema lmm_rehearsal_20260801 \
  --report /path/to/audit/verify.json

bash crates/lmm-db-migrate/scripts/rehearse-postgres.sh
crates/lmm-db-migrate/scripts/verify-provenance.sh
```

The PostgreSQL DSN is accepted only through `LMM_MIGRATE_DATABASE_URL`. It is never accepted as a command-line argument or written to an audit report.

## Offline source boundary

All source commands reject symlinks, special files, and SQLite `-wal`, `-journal`, or `-shm` sidecars. Before opening the source, `rehearse` and `verify` capture its canonical path, device, inode, size, nanosecond modification time, and SHA-256. The opened file descriptor is immediately measured and hashed again, then retained while SQLite is opened read-only through its `/proc/self/fd` path. This closes the path-replacement window while preserving SQLite read-lock semantics.

A single SQLite read-only transaction remains open throughout COPY and source-side verification. Immediately before PostgreSQL commit, the path identity, metadata, SHA-256, schema contract, and absence of sidecars are checked again. The SQLite transaction is committed only after PostgreSQL commits successfully, so the protected source snapshot is never released early.

## Rehearsal transaction

The target schema identifier must match the strict lower-case identifier contract. A PostgreSQL transaction-scoped advisory lock serializes creation of that schema, and schema existence is checked under the same transaction.

The baseline is applied to a new isolated schema. All 34 tables are streamed through PostgreSQL COPY using the manifest's explicit column lists and converters. Rows use complete primary-key order: SQLite text keys use byte ordering and PostgreSQL text keys use `COLLATE "C"`. JSON, booleans, UTC timestamps, fixed-scale decimals, finite REAL values, NULL, and COPY control characters have explicit canonical behavior.

After COPY, all 29 owned sequences are advanced with `setval`; an empty table correctly produces `nextval = 1`. The live PostgreSQL catalog is validated against the manifest. SQLite and PostgreSQL are then read independently and compared using per-table counts and canonical BLAKE3 table hashes. Financial aggregate checks cover users, tokens, logs, quota data, top-ups, subscription orders, and channels without publishing aggregate values.

COPY, catalog, sequence, or verification failure rolls back the complete target schema transaction. `verify` uses a read-only, repeatable-read PostgreSQL snapshot.

## Audit output

Success and failure reports are created with mode `0600`, written through a same-directory temporary file, fsynced, atomically renamed, and followed by a parent-directory fsync. Reports contain no DSN, row value, primary-key value, financial value, or underlying error text. Failure reports contain only a stable stage and error category. Standard error uses the same classifications and does not print conversion values or PostgreSQL/SQLite error details.

## Production cutover transaction

The autonomous transaction is now implemented under `deploy/backend-cutover/`
and documented in `docs/postgresql-cutover.md`. It provides write freeze,
offline backup and verification, a root-owned hash-verified candidate artifact,
a forward-only PostgreSQL-write boundary written before PostgreSQL environment
publication, authenticated canaries, an idempotent manual reconciler, and a
systemd boot gate. A killed coordinator restores the exact saved SQLite
environment only before the boundary; marker-, journal-, or candidate-hash
evidence of possible PostgreSQL activation permits only forward reconciliation.

The migration CLI still only creates a fresh isolated/versioned schema or
verifies one; it does not stop a service, publish configuration, or switch
traffic without the separate cutover coordinator. If a live target is already
PostgreSQL-backed, first verify the active schema, durable `PG_WRITE_BOUNDARY`,
candidate/environment hashes, and authenticated canaries. A missing boundary or
failed post-cutover verification is an unverified state that must be reconciled
before another migration attempt or backend switch. PostgreSQL 18 is the
persistent authority only after that evidence is accepted; Valkey remains
reconstructable cache, session/revocation, and rate-limit state rather than a
database of record.

This one-time offline source freeze is bounded maintenance downtime, not a
zero-downtime migration. Detaching it into systemd survives loss of the
initiating SSH/API channel, but stopping the sole Go process disconnects active
HTTP, SSE, and WebSocket clients. Production execution remains prohibited until
the full isolated rehearsal and explicit operator approval described in the
cutover runbook are complete.
