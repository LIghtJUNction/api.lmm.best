//! Deterministic fingerprinting of the supported PostgreSQL `public` catalog.
//!
//! The supported scope is deliberately narrow: the `public` schema and objects owned by it,
//! plus database identity and privileges that directly describe those objects.  Extensions in
//! other schemas, unrelated foreign servers, and application row values are outside the scope.
//! Public foreign tables are rejected rather than serialising server, FDW, or user-mapping
//! options, because those catalog fields may contain credentials or endpoint material.  All
//! callers must invoke [`begin_catalog_inspection`] as the first statement in the transaction;
//! it establishes `READ COMMITTED` and the shared migration advisory lock.  The lock is the
//! quiescence contract for migration writers, and [`fingerprint`] enforces that it is still held
//! before every catalog read, including the final pre-commit fingerprint.

use std::{
    thread,
    time::{Duration, Instant},
};

use postgres::Transaction;
use serde::Serialize;
use sha2::{Digest, Sha256};
use thiserror::Error;

use crate::release::Sha256Digest;

/// Cross-runtime migration serialization contract. Must match Go MigrationAdvisoryLockKey.
/// Shared Go/Rust startup-migration advisory lock key.
pub const SHARED_MIGRATION_ADVISORY_LOCK_KEY: i64 = 0x4c4d4d4150490001;
const MIGRATION_LOCK_ACQUISITION_TIMEOUT: Duration = Duration::from_secs(5);
const MIGRATION_LOCK_RETRY_INTERVAL: Duration = Duration::from_millis(50);

/// Catalog inspection failed or found an unsafe database state.
#[derive(Debug, Error)]
pub enum CatalogError {
    /// PostgreSQL rejected a catalog query.
    #[error("PostgreSQL catalog inspection failed: {0}")]
    Postgres(#[from] postgres::Error),
    /// A catalog record could not be encoded canonically.
    #[error("PostgreSQL catalog canonicalization failed: {0}")]
    Json(#[from] serde_json::Error),
    /// The application schema contains incomplete validation state.
    #[error("PostgreSQL public schema is not safe to adopt")]
    UnsafeState,
    /// The generated digest was unexpectedly invalid.
    #[error("PostgreSQL catalog digest was invalid")]
    InvalidDigest,
    /// The transaction was not prepared with the required lock/isolation invariant.
    #[error("PostgreSQL catalog inspection requires the migration lock and READ COMMITTED")]
    LockInvariant,
    /// Another migration session retained the shared advisory lock past the bounded wait.
    #[error("timed out acquiring the shared PostgreSQL migration advisory lock")]
    LockAcquisitionTimeout,
}

/// Non-secret database identity included in the catalog fingerprint.
#[derive(Clone, Debug, Eq, PartialEq, Serialize)]
pub struct DatabaseIdentity {
    /// Exact current database name.
    pub database: String,
    /// Exact session role name.
    pub role: String,
    /// PostgreSQL major version.
    pub postgres_major: i32,
    /// Database encoding.
    pub encoding: String,
    /// Database collation locale.
    pub collation: String,
    /// Database character classification locale.
    pub character_type: String,
    /// PostgreSQL locale provider code.
    pub locale_provider: String,
    /// Provider-specific locale identifier.
    pub locale: String,
    /// Provider-specific ICU collation rules, when configured.
    pub icu_rules: String,
    /// Recorded collation library version, when available.
    pub collation_version: String,
}

/// Canonical fingerprint and the identity bound into it.
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct CatalogFingerprint {
    /// Database identity represented by the digest.
    pub identity: DatabaseIdentity,
    /// SHA-256 of the canonical catalog representation.
    pub sha256: Sha256Digest,
}

#[derive(Debug, Eq, Ord, PartialEq, PartialOrd, Serialize)]
struct CatalogRecord {
    kind: String,
    key: String,
    definition: String,
}

#[derive(Serialize)]
struct CatalogSnapshot<'a> {
    format_version: u32,
    identity: &'a DatabaseIdentity,
    records: &'a [CatalogRecord],
}

/// Prepare a transaction for a locked, `READ COMMITTED` catalog inspection.
///
/// This must be the first statement issued on `transaction`.  Every catalog writer participating
/// in adoption is required to use the same advisory lock; the lock is transaction-scoped.
pub fn begin_catalog_inspection(transaction: &mut Transaction<'_>) -> Result<(), CatalogError> {
    transaction.batch_execute("SET TRANSACTION ISOLATION LEVEL READ COMMITTED")?;
    acquire_shared_migration_lock(transaction)?;
    Ok(())
}

/// Acquire the shared startup-migration lock with a bounded wait.
///
/// Callers must invoke this before migration/adoption catalog or schema writes. The lock is
/// transaction-scoped and therefore released by commit or rollback.
pub fn acquire_shared_migration_lock(
    transaction: &mut Transaction<'_>,
) -> Result<(), CatalogError> {
    let deadline = Instant::now() + MIGRATION_LOCK_ACQUISITION_TIMEOUT;
    loop {
        let acquired = transaction
            .query_one(
                "SELECT pg_catalog.pg_try_advisory_xact_lock($1)",
                &[&SHARED_MIGRATION_ADVISORY_LOCK_KEY],
            )?
            .get::<_, bool>(0);
        if acquired {
            return Ok(());
        }

        let remaining = deadline.saturating_duration_since(Instant::now());
        if remaining.is_zero() {
            return Err(CatalogError::LockAcquisitionTimeout);
        }
        thread::sleep(MIGRATION_LOCK_RETRY_INTERVAL.min(remaining));
        if Instant::now() >= deadline {
            return Err(CatalogError::LockAcquisitionTimeout);
        }
    }
}

/// Reads a canonical description of the supported `public` schema.
///
/// The representation includes database identity, relations, columns and types, constraints,
/// complete index definitions, partition keys and bounds, same-schema inheritance, sequence
/// metadata and ownership, triggers, functions, public-schema extensions, views, row-level
/// security policies, privileges, and owners. Foreign tables and their server/FDW metadata are
/// unsupported and rejected by [`fingerprint`]. Application table row values are never selected.
pub fn fingerprint(transaction: &mut Transaction<'_>) -> Result<CatalogFingerprint, CatalogError> {
    ensure_inspection_invariant(transaction)?;
    let identity = read_identity(transaction)?;
    validate_safe_state(transaction)?;
    let mut records = transaction
        .query(CATALOG_RECORDS_SQL, &[])?
        .into_iter()
        .map(|row| CatalogRecord {
            kind: row.get(0),
            key: row.get(1),
            definition: row.get(2),
        })
        .collect::<Vec<_>>();
    records.sort();
    let canonical = serde_json::to_vec(&CatalogSnapshot {
        format_version: 2,
        identity: &identity,
        records: &records,
    })?;
    let digest = format!("{:x}", Sha256::digest(canonical));
    let sha256 = Sha256Digest::parse(&digest, "public_catalog_sha256")
        .map_err(|_| CatalogError::InvalidDigest)?;
    Ok(CatalogFingerprint { identity, sha256 })
}

fn ensure_inspection_invariant(transaction: &mut Transaction<'_>) -> Result<(), CatalogError> {
    let lock_class = SHARED_MIGRATION_ADVISORY_LOCK_KEY >> 32;
    let lock_object = SHARED_MIGRATION_ADVISORY_LOCK_KEY & 0xffff_ffff;
    let row = transaction.query_one(
        r#"
        SELECT pg_catalog.current_setting('transaction_isolation') = 'read committed',
               EXISTS (
                 SELECT 1 FROM pg_catalog.pg_locks
                  WHERE locktype = 'advisory'
                    AND pid = pg_catalog.pg_backend_pid()
                    AND classid = $1::bigint::oid
                    AND objid = $2::bigint::oid
                    AND objsubid = 1
                    AND mode = 'ExclusiveLock'
                    AND granted
               )
        "#,
        &[&lock_class, &lock_object],
    )?;
    if !row.get::<_, bool>(0) || !row.get::<_, bool>(1) {
        return Err(CatalogError::LockInvariant);
    }
    Ok(())
}

fn read_identity(transaction: &mut Transaction<'_>) -> Result<DatabaseIdentity, CatalogError> {
    let row = transaction.query_one(
        r#"
        SELECT d.datname,
               CURRENT_USER,
               pg_catalog.current_setting('server_version_num')::integer / 10000,
               pg_catalog.pg_encoding_to_char(d.encoding),
               d.datcollate,
               d.datctype,
               COALESCE(pg_catalog.to_jsonb(d)->>'datlocprovider', ''),
               COALESCE(
                 pg_catalog.to_jsonb(d)->>'datlocale',
                 pg_catalog.to_jsonb(d)->>'daticulocale',
                 ''
               ),
               COALESCE(pg_catalog.to_jsonb(d)->>'daticurules', ''),
               COALESCE(pg_catalog.to_jsonb(d)->>'datcollversion', '')
          FROM pg_catalog.pg_database AS d
         WHERE d.datname = pg_catalog.current_database()
        "#,
        &[],
    )?;
    Ok(DatabaseIdentity {
        database: row.get(0),
        role: row.get(1),
        postgres_major: row.get(2),
        encoding: row.get(3),
        collation: row.get(4),
        character_type: row.get(5),
        locale_provider: row.get(6),
        locale: row.get(7),
        icu_rules: row.get(8),
        collation_version: row.get(9),
    })
}

fn validate_safe_state(transaction: &mut Transaction<'_>) -> Result<(), CatalogError> {
    let row = transaction.query_one(SAFE_STATE_SQL, &[])?;
    if !(row.get::<_, bool>(0)
        && row.get::<_, bool>(1)
        && row.get::<_, bool>(2)
        && row.get::<_, bool>(3)
        && row.get::<_, bool>(4)
        && row.get::<_, bool>(5))
    {
        return Err(CatalogError::UnsafeState);
    }
    Ok(())
}

const SAFE_STATE_SQL: &str = r#"
        SELECT
          EXISTS (SELECT 1 FROM pg_catalog.pg_namespace WHERE nspname = 'public'),
          NOT EXISTS (
            SELECT 1
              FROM pg_catalog.pg_index AS i
              JOIN pg_catalog.pg_class AS c ON c.oid = i.indexrelid
              JOIN pg_catalog.pg_namespace AS n ON n.oid = c.relnamespace
             WHERE n.nspname = 'public' AND (NOT i.indisvalid OR NOT i.indisready)
          ),
          NOT EXISTS (
            SELECT 1
              FROM pg_catalog.pg_constraint AS con
              JOIN pg_catalog.pg_namespace AS n ON n.oid = con.connamespace
             WHERE n.nspname = 'public' AND NOT con.convalidated
          ),
          NOT EXISTS (
            SELECT 1
              FROM pg_catalog.pg_trigger AS t
              JOIN pg_catalog.pg_class AS c ON c.oid = t.tgrelid
              JOIN pg_catalog.pg_namespace AS n ON n.oid = c.relnamespace
             WHERE n.nspname = 'public' AND t.tgenabled = 'D'
          ),
          NOT EXISTS (
            SELECT 1
              FROM pg_catalog.pg_inherits AS i
              JOIN pg_catalog.pg_class AS child ON child.oid = i.inhrelid
              JOIN pg_catalog.pg_namespace AS child_ns ON child_ns.oid = child.relnamespace
              JOIN pg_catalog.pg_class AS parent ON parent.oid = i.inhparent
              JOIN pg_catalog.pg_namespace AS parent_ns ON parent_ns.oid = parent.relnamespace
             WHERE (child_ns.nspname = 'public' AND parent_ns.nspname <> 'public')
                OR (parent_ns.nspname = 'public' AND child_ns.nspname <> 'public')
          ),
          NOT EXISTS (
            SELECT 1
              FROM pg_catalog.pg_class AS c
              JOIN pg_catalog.pg_namespace AS n ON n.oid = c.relnamespace
             WHERE n.nspname = 'public' AND c.relkind = 'f'
          )
"#;

const CATALOG_RECORDS_SQL: &str = r#"
SELECT kind, object_key, definition
FROM (
  SELECT 'schema'::text AS kind,
         n.nspname::text AS object_key,
         pg_catalog.jsonb_build_object(
           'owner', pg_catalog.pg_get_userbyid(n.nspowner)
         )::text AS definition
    FROM pg_catalog.pg_namespace AS n
   WHERE n.nspname = 'public'

  UNION ALL
  SELECT 'relation', c.relname,
         pg_catalog.jsonb_build_object(
           'kind', c.relkind,
           'owner', pg_catalog.pg_get_userbyid(c.relowner),
           'persistence', c.relpersistence,
           'replica_identity', c.relreplident,
           'row_security', c.relrowsecurity,
           'force_row_security', c.relforcerowsecurity,
           'options', COALESCE(c.reloptions::text, '')
         )::text
    FROM pg_catalog.pg_class AS c
    JOIN pg_catalog.pg_namespace AS n ON n.oid = c.relnamespace
   WHERE n.nspname = 'public' AND c.relkind IN ('r', 'p', 'v', 'm', 'S', 'c')

  UNION ALL
  SELECT 'partitioned_table', c.relname,
         pg_catalog.jsonb_build_object(
           'strategy', p.partstrat,
           'key_count', p.partnatts,
           'key_attributes', p.partattrs::text,
           'operator_classes', COALESCE((
             SELECT pg_catalog.jsonb_agg(opn.nspname || '.' || opc.opcname ORDER BY item.ordinality)
               FROM pg_catalog.unnest(p.partclass::oid[]) WITH ORDINALITY AS item(opclass_oid, ordinality)
               JOIN pg_catalog.pg_opclass AS opc ON opc.oid = item.opclass_oid
               JOIN pg_catalog.pg_namespace AS opn ON opn.oid = opc.opcnamespace
           ), '[]'::pg_catalog.jsonb),
           'collations', COALESCE((
             SELECT pg_catalog.jsonb_agg(
               CASE WHEN item.collation_oid = 0 THEN '' ELSE item.collation_oid::pg_catalog.regcollation::text END
               ORDER BY item.ordinality
             )
               FROM pg_catalog.unnest(p.partcollation::oid[]) WITH ORDINALITY AS item(collation_oid, ordinality)
           ), '[]'::pg_catalog.jsonb),
           'expressions', COALESCE(pg_catalog.pg_get_expr(p.partexprs, p.partrelid), ''),
           'definition', pg_catalog.pg_get_partkeydef(p.partrelid)
         )::text
    FROM pg_catalog.pg_partitioned_table AS p
    JOIN pg_catalog.pg_class AS c ON c.oid = p.partrelid
    JOIN pg_catalog.pg_namespace AS n ON n.oid = c.relnamespace
   WHERE n.nspname = 'public'

  UNION ALL
  SELECT 'inheritance', child_ns.nspname || '.' || child.relname,
         pg_catalog.jsonb_build_object(
           'parent', parent_ns.nspname || '.' || parent.relname,
           'sequence', i.inhseqno,
           'detach_pending', COALESCE((pg_catalog.to_jsonb(i)->>'inhdetachpending')::boolean, false),
           'is_partition', child.relispartition,
           'bound', COALESCE(pg_catalog.pg_get_expr(child.relpartbound, child.oid, false), '')
         )::text
    FROM pg_catalog.pg_inherits AS i
    JOIN pg_catalog.pg_class AS child ON child.oid = i.inhrelid
    JOIN pg_catalog.pg_namespace AS child_ns ON child_ns.oid = child.relnamespace
    JOIN pg_catalog.pg_class AS parent ON parent.oid = i.inhparent
    JOIN pg_catalog.pg_namespace AS parent_ns ON parent_ns.oid = parent.relnamespace
   WHERE child_ns.nspname = 'public' AND parent_ns.nspname = 'public'

  UNION ALL
  SELECT 'column', c.relname || '.' || a.attnum::text || '.' || a.attname,
         pg_catalog.jsonb_build_object(
           'type', pg_catalog.format_type(a.atttypid, a.atttypmod),
           'not_null', a.attnotnull,
           'default', COALESCE(pg_catalog.pg_get_expr(d.adbin, d.adrelid), ''),
           'identity', a.attidentity,
           'generated', a.attgenerated,
           'collation', CASE WHEN a.attcollation = 0 THEN '' ELSE a.attcollation::pg_catalog.regcollation::text END,
           'storage', a.attstorage,
           'statistics', a.attstattarget
         )::text
    FROM pg_catalog.pg_attribute AS a
    JOIN pg_catalog.pg_class AS c ON c.oid = a.attrelid
    JOIN pg_catalog.pg_namespace AS n ON n.oid = c.relnamespace
    LEFT JOIN pg_catalog.pg_attrdef AS d ON d.adrelid = a.attrelid AND d.adnum = a.attnum
   WHERE n.nspname = 'public' AND c.relkind IN ('r', 'p', 'v', 'm', 'c')
     AND a.attnum > 0 AND NOT a.attisdropped

  UNION ALL
  SELECT 'constraint', COALESCE(c.relname, t.typname, '') || '.' || con.conname,
         pg_catalog.jsonb_build_object(
           'type', con.contype,
           'validated', con.convalidated,
           'deferrable', con.condeferrable,
           'initially_deferred', con.condeferred,
           'referenced_relation', COALESCE(con.confrelid::pg_catalog.regclass::text, ''),
           'definition', pg_catalog.pg_get_constraintdef(con.oid, false)
         )::text
    FROM pg_catalog.pg_constraint AS con
    LEFT JOIN pg_catalog.pg_class AS c ON c.oid = con.conrelid
    LEFT JOIN pg_catalog.pg_type AS t ON t.oid = con.contypid
    JOIN pg_catalog.pg_namespace AS n ON n.oid = con.connamespace
   WHERE n.nspname = 'public'

  UNION ALL
  SELECT 'index', tc.relname || '.' || ic.relname,
         pg_catalog.jsonb_build_object(
           'owner', pg_catalog.pg_get_userbyid(ic.relowner),
           'unique', i.indisunique,
           'primary', i.indisprimary,
           'exclusion', i.indisexclusion,
           'immediate', i.indimmediate,
           'clustered', i.indisclustered,
           'replica_identity', i.indisreplident,
           'valid', i.indisvalid,
           'ready', i.indisready,
           'live', i.indislive,
           'key_attributes', i.indnkeyatts,
           'total_attributes', i.indnatts,
           'attribute_numbers', i.indkey::text,
           'operator_classes', COALESCE((
             SELECT pg_catalog.string_agg(opn.nspname || '.' || opc.opcname, ',' ORDER BY item.ordinality)
               FROM pg_catalog.unnest(i.indclass::oid[]) WITH ORDINALITY AS item(opclass_oid, ordinality)
               JOIN pg_catalog.pg_opclass AS opc ON opc.oid = item.opclass_oid
               JOIN pg_catalog.pg_namespace AS opn ON opn.oid = opc.opcnamespace
           ), ''),
           'collations', COALESCE((
             SELECT pg_catalog.string_agg(
               CASE WHEN item.collation_oid = 0 THEN '' ELSE item.collation_oid::pg_catalog.regcollation::text END,
               ',' ORDER BY item.ordinality
             )
               FROM pg_catalog.unnest(i.indcollation::oid[]) WITH ORDINALITY AS item(collation_oid, ordinality)
           ), ''),
           'options', i.indoption::text,
           'expressions', COALESCE(pg_catalog.pg_get_expr(i.indexprs, i.indrelid), ''),
           'predicate', COALESCE(pg_catalog.pg_get_expr(i.indpred, i.indrelid), ''),
           'included_columns', COALESCE((
             SELECT pg_catalog.string_agg(a.attname, ',' ORDER BY item.ordinality)
               FROM pg_catalog.unnest(i.indkey::smallint[]) WITH ORDINALITY AS item(attribute_number, ordinality)
               JOIN pg_catalog.pg_attribute AS a
                 ON a.attrelid = i.indrelid AND a.attnum = item.attribute_number
              WHERE item.ordinality > i.indnkeyatts
           ), ''),
           'definition', pg_catalog.pg_get_indexdef(i.indexrelid)
         )::text
    FROM pg_catalog.pg_index AS i
    JOIN pg_catalog.pg_class AS ic ON ic.oid = i.indexrelid
    JOIN pg_catalog.pg_class AS tc ON tc.oid = i.indrelid
    JOIN pg_catalog.pg_namespace AS n ON n.oid = tc.relnamespace
   WHERE n.nspname = 'public'

  UNION ALL
  SELECT 'sequence', c.relname,
         pg_catalog.jsonb_build_object(
           'owner', pg_catalog.pg_get_userbyid(c.relowner),
           'data_type', pg_catalog.format_type(s.seqtypid, NULL),
           'start', s.seqstart,
           'increment', s.seqincrement,
           'minimum', s.seqmin,
           'maximum', s.seqmax,
           'cache', s.seqcache,
           'cycle', s.seqcycle,
           'owned_by', COALESCE(owned.ref, ''),
           'ownership_dependency', COALESCE(owned.dependency_type, '')
         )::text
    FROM pg_catalog.pg_class AS c
    JOIN pg_catalog.pg_namespace AS n ON n.oid = c.relnamespace
    JOIN pg_catalog.pg_sequence AS s ON s.seqrelid = c.oid
    LEFT JOIN LATERAL (
      SELECT dc.relname || '.' || a.attname AS ref, dep.deptype::text AS dependency_type
        FROM pg_catalog.pg_depend AS dep
        JOIN pg_catalog.pg_class AS dc ON dc.oid = dep.refobjid
        JOIN pg_catalog.pg_attribute AS a
          ON a.attrelid = dep.refobjid AND a.attnum = dep.refobjsubid
       WHERE dep.classid = 'pg_catalog.pg_class'::pg_catalog.regclass
         AND dep.objid = c.oid AND dep.deptype IN ('a', 'i')
       ORDER BY ref LIMIT 1
    ) AS owned ON true
   WHERE n.nspname = 'public' AND c.relkind = 'S'

  UNION ALL
  SELECT 'trigger', c.relname || '.' || t.tgname,
         pg_catalog.jsonb_build_object(
           'internal', t.tgisinternal,
           'constraint_oid', t.tgconstraint,
           'enabled', t.tgenabled,
           'function', t.tgfoid::pg_catalog.regprocedure::text,
           'definition', pg_catalog.pg_get_triggerdef(t.oid, false)
         )::text
    FROM pg_catalog.pg_trigger AS t
    JOIN pg_catalog.pg_class AS c ON c.oid = t.tgrelid
    JOIN pg_catalog.pg_namespace AS n ON n.oid = c.relnamespace
   WHERE n.nspname = 'public'

  UNION ALL
  SELECT 'function', p.proname || '(' || pg_catalog.pg_get_function_identity_arguments(p.oid) || ')',
         pg_catalog.jsonb_build_object(
           'kind', p.prokind,
           'owner', pg_catalog.pg_get_userbyid(p.proowner),
           'language', l.lanname,
           'result', pg_catalog.pg_get_function_result(p.oid),
           'volatility', p.provolatile,
           'parallel', p.proparallel,
           'security_definer', p.prosecdef,
           'leakproof', p.proleakproof,
           'strict', p.proisstrict,
           'configuration', COALESCE(p.proconfig::text, ''),
           'definition', CASE WHEN p.prokind = 'a' THEN '' ELSE pg_catalog.pg_get_functiondef(p.oid) END,
           'aggregate', CASE WHEN p.prokind = 'a' THEN pg_catalog.jsonb_build_object(
             'kind', ag.aggkind,
             'direct_arguments', ag.aggnumdirectargs,
             'transition', ag.aggtransfn::pg_catalog.regprocedure::text,
             'final', ag.aggfinalfn::pg_catalog.regprocedure::text,
             'combine', ag.aggcombinefn::pg_catalog.regprocedure::text,
             'serial', ag.aggserialfn::pg_catalog.regprocedure::text,
             'deserial', ag.aggdeserialfn::pg_catalog.regprocedure::text,
             'moving_transition', ag.aggmtransfn::pg_catalog.regprocedure::text,
             'moving_inverse', ag.aggminvtransfn::pg_catalog.regprocedure::text,
             'moving_final', ag.aggmfinalfn::pg_catalog.regprocedure::text,
             'transition_type', pg_catalog.format_type(ag.aggtranstype, NULL),
             'transition_space', ag.aggtransspace,
             'moving_transition_type', pg_catalog.format_type(ag.aggmtranstype, NULL),
             'moving_transition_space', ag.aggmtransspace,
             'initial', COALESCE(ag.agginitval, ''),
             'moving_initial', COALESCE(ag.aggminitval, '')
           ) ELSE '{}'::pg_catalog.jsonb END
         )::text
    FROM pg_catalog.pg_proc AS p
    JOIN pg_catalog.pg_namespace AS n ON n.oid = p.pronamespace
    JOIN pg_catalog.pg_language AS l ON l.oid = p.prolang
    LEFT JOIN pg_catalog.pg_aggregate AS ag ON ag.aggfnoid = p.oid
   WHERE n.nspname = 'public'

  UNION ALL
  SELECT 'extension', e.extname,
         pg_catalog.jsonb_build_object(
           'owner', pg_catalog.pg_get_userbyid(e.extowner),
           'schema', n.nspname,
           'version', e.extversion,
           'relocatable', e.extrelocatable
         )::text
    FROM pg_catalog.pg_extension AS e
    JOIN pg_catalog.pg_namespace AS n ON n.oid = e.extnamespace
   WHERE n.nspname = 'public'

  UNION ALL
  SELECT 'view', c.relname,
         pg_catalog.jsonb_build_object(
           'kind', c.relkind,
           'definition', pg_catalog.pg_get_viewdef(c.oid, false)
         )::text
    FROM pg_catalog.pg_class AS c
    JOIN pg_catalog.pg_namespace AS n ON n.oid = c.relnamespace
   WHERE n.nspname = 'public' AND c.relkind IN ('v', 'm')

  UNION ALL
  SELECT 'policy', c.relname || '.' || p.polname,
         pg_catalog.jsonb_build_object(
           'permissive', p.polpermissive,
           'command', p.polcmd,
           'roles', COALESCE((
             SELECT pg_catalog.string_agg(
               CASE WHEN role_oid = 0 THEN 'PUBLIC' ELSE pg_catalog.pg_get_userbyid(role_oid) END,
               ',' ORDER BY CASE WHEN role_oid = 0 THEN 'PUBLIC' ELSE pg_catalog.pg_get_userbyid(role_oid) END
             )
             FROM pg_catalog.unnest(p.polroles) AS roles(role_oid)
           ), ''),
           'using', COALESCE(pg_catalog.pg_get_expr(p.polqual, p.polrelid), ''),
           'check', COALESCE(pg_catalog.pg_get_expr(p.polwithcheck, p.polrelid), '')
         )::text
    FROM pg_catalog.pg_policy AS p
    JOIN pg_catalog.pg_class AS c ON c.oid = p.polrelid
    JOIN pg_catalog.pg_namespace AS n ON n.oid = c.relnamespace
   WHERE n.nspname = 'public'

  UNION ALL
  SELECT 'relation_grant', c.relname || '.' ||
         CASE WHEN acl.grantee = 0 THEN 'PUBLIC' ELSE pg_catalog.pg_get_userbyid(acl.grantee) END ||
         '.' || acl.privilege_type || '.' || pg_catalog.pg_get_userbyid(acl.grantor),
         pg_catalog.jsonb_build_object(
           'grantor', pg_catalog.pg_get_userbyid(acl.grantor),
           'grantee', CASE WHEN acl.grantee = 0 THEN 'PUBLIC' ELSE pg_catalog.pg_get_userbyid(acl.grantee) END,
           'privilege', acl.privilege_type,
           'grantable', acl.is_grantable
         )::text
    FROM pg_catalog.pg_class AS c
    JOIN pg_catalog.pg_namespace AS n ON n.oid = c.relnamespace
    CROSS JOIN LATERAL pg_catalog.aclexplode(COALESCE(c.relacl, pg_catalog.acldefault(CASE WHEN c.relkind = 'S' THEN 's'::"char" ELSE 'r'::"char" END, c.relowner))) AS acl
   WHERE n.nspname = 'public' AND c.relkind IN ('r', 'p', 'v', 'm', 'S')

  UNION ALL
  SELECT 'column_grant', c.relname || '.' || a.attname || '.' ||
         CASE WHEN acl.grantee = 0 THEN 'PUBLIC' ELSE pg_catalog.pg_get_userbyid(acl.grantee) END ||
         '.' || acl.privilege_type || '.' || pg_catalog.pg_get_userbyid(acl.grantor),
         pg_catalog.jsonb_build_object(
           'grantor', pg_catalog.pg_get_userbyid(acl.grantor),
           'grantee', CASE WHEN acl.grantee = 0 THEN 'PUBLIC' ELSE pg_catalog.pg_get_userbyid(acl.grantee) END,
           'privilege', acl.privilege_type,
           'grantable', acl.is_grantable
         )::text
    FROM pg_catalog.pg_attribute AS a
    JOIN pg_catalog.pg_class AS c ON c.oid = a.attrelid
    JOIN pg_catalog.pg_namespace AS n ON n.oid = c.relnamespace
    CROSS JOIN LATERAL pg_catalog.aclexplode(a.attacl) AS acl
   WHERE n.nspname = 'public' AND a.attnum > 0 AND NOT a.attisdropped

  UNION ALL
  SELECT 'schema_grant', n.nspname || '.' ||
         CASE WHEN acl.grantee = 0 THEN 'PUBLIC' ELSE pg_catalog.pg_get_userbyid(acl.grantee) END ||
         '.' || acl.privilege_type || '.' || pg_catalog.pg_get_userbyid(acl.grantor),
         pg_catalog.jsonb_build_object(
           'grantor', pg_catalog.pg_get_userbyid(acl.grantor),
           'grantee', CASE WHEN acl.grantee = 0 THEN 'PUBLIC' ELSE pg_catalog.pg_get_userbyid(acl.grantee) END,
           'privilege', acl.privilege_type,
           'grantable', acl.is_grantable
         )::text
    FROM pg_catalog.pg_namespace AS n
    CROSS JOIN LATERAL pg_catalog.aclexplode(COALESCE(n.nspacl, pg_catalog.acldefault('n'::"char", n.nspowner))) AS acl
   WHERE n.nspname = 'public'

  UNION ALL
  SELECT 'type', t.typname,
         pg_catalog.jsonb_build_object(
           'kind', t.typtype,
           'category', t.typcategory,
           'owner', pg_catalog.pg_get_userbyid(t.typowner),
           'base', CASE WHEN t.typbasetype = 0 THEN '' ELSE pg_catalog.format_type(t.typbasetype, t.typtypmod) END,
           'range_subtype', CASE WHEN r.rngsubtype IS NULL THEN '' ELSE pg_catalog.format_type(r.rngsubtype, NULL) END,
           'range_collation', CASE WHEN COALESCE(r.rngcollation, 0) = 0 THEN '' ELSE r.rngcollation::pg_catalog.regcollation::text END,
           'range_operator_class', COALESCE(opn.nspname || '.' || opc.opcname, ''),
           'range_canonical', CASE WHEN COALESCE(r.rngcanonical, 0) = 0 THEN '' ELSE r.rngcanonical::pg_catalog.regprocedure::text END,
           'range_subdiff', CASE WHEN COALESCE(r.rngsubdiff, 0) = 0 THEN '' ELSE r.rngsubdiff::pg_catalog.regprocedure::text END,
           'not_null', t.typnotnull,
           'default', COALESCE(t.typdefault, ''),
           'collation', CASE WHEN t.typcollation = 0 THEN '' ELSE t.typcollation::pg_catalog.regcollation::text END,
           'enum_labels', COALESCE(en.labels, '')
         )::text
    FROM pg_catalog.pg_type AS t
    JOIN pg_catalog.pg_namespace AS n ON n.oid = t.typnamespace
    LEFT JOIN pg_catalog.pg_range AS r ON r.rngtypid = t.oid OR r.rngmultitypid = t.oid
    LEFT JOIN pg_catalog.pg_opclass AS opc ON opc.oid = r.rngsubopc
    LEFT JOIN pg_catalog.pg_namespace AS opn ON opn.oid = opc.opcnamespace
    LEFT JOIN LATERAL (
      SELECT pg_catalog.string_agg(e.enumlabel, E'\\n' ORDER BY e.enumsortorder) AS labels
        FROM pg_catalog.pg_enum AS e WHERE e.enumtypid = t.oid
    ) AS en ON true
   WHERE n.nspname = 'public' AND t.typtype IN ('e', 'd', 'c', 'r', 'm')

  UNION ALL
  SELECT 'function_grant', p.proname || '(' || pg_catalog.pg_get_function_identity_arguments(p.oid) || ').' ||
         CASE WHEN acl.grantee = 0 THEN 'PUBLIC' ELSE pg_catalog.pg_get_userbyid(acl.grantee) END ||
         '.' || acl.privilege_type || '.' || pg_catalog.pg_get_userbyid(acl.grantor),
         pg_catalog.jsonb_build_object(
           'grantor', pg_catalog.pg_get_userbyid(acl.grantor),
           'grantee', CASE WHEN acl.grantee = 0 THEN 'PUBLIC' ELSE pg_catalog.pg_get_userbyid(acl.grantee) END,
           'privilege', acl.privilege_type,
           'grantable', acl.is_grantable
         )::text
    FROM pg_catalog.pg_proc AS p
    JOIN pg_catalog.pg_namespace AS n ON n.oid = p.pronamespace
    CROSS JOIN LATERAL pg_catalog.aclexplode(COALESCE(p.proacl, pg_catalog.acldefault('f'::"char", p.proowner))) AS acl
   WHERE n.nspname = 'public'

  UNION ALL
  SELECT 'type_grant', t.typname || '.' ||
         CASE WHEN acl.grantee = 0 THEN 'PUBLIC' ELSE pg_catalog.pg_get_userbyid(acl.grantee) END ||
         '.' || acl.privilege_type || '.' || pg_catalog.pg_get_userbyid(acl.grantor),
         pg_catalog.jsonb_build_object(
           'grantor', pg_catalog.pg_get_userbyid(acl.grantor),
           'grantee', CASE WHEN acl.grantee = 0 THEN 'PUBLIC' ELSE pg_catalog.pg_get_userbyid(acl.grantee) END,
           'privilege', acl.privilege_type,
           'grantable', acl.is_grantable
         )::text
    FROM pg_catalog.pg_type AS t
    JOIN pg_catalog.pg_namespace AS n ON n.oid = t.typnamespace
    CROSS JOIN LATERAL pg_catalog.aclexplode(COALESCE(t.typacl, pg_catalog.acldefault('T'::"char", t.typowner))) AS acl
   WHERE n.nspname = 'public' AND t.typtype IN ('e', 'd', 'c', 'r', 'm')

  UNION ALL
  SELECT 'default_grant', pg_catalog.pg_get_userbyid(d.defaclrole) || '.' ||
         COALESCE(n.nspname, '') || '.' || d.defaclobjtype::text || '.' ||
         CASE WHEN acl.grantee = 0 THEN 'PUBLIC' ELSE pg_catalog.pg_get_userbyid(acl.grantee) END ||
         '.' || acl.privilege_type,
         pg_catalog.jsonb_build_object(
           'role', pg_catalog.pg_get_userbyid(d.defaclrole),
           'schema', COALESCE(n.nspname, ''),
           'object_type', d.defaclobjtype,
           'grantor', pg_catalog.pg_get_userbyid(acl.grantor),
           'grantee', CASE WHEN acl.grantee = 0 THEN 'PUBLIC' ELSE pg_catalog.pg_get_userbyid(acl.grantee) END,
           'privilege', acl.privilege_type,
           'grantable', acl.is_grantable
         )::text
    FROM pg_catalog.pg_default_acl AS d
    LEFT JOIN pg_catalog.pg_namespace AS n ON n.oid = d.defaclnamespace
    CROSS JOIN LATERAL pg_catalog.aclexplode(d.defaclacl) AS acl
   WHERE d.defaclnamespace = 0 OR n.nspname = 'public'
) AS catalog
ORDER BY kind, object_key, definition
"#;

#[cfg(test)]
mod tests {
    use super::{CATALOG_RECORDS_SQL, SAFE_STATE_SQL, SHARED_MIGRATION_ADVISORY_LOCK_KEY};

    #[test]
    fn shared_migration_lock_key_matches_go_contract() {
        assert_eq!(SHARED_MIGRATION_ADVISORY_LOCK_KEY, 0x4c4d4d4150490001_i64);
    }

    #[test]
    fn migration_tool_has_no_legacy_schema_hash_lock() {
        let migration_source = include_str!("migrate.rs");
        assert!(!migration_source.contains("hashtextextended"));
        assert!(migration_source.contains("acquire_shared_migration_lock"));
    }

    #[test]
    fn catalog_query_fingerprints_partition_and_inheritance_metadata() {
        for fragment in [
            "'partitioned_table'",
            "p.partstrat",
            "p.partnatts",
            "p.partattrs",
            "p.partclass",
            "p.partcollation",
            "pg_get_partkeydef",
            "'inheritance'",
            "pg_catalog.pg_inherits",
            "pg_get_expr(child.relpartbound",
            "inhdetachpending",
            "child.relispartition",
            "child_ns.nspname = 'public' AND parent_ns.nspname = 'public'",
        ] {
            assert!(
                CATALOG_RECORDS_SQL.contains(fragment),
                "missing SQL fragment: {fragment}"
            );
        }
    }

    #[test]
    fn catalog_query_rejects_foreign_metadata_instead_of_hashing_options() {
        assert!(!CATALOG_RECORDS_SQL.contains("'foreign_table'"));
        assert!(!CATALOG_RECORDS_SQL.contains("'foreign_server'"));
        assert!(!CATALOG_RECORDS_SQL.contains("srvoptions"));
        assert!(!CATALOG_RECORDS_SQL.contains("fdwoptions"));
        assert!(SAFE_STATE_SQL.contains("c.relkind = 'f'"));
    }

    #[test]
    fn catalog_query_casts_default_acl_object_type_before_concatenation() {
        assert!(CATALOG_RECORDS_SQL.contains("d.defaclobjtype::text"));
    }

    #[test]
    fn safe_state_rejects_domain_constraints_and_internal_disabled_triggers() {
        assert!(SAFE_STATE_SQL.contains("con.connamespace"));
        assert!(SAFE_STATE_SQL.contains("NOT con.convalidated"));
        assert!(CATALOG_RECORDS_SQL.contains("'validated', con.convalidated"));
        assert!(SAFE_STATE_SQL.contains("t.tgenabled = 'D'"));
        assert!(CATALOG_RECORDS_SQL.contains("'internal', t.tgisinternal"));
        assert!(SAFE_STATE_SQL.contains("parent_ns.nspname <> 'public'"));
    }
}
