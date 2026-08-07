//! Transactional adoption of an existing PostgreSQL `public` schema.

use std::{
    fs::{self, File},
    io::{Read, Seek, SeekFrom},
    path::{Component, Path, PathBuf},
    str::FromStr,
};

#[cfg(unix)]
use std::os::unix::fs::MetadataExt;

use postgres::{Client, NoTls, Transaction};
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use thiserror::Error;

use crate::{
    postgres_catalog::{CatalogError, CatalogFingerprint, begin_catalog_inspection, fingerprint},
    release::{ReleaseBindingError, ReleaseId, Sha256Digest},
};

const PLAN_MAX_BYTES: u64 = 64 * 1024;
const LEDGER_COMMENT: &str = "lmm-db-migrate postgres adopt-existing ledger v1";

/// Inputs for one explicit PostgreSQL adoption attempt.
pub struct AdoptExistingOptions<'a> {
    /// PostgreSQL connection URL. It is never included in reports or errors.
    pub database_url: &'a str,
    /// Strict, byte-addressed adoption plan.
    pub plan: &'a Path,
    /// Expected SHA-256 of the exact plan bytes.
    pub expected_plan_sha256: &'a Sha256Digest,
    /// Exact database identity expected after connecting.
    pub expected_database: &'a str,
    /// Exact role identity expected after connecting.
    pub expected_role: &'a str,
    /// Exact release revision duplicated outside the plan.
    pub release_revision: &'a ReleaseId,
    /// Exact immutable release artifact digest duplicated outside the plan.
    pub release_artifact_sha256: &'a Sha256Digest,
    /// Deployment-verifier attestation that managed services are stopped and no managed
    /// migration-capable sessions remain.  It does not make claims about arbitrary DB principals.
    pub maintenance_quiescence: &'a MaintenanceQuiescenceAttestation,
}

/// Externally verified maintenance-mode precondition for adoption.
///
/// The deployment verifier must attest the service state and managed-session count.  The
/// `principal_scope` is intentionally explicit: arbitrary PostgreSQL principals are excluded and
/// may still change the database, so this attestation never substitutes for catalog validation.
#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
pub struct MaintenanceQuiescenceAttestation {
    /// Attestation schema version.
    pub format_version: u32,
    /// Must be exactly `verified`.
    pub status: String,
    /// Stable deployment verifier identity.
    pub verifier: String,
    /// Must be true when the managed service is stopped.
    pub service_stopped: bool,
    /// Number of migration-capable sessions observed among managed principals.
    pub migration_capable_sessions: u32,
    /// Must be exactly `deployment_managed_only`.
    pub principal_scope: String,
}

/// Successful, bounded, non-secret adoption report.
#[derive(Debug, Serialize)]
pub struct AdoptionReport {
    /// Stable completion state.
    pub status: AdoptionOutcome,
    /// Exact plan digest.
    pub plan_sha256: String,
    /// Immutable release revision.
    pub release_revision: String,
    /// Immutable release artifact digest.
    pub release_artifact_sha256: String,
    /// Public catalog fingerprint verified before commit.
    pub public_catalog_sha256: String,
    /// Exact database identity.
    pub database: String,
    /// Exact role identity.
    pub role: String,
    /// PostgreSQL major version.
    pub postgres_major: i32,
    /// Exact configured PostgreSQL `search_path`.
    pub configured_search_path: String,
    /// First valid schema selected by PostgreSQL.
    pub current_schema: String,
    /// Effective lookup order including the implicit system catalog.
    pub effective_schemas: [String; 2],
    /// Verifier identity for the maintenance-quiescence precondition.
    pub maintenance_quiescence_verifier: String,
}

/// Transaction result for adoption or exact replay.
#[derive(Clone, Copy, Debug, Eq, PartialEq, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum AdoptionOutcome {
    /// A new control ledger and immutable adoption row were committed.
    Adopted,
    /// The exact row and catalog fingerprint already existed; no writes were issued.
    AlreadyApplied,
}

/// Fail-closed adoption error.
#[derive(Debug, Error)]
pub enum AdoptionError {
    /// The connection input was not an explicit PostgreSQL URL.
    #[error("adoption requires an explicit PostgreSQL URL")]
    InvalidDatabaseUrl,
    /// The plan path or file type was unsafe.
    #[error("adoption plan path is unsafe")]
    UnsafePlanPath,
    /// The plan exceeded the fixed input bound.
    #[error("adoption plan exceeds the size limit")]
    PlanTooLarge,
    /// The plan changed while it was being validated and read.
    #[error("adoption plan changed during validation")]
    PlanChanged,
    /// Plan filesystem access failed.
    #[error("adoption plan filesystem operation failed: {0}")]
    Io(#[from] std::io::Error),
    /// Strict plan JSON was invalid.
    #[error("adoption plan JSON is invalid: {0}")]
    Json(#[from] serde_json::Error),
    /// Plan or command release metadata was invalid.
    #[error("adoption release binding is invalid: {0}")]
    Release(#[from] ReleaseBindingError),
    /// The plan did not match its expected digest or duplicated command binding.
    #[error("adoption plan binding does not match")]
    PlanBindingMismatch,
    /// The connected database or role was not the exact expected identity.
    #[error("connected PostgreSQL identity does not match")]
    DatabaseIdentityMismatch,
    /// Configured or effective PostgreSQL schema resolution was not exact.
    #[error("PostgreSQL runtime schema resolution does not match")]
    RuntimeSchemaResolutionMismatch,
    /// The public catalog did not match the plan or changed inside the transaction.
    #[error("PostgreSQL public catalog fingerprint does not match")]
    CatalogMismatch,
    /// Catalog inspection failed or found unsafe state.
    #[error(transparent)]
    Catalog(#[from] CatalogError),
    /// The control schema was partial, altered, or contained conflicting metadata.
    #[error("PostgreSQL adoption ledger is in an unknown or conflicting state")]
    LedgerConflict,
    /// PostgreSQL rejected an adoption operation.
    #[error("PostgreSQL adoption failed: {0}")]
    Postgres(#[from] postgres::Error),
    /// The external maintenance-quiescence attestation was absent or invalid.
    #[error("maintenance quiescence attestation is absent or invalid")]
    MaintenanceQuiescenceInvalid,
}

#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
struct RawPlan {
    format_version: u32,
    operation: String,
    app_schema: String,
    control_schema: String,
    expected_database: String,
    expected_role: String,
    expected_postgres_major: i32,
    expected_configured_search_path: String,
    expected_current_schema: String,
    expected_effective_schemas: [String; 2],
    release_revision: String,
    release_artifact_sha256: String,
    expected_public_catalog_sha256: String,
    maintenance_quiescence: MaintenanceQuiescenceAttestation,
    #[serde(rename = "application_ddl")]
    _application_ddl: [String; 0],
}

struct ValidatedPlan {
    sha256: Sha256Digest,
    expected_database: String,
    expected_role: String,
    expected_postgres_major: i32,
    release_revision: ReleaseId,
    release_artifact_sha256: Sha256Digest,
    expected_public_catalog_sha256: Sha256Digest,
    maintenance_quiescence: MaintenanceQuiescenceAttestation,
}

struct RuntimeSchemaResolution {
    configured_search_path: String,
    current_schema: String,
    effective_schemas: [String; 2],
}

/// Adopts an existing PostgreSQL database in one advisory-locked transaction.
///
/// Exact replay validates the persisted row and public fingerprint and issues no writes.
pub fn adopt_existing(options: &AdoptExistingOptions<'_>) -> Result<AdoptionReport, AdoptionError> {
    if !(options.database_url.starts_with("postgresql://")
        || options.database_url.starts_with("postgres://"))
    {
        return Err(AdoptionError::InvalidDatabaseUrl);
    }
    validate_identity_argument(options.expected_database)?;
    validate_identity_argument(options.expected_role)?;
    validate_maintenance_quiescence(options.maintenance_quiescence)?;
    let plan = load_plan(options.plan, options.expected_plan_sha256)?;
    if plan.expected_database != options.expected_database
        || plan.expected_role != options.expected_role
        || &plan.release_revision != options.release_revision
        || &plan.release_artifact_sha256 != options.release_artifact_sha256
        || &plan.maintenance_quiescence != options.maintenance_quiescence
    {
        return Err(AdoptionError::PlanBindingMismatch);
    }

    let mut client = Client::connect(options.database_url, NoTls)?;
    let mut transaction = client.transaction()?;
    // This must remain the first transaction statement: establish READ COMMITTED and the shared
    // xact-scoped lock before any runtime or catalog reads. The final fingerprint below runs in
    // this same locked transaction, and `fingerprint` enforces that invariant.
    begin_catalog_inspection(&mut transaction)?;
    let configured_runtime_schema = validate_and_normalize_runtime_schema(&mut transaction)?;

    let before = fingerprint(&mut transaction)?;
    validate_database_identity(&before, options)?;
    if before.identity.postgres_major != plan.expected_postgres_major
        || before.sha256 != plan.expected_public_catalog_sha256
    {
        return Err(AdoptionError::CatalogMismatch);
    }

    let outcome = match ledger_presence(&mut transaction)? {
        LedgerPresence::Missing => {
            create_ledger(&mut transaction)?;
            validate_ledger_schema(&mut transaction, options.expected_role)?;
            insert_adoption(&mut transaction, &plan, &before)?;
            AdoptionOutcome::Adopted
        }
        LedgerPresence::Complete => {
            validate_ledger_schema(&mut transaction, options.expected_role)?;
            validate_existing_adoption(&mut transaction, &plan, &before)?;
            AdoptionOutcome::AlreadyApplied
        }
        LedgerPresence::Partial => return Err(AdoptionError::LedgerConflict),
    };

    let after = fingerprint(&mut transaction)?;
    if after != before {
        return Err(AdoptionError::CatalogMismatch);
    }
    read_and_validate_runtime_schema(&mut transaction)?;
    transaction.commit()?;

    Ok(AdoptionReport {
        status: outcome,
        plan_sha256: plan.sha256.to_string(),
        release_revision: plan.release_revision.as_str().to_owned(),
        release_artifact_sha256: plan.release_artifact_sha256.to_string(),
        public_catalog_sha256: after.sha256.to_string(),
        database: after.identity.database,
        role: after.identity.role,
        postgres_major: after.identity.postgres_major,
        configured_search_path: configured_runtime_schema.configured_search_path,
        current_schema: configured_runtime_schema.current_schema,
        effective_schemas: configured_runtime_schema.effective_schemas,
        maintenance_quiescence_verifier: plan.maintenance_quiescence.verifier.clone(),
    })
}

fn validate_and_normalize_runtime_schema(
    transaction: &mut Transaction<'_>,
) -> Result<RuntimeSchemaResolution, AdoptionError> {
    let configured = read_runtime_schema(transaction)?;
    validate_runtime_schema(&configured)?;
    transaction.batch_execute("SET LOCAL search_path = public")?;
    read_and_validate_runtime_schema(transaction)?;
    Ok(configured)
}

fn read_and_validate_runtime_schema(
    transaction: &mut Transaction<'_>,
) -> Result<RuntimeSchemaResolution, AdoptionError> {
    let resolution = read_runtime_schema(transaction)?;
    validate_runtime_schema(&resolution)?;
    Ok(resolution)
}

fn read_runtime_schema(
    transaction: &mut Transaction<'_>,
) -> Result<RuntimeSchemaResolution, AdoptionError> {
    let row = transaction.query_one(
        r#"
        SELECT pg_catalog.current_setting('search_path'),
               COALESCE(pg_catalog.current_schema()::text, ''),
               pg_catalog.cardinality(pg_catalog.current_schemas(true))::integer,
               COALESCE((pg_catalog.current_schemas(true))[1]::text, ''),
               COALESCE((pg_catalog.current_schemas(true))[2]::text, ''),
               NOT ('lmm_meta' = ANY(pg_catalog.current_schemas(true)))
        "#,
        &[],
    )?;
    let configured_search_path: String = row.get(0);
    let current_schema: String = row.get(1);
    let effective_count: i32 = row.get(2);
    let effective_schemas = [row.get(3), row.get(4)];
    let control_schema_excluded: bool = row.get(5);
    if effective_count != 2 || !control_schema_excluded {
        return Err(AdoptionError::RuntimeSchemaResolutionMismatch);
    }
    Ok(RuntimeSchemaResolution {
        configured_search_path,
        current_schema,
        effective_schemas,
    })
}

fn validate_runtime_schema(resolution: &RuntimeSchemaResolution) -> Result<(), AdoptionError> {
    if resolution.configured_search_path != "public"
        || resolution.current_schema != "public"
        || resolution.effective_schemas[0] != "pg_catalog"
        || resolution.effective_schemas[1] != "public"
    {
        return Err(AdoptionError::RuntimeSchemaResolutionMismatch);
    }
    Ok(())
}

fn validate_identity_argument(value: &str) -> Result<(), AdoptionError> {
    if value.is_empty() || value.len() > 128 || value.chars().any(char::is_control) {
        return Err(AdoptionError::DatabaseIdentityMismatch);
    }
    Ok(())
}

fn validate_database_identity(
    fingerprint: &CatalogFingerprint,
    options: &AdoptExistingOptions<'_>,
) -> Result<(), AdoptionError> {
    if fingerprint.identity.database != options.expected_database
        || fingerprint.identity.role != options.expected_role
        || fingerprint.identity.postgres_major <= 0
    {
        return Err(AdoptionError::DatabaseIdentityMismatch);
    }
    Ok(())
}

fn load_plan(path: &Path, expected_hash: &Sha256Digest) -> Result<ValidatedPlan, AdoptionError> {
    let absolute = absolute_path(path)?;
    reject_symlink_components(&absolute)?;
    let canonical = fs::canonicalize(&absolute)?;
    let path_metadata = fs::symlink_metadata(&canonical)?;
    if !path_metadata.file_type().is_file() || path_metadata.file_type().is_symlink() {
        return Err(AdoptionError::UnsafePlanPath);
    }
    if path_metadata.len() > PLAN_MAX_BYTES {
        return Err(AdoptionError::PlanTooLarge);
    }

    let mut file = File::open(&canonical)?;
    let opened_metadata = file.metadata()?;
    if !same_file(&path_metadata, &opened_metadata) {
        return Err(AdoptionError::PlanChanged);
    }
    let mut bytes = Vec::with_capacity(opened_metadata.len() as usize);
    file.by_ref()
        .take(PLAN_MAX_BYTES + 1)
        .read_to_end(&mut bytes)?;
    if bytes.len() as u64 > PLAN_MAX_BYTES {
        return Err(AdoptionError::PlanTooLarge);
    }
    file.seek(SeekFrom::Start(0))?;
    let after_read = file.metadata()?;
    let path_after = fs::symlink_metadata(&canonical)?;
    if !same_file(&opened_metadata, &after_read)
        || !same_file(&opened_metadata, &path_after)
        || opened_metadata.len() != bytes.len() as u64
    {
        return Err(AdoptionError::PlanChanged);
    }

    let actual_hash = format!("{:x}", Sha256::digest(&bytes));
    if actual_hash != expected_hash.as_str() {
        return Err(AdoptionError::PlanBindingMismatch);
    }
    let raw: RawPlan = serde_json::from_slice(&bytes)?;
    validate_raw_plan(&raw)?;
    validate_identity_argument(&raw.expected_database)?;
    validate_identity_argument(&raw.expected_role)?;
    Ok(ValidatedPlan {
        sha256: Sha256Digest::parse(&actual_hash, "plan_sha256")?,
        expected_database: raw.expected_database,
        expected_role: raw.expected_role,
        expected_postgres_major: raw.expected_postgres_major,
        release_revision: ReleaseId::from_str(&raw.release_revision)?,
        release_artifact_sha256: Sha256Digest::parse(
            &raw.release_artifact_sha256,
            "release_artifact_sha256",
        )?,
        expected_public_catalog_sha256: Sha256Digest::parse(
            &raw.expected_public_catalog_sha256,
            "expected_public_catalog_sha256",
        )?,
        maintenance_quiescence: raw.maintenance_quiescence,
    })
}

fn validate_raw_plan(raw: &RawPlan) -> Result<(), AdoptionError> {
    if raw.format_version != 2
        || raw.operation != "postgres_adopt_existing"
        || raw.app_schema != "public"
        || raw.control_schema != "lmm_meta"
        || raw.expected_postgres_major <= 0
        || raw.expected_configured_search_path != "public"
        || raw.expected_current_schema != "public"
        || raw.expected_effective_schemas[0] != "pg_catalog"
        || raw.expected_effective_schemas[1] != "public"
    {
        return Err(AdoptionError::PlanBindingMismatch);
    }
    validate_maintenance_quiescence(&raw.maintenance_quiescence)
}

fn validate_maintenance_quiescence(
    attestation: &MaintenanceQuiescenceAttestation,
) -> Result<(), AdoptionError> {
    if attestation.format_version != 1
        || attestation.status != "verified"
        || attestation.verifier.is_empty()
        || attestation.verifier.len() > 128
        || attestation.verifier.chars().any(char::is_control)
        || !attestation.service_stopped
        || attestation.migration_capable_sessions != 0
        || attestation.principal_scope != "deployment_managed_only"
    {
        return Err(AdoptionError::MaintenanceQuiescenceInvalid);
    }
    Ok(())
}

fn absolute_path(path: &Path) -> Result<PathBuf, AdoptionError> {
    if path.as_os_str().is_empty() {
        return Err(AdoptionError::UnsafePlanPath);
    }
    if path.is_absolute() {
        Ok(path.to_path_buf())
    } else {
        Ok(std::env::current_dir()?.join(path))
    }
}

fn reject_symlink_components(path: &Path) -> Result<(), AdoptionError> {
    let mut current = PathBuf::new();
    for component in path.components() {
        match component {
            Component::Prefix(_) | Component::RootDir | Component::Normal(_) => {
                current.push(component.as_os_str());
            }
            Component::CurDir => continue,
            Component::ParentDir => return Err(AdoptionError::UnsafePlanPath),
        }
        if fs::symlink_metadata(&current)?.file_type().is_symlink() {
            return Err(AdoptionError::UnsafePlanPath);
        }
    }
    Ok(())
}

#[cfg(unix)]
fn same_file(left: &fs::Metadata, right: &fs::Metadata) -> bool {
    left.dev() == right.dev()
        && left.ino() == right.ino()
        && left.len() == right.len()
        && left.mtime() == right.mtime()
        && left.mtime_nsec() == right.mtime_nsec()
}

#[cfg(not(unix))]
fn same_file(left: &fs::Metadata, right: &fs::Metadata) -> bool {
    left.len() == right.len()
        && left.modified().ok() == right.modified().ok()
        && left.is_file() == right.is_file()
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
enum LedgerPresence {
    Missing,
    Partial,
    Complete,
}

fn ledger_presence(transaction: &mut Transaction<'_>) -> Result<LedgerPresence, AdoptionError> {
    let row = transaction.query_one(
        r#"
        SELECT
          EXISTS (SELECT 1 FROM pg_catalog.pg_namespace WHERE nspname = 'lmm_meta'),
          EXISTS (
            SELECT 1
              FROM pg_catalog.pg_class AS c
              JOIN pg_catalog.pg_namespace AS n ON n.oid = c.relnamespace
             WHERE n.nspname = 'lmm_meta'
               AND c.relname = 'lmm_adoption_ledger'
               AND c.relkind = 'r'
          )
        "#,
        &[],
    )?;
    match (row.get::<_, bool>(0), row.get::<_, bool>(1)) {
        (false, false) => Ok(LedgerPresence::Missing),
        (true, true) => Ok(LedgerPresence::Complete),
        _ => Ok(LedgerPresence::Partial),
    }
}

fn create_ledger(transaction: &mut Transaction<'_>) -> Result<(), AdoptionError> {
    transaction.batch_execute(
        r#"
        CREATE SCHEMA lmm_meta AUTHORIZATION CURRENT_USER;
        REVOKE ALL ON SCHEMA lmm_meta FROM PUBLIC;
        CREATE TABLE lmm_meta.lmm_adoption_ledger (
          singleton boolean NOT NULL,
          plan_sha256 text NOT NULL,
          release_revision text NOT NULL,
          release_artifact_sha256 text NOT NULL,
          public_catalog_sha256 text NOT NULL,
          database_name text NOT NULL,
          database_role text NOT NULL,
          postgres_major integer NOT NULL,
          CONSTRAINT lmm_adoption_ledger_pkey PRIMARY KEY (singleton)
        );
        REVOKE ALL ON TABLE lmm_meta.lmm_adoption_ledger FROM PUBLIC;
        COMMENT ON TABLE lmm_meta.lmm_adoption_ledger IS
          'lmm-db-migrate postgres adopt-existing ledger v1';
        "#,
    )?;
    Ok(())
}

fn validate_ledger_schema(
    transaction: &mut Transaction<'_>,
    expected_owner: &str,
) -> Result<(), AdoptionError> {
    let row = transaction.query_one(
        r#"
        SELECT pg_catalog.pg_get_userbyid(n.nspowner),
               pg_catalog.pg_get_userbyid(c.relowner),
               NOT EXISTS (
                 SELECT 1
                   FROM pg_catalog.aclexplode(COALESCE(
                     n.nspacl, pg_catalog.acldefault('n'::"char", n.nspowner)
                   )) AS acl
                  WHERE acl.grantee <> n.nspowner
               ),
               NOT EXISTS (
                 SELECT 1
                   FROM pg_catalog.aclexplode(COALESCE(
                     c.relacl, pg_catalog.acldefault('r'::"char", c.relowner)
                   )) AS acl
                  WHERE acl.grantee <> c.relowner
               ),
               pg_catalog.obj_description(c.oid, 'pg_class'),
               (
                 SELECT count(*)::bigint
                   FROM pg_catalog.pg_class AS other
                  WHERE other.relnamespace = n.oid AND other.relkind <> 'i'
               ),
               (
                 SELECT count(*)::bigint
                   FROM pg_catalog.pg_class AS idx
                  WHERE idx.relnamespace = n.oid AND idx.relkind = 'i'
               ),
               c.relpersistence::text, c.relreplident::text,
               NOT c.relrowsecurity, NOT c.relforcerowsecurity, c.reloptions IS NULL,
               (
                 SELECT count(*)::bigint FROM pg_catalog.pg_proc AS p
                  WHERE p.pronamespace = n.oid
               ),
               (
                 SELECT count(*)::bigint FROM pg_catalog.pg_type AS t
                  WHERE t.typnamespace = n.oid
                    AND t.typname NOT IN ('lmm_adoption_ledger', '_lmm_adoption_ledger')
               ),
               (
                 SELECT count(*)::bigint
                   FROM pg_catalog.pg_trigger AS t
                   JOIN pg_catalog.pg_class AS controlled ON controlled.oid = t.tgrelid
                  WHERE controlled.relnamespace = n.oid
               ),
               (
                 SELECT count(*)::bigint
                   FROM pg_catalog.pg_policy AS p
                   JOIN pg_catalog.pg_class AS controlled ON controlled.oid = p.polrelid
                  WHERE controlled.relnamespace = n.oid
               )
          FROM pg_catalog.pg_class AS c
          JOIN pg_catalog.pg_namespace AS n ON n.oid = c.relnamespace
         WHERE n.nspname = 'lmm_meta'
           AND c.relname = 'lmm_adoption_ledger'
           AND c.relkind = 'r'
        "#,
        &[],
    )?;
    if row.get::<_, String>(0) != expected_owner
        || row.get::<_, String>(1) != expected_owner
        || !row.get::<_, bool>(2)
        || !row.get::<_, bool>(3)
        || row.get::<_, Option<String>>(4).as_deref() != Some(LEDGER_COMMENT)
        || row.get::<_, i64>(5) != 1
        || row.get::<_, i64>(6) != 1
        || row.get::<_, String>(7) != "p"
        || row.get::<_, String>(8) != "d"
        || !row.get::<_, bool>(9)
        || !row.get::<_, bool>(10)
        || !row.get::<_, bool>(11)
        || row.get::<_, i64>(12) != 0
        || row.get::<_, i64>(13) != 0
        || row.get::<_, i64>(14) != 0
        || row.get::<_, i64>(15) != 0
    {
        return Err(AdoptionError::LedgerConflict);
    }

    let columns = transaction.query(
        r#"
        SELECT a.attname, pg_catalog.format_type(a.atttypid, a.atttypmod), a.attnotnull,
               d.oid IS NOT NULL, a.attidentity::text, a.attgenerated::text,
               a.attstorage::text, COALESCE(a.attstattarget::integer, -1), a.attacl IS NULL,
               a.attcollation = t.typcollation
          FROM pg_catalog.pg_attribute AS a
          JOIN pg_catalog.pg_class AS c ON c.oid = a.attrelid
          JOIN pg_catalog.pg_namespace AS n ON n.oid = c.relnamespace
          LEFT JOIN pg_catalog.pg_attrdef AS d
            ON d.adrelid = a.attrelid AND d.adnum = a.attnum
          JOIN pg_catalog.pg_type AS t ON t.oid = a.atttypid
         WHERE n.nspname = 'lmm_meta' AND c.relname = 'lmm_adoption_ledger'
           AND a.attnum > 0 AND NOT a.attisdropped
         ORDER BY a.attnum
        "#,
        &[],
    )?;
    const EXPECTED_COLUMNS: &[(&str, &str, &str)] = &[
        ("singleton", "boolean", "p"),
        ("plan_sha256", "text", "x"),
        ("release_revision", "text", "x"),
        ("release_artifact_sha256", "text", "x"),
        ("public_catalog_sha256", "text", "x"),
        ("database_name", "text", "x"),
        ("database_role", "text", "x"),
        ("postgres_major", "integer", "p"),
    ];
    if columns.len() != EXPECTED_COLUMNS.len()
        || columns.iter().zip(EXPECTED_COLUMNS).any(|(row, expected)| {
            row.get::<_, String>(0) != expected.0
                || row.get::<_, String>(1) != expected.1
                || !row.get::<_, bool>(2)
                || row.get::<_, bool>(3)
                || !row.get::<_, String>(4).is_empty()
                || !row.get::<_, String>(5).is_empty()
                || row.get::<_, String>(6) != expected.2
                || row.get::<_, i32>(7) != -1
                || !row.get::<_, bool>(8)
                || !row.get::<_, bool>(9)
        })
    {
        return Err(AdoptionError::LedgerConflict);
    }

    let constraints = transaction.query(
        r#"
        SELECT con.conname, con.contype::text, con.conkey::text,
               con.convalidated, con.condeferrable, con.condeferred
          FROM pg_catalog.pg_constraint AS con
          JOIN pg_catalog.pg_class AS c ON c.oid = con.conrelid
          JOIN pg_catalog.pg_namespace AS n ON n.oid = c.relnamespace
         WHERE n.nspname = 'lmm_meta' AND c.relname = 'lmm_adoption_ledger'
           AND con.contype = 'p'
         ORDER BY con.conname
        "#,
        &[],
    )?;
    if constraints.len() != 1
        || constraints[0].get::<_, String>(0) != "lmm_adoption_ledger_pkey"
        || constraints[0].get::<_, String>(1) != "p"
        || constraints[0].get::<_, String>(2) != "{1}"
        || !constraints[0].get::<_, bool>(3)
        || constraints[0].get::<_, bool>(4)
        || constraints[0].get::<_, bool>(5)
    {
        return Err(AdoptionError::LedgerConflict);
    }

    let index = transaction.query_one(
        r#"
        SELECT ic.relname, pg_catalog.pg_get_userbyid(ic.relowner), am.amname,
               i.indisunique, i.indisprimary, i.indisvalid, i.indisready,
               i.indnkeyatts, i.indnatts, i.indkey::text,
               opn.nspname, opc.opcname, i.indcollation::text, i.indoption::text,
               i.indexprs IS NULL, i.indpred IS NULL
          FROM pg_catalog.pg_index AS i
          JOIN pg_catalog.pg_class AS ic ON ic.oid = i.indexrelid
          JOIN pg_catalog.pg_class AS tc ON tc.oid = i.indrelid
          JOIN pg_catalog.pg_namespace AS n ON n.oid = tc.relnamespace
          JOIN pg_catalog.pg_am AS am ON am.oid = ic.relam
          JOIN pg_catalog.pg_opclass AS opc ON opc.oid = i.indclass[0]
          JOIN pg_catalog.pg_namespace AS opn ON opn.oid = opc.opcnamespace
         WHERE n.nspname = 'lmm_meta' AND tc.relname = 'lmm_adoption_ledger'
        "#,
        &[],
    )?;
    if index.get::<_, String>(0) != "lmm_adoption_ledger_pkey"
        || index.get::<_, String>(1) != expected_owner
        || index.get::<_, String>(2) != "btree"
        || !index.get::<_, bool>(3)
        || !index.get::<_, bool>(4)
        || !index.get::<_, bool>(5)
        || !index.get::<_, bool>(6)
        || index.get::<_, i16>(7) != 1
        || index.get::<_, i16>(8) != 1
        || index.get::<_, String>(9) != "1"
        || index.get::<_, String>(10) != "pg_catalog"
        || index.get::<_, String>(11) != "bool_ops"
        || index.get::<_, String>(12) != "0"
        || index.get::<_, String>(13) != "0"
        || !index.get::<_, bool>(14)
        || !index.get::<_, bool>(15)
    {
        return Err(AdoptionError::LedgerConflict);
    }
    Ok(())
}

fn insert_adoption(
    transaction: &mut Transaction<'_>,
    plan: &ValidatedPlan,
    catalog: &CatalogFingerprint,
) -> Result<(), AdoptionError> {
    let inserted = transaction.execute(
        r#"
        INSERT INTO lmm_meta.lmm_adoption_ledger
          (singleton, plan_sha256, release_revision, release_artifact_sha256,
           public_catalog_sha256, database_name, database_role, postgres_major)
        VALUES (TRUE, $1, $2, $3, $4, $5, $6, $7)
        "#,
        &[
            &plan.sha256.as_str(),
            &plan.release_revision.as_str(),
            &plan.release_artifact_sha256.as_str(),
            &catalog.sha256.as_str(),
            &catalog.identity.database,
            &catalog.identity.role,
            &catalog.identity.postgres_major,
        ],
    )?;
    if inserted != 1 {
        return Err(AdoptionError::LedgerConflict);
    }
    Ok(())
}

fn validate_existing_adoption(
    transaction: &mut Transaction<'_>,
    plan: &ValidatedPlan,
    catalog: &CatalogFingerprint,
) -> Result<(), AdoptionError> {
    let rows = transaction.query(
        r#"
        SELECT singleton, plan_sha256, release_revision, release_artifact_sha256,
               public_catalog_sha256, database_name, database_role, postgres_major
          FROM lmm_meta.lmm_adoption_ledger
        "#,
        &[],
    )?;
    if rows.len() != 1 {
        return Err(AdoptionError::LedgerConflict);
    }
    let row = &rows[0];
    if !row.get::<_, bool>(0)
        || row.get::<_, String>(1) != plan.sha256.as_str()
        || row.get::<_, String>(2) != plan.release_revision.as_str()
        || row.get::<_, String>(3) != plan.release_artifact_sha256.as_str()
        || row.get::<_, String>(4) != catalog.sha256.as_str()
        || row.get::<_, String>(5) != catalog.identity.database
        || row.get::<_, String>(6) != catalog.identity.role
        || row.get::<_, i32>(7) != catalog.identity.postgres_major
    {
        return Err(AdoptionError::LedgerConflict);
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn valid_maintenance_quiescence_json() -> &'static str {
        r#"{
          "format_version": 1,
          "status": "verified",
          "verifier": "test-deploy-verifier",
          "service_stopped": true,
          "migration_capable_sessions": 0,
          "principal_scope": "deployment_managed_only"
        }"#
    }

    fn plan_json(application_ddl: &str) -> String {
        format!(
            r#"{{
              "format_version": 2,
              "operation": "postgres_adopt_existing",
              "app_schema": "public",
              "control_schema": "lmm_meta",
              "expected_database": "lmm_test",
              "expected_role": "lmm_test_role",
              "expected_postgres_major": 17,
              "expected_configured_search_path": "public",
              "expected_current_schema": "public",
              "expected_effective_schemas": ["pg_catalog", "public"],
              "release_revision": "release-1",
              "release_artifact_sha256": "{}",
              "expected_public_catalog_sha256": "{}",
              "maintenance_quiescence": {},
              "application_ddl": {application_ddl}
            }}"#,
            "a".repeat(64),
            "b".repeat(64),
            valid_maintenance_quiescence_json()
        )
    }

    #[test]
    fn plan_should_require_verified_maintenance_quiescence() {
        let mut plan: RawPlan = serde_json::from_str(&plan_json("[]")).expect("valid plan JSON");
        assert!(validate_raw_plan(&plan).is_ok());

        plan.maintenance_quiescence.service_stopped = false;
        assert!(matches!(
            validate_raw_plan(&plan),
            Err(AdoptionError::MaintenanceQuiescenceInvalid)
        ));

        plan.maintenance_quiescence.service_stopped = true;
        plan.maintenance_quiescence.migration_capable_sessions = 1;
        assert!(matches!(
            validate_raw_plan(&plan),
            Err(AdoptionError::MaintenanceQuiescenceInvalid)
        ));

        plan.maintenance_quiescence.migration_capable_sessions = 0;
        plan.maintenance_quiescence.principal_scope = "all_principals".into();
        assert!(matches!(
            validate_raw_plan(&plan),
            Err(AdoptionError::MaintenanceQuiescenceInvalid)
        ));
    }

    #[test]
    fn plan_should_require_literal_empty_application_ddl() {
        assert!(serde_json::from_str::<RawPlan>(&plan_json("[]")).is_ok());
        assert!(serde_json::from_str::<RawPlan>(&plan_json(r#"["CREATE TABLE x()"]"#)).is_err());
    }

    #[test]
    fn ledger_schema_query_casts_statistics_target_to_stable_integer() {
        let source = include_str!("postgres_adopt.rs");
        assert!(source.contains("COALESCE(a.attstattarget::integer, -1)"));
        assert!(source.contains("row.get::<_, i32>(7) != -1"));
    }

    #[test]
    fn ledger_schema_uses_column_not_null_and_scopes_constraint_to_primary_key() {
        let source = include_str!("postgres_adopt.rs");
        assert!(source.contains("|| !row.get::<_, bool>(2)"));
        assert!(source.contains("AND con.contype = 'p'"));
    }

    #[test]
    fn plan_should_pin_configured_and_effective_schema_resolution() {
        let mut plan: RawPlan = serde_json::from_str(&plan_json("[]")).expect("valid plan JSON");
        assert!(validate_raw_plan(&plan).is_ok());

        plan.expected_configured_search_path = "pg_catalog, public".into();
        assert!(matches!(
            validate_raw_plan(&plan),
            Err(AdoptionError::PlanBindingMismatch)
        ));

        plan.expected_configured_search_path = "public".into();
        plan.expected_effective_schemas[1] = "lmm_meta".into();
        assert!(matches!(
            validate_raw_plan(&plan),
            Err(AdoptionError::PlanBindingMismatch)
        ));
    }

    #[test]
    fn runtime_schema_should_reject_unsafe_configured_path_before_normalization() {
        let safe = RuntimeSchemaResolution {
            configured_search_path: "public".into(),
            current_schema: "public".into(),
            effective_schemas: ["pg_catalog".into(), "public".into()],
        };
        assert!(validate_runtime_schema(&safe).is_ok());

        for unsafe_path in [
            "public, pg_catalog",
            "pg_catalog, public",
            "\"$user\", public",
            "lmm_meta, public",
            "\"public\"",
        ] {
            let unsafe_resolution = RuntimeSchemaResolution {
                configured_search_path: unsafe_path.into(),
                current_schema: "public".into(),
                effective_schemas: ["pg_catalog".into(), "public".into()],
            };
            assert!(matches!(
                validate_runtime_schema(&unsafe_resolution),
                Err(AdoptionError::RuntimeSchemaResolutionMismatch)
            ));
        }
    }

    #[test]
    fn plan_should_reject_unknown_fields() {
        let json = plan_json("[]").replace(
            r#""application_ddl": []"#,
            r#""unexpected": true, "application_ddl": []"#,
        );
        assert!(serde_json::from_str::<RawPlan>(&json).is_err());
    }

    #[test]
    fn plan_loader_should_bind_exact_bytes() {
        let directory = tempfile::tempdir().expect("temporary directory");
        let path = directory.path().join("plan.json");
        let bytes = plan_json("[]");
        fs::write(&path, &bytes).expect("write plan");
        let hash = format!("{:x}", Sha256::digest(bytes.as_bytes()));
        let expected = Sha256Digest::parse(&hash, "test").expect("valid hash");
        let plan = load_plan(&path, &expected).expect("valid plan");
        assert_eq!(plan.sha256, expected);
    }

    #[cfg(unix)]
    #[test]
    fn plan_loader_should_reject_symlink() {
        use std::os::unix::fs::symlink;

        let directory = tempfile::tempdir().expect("temporary directory");
        let referent = directory.path().join("referent.json");
        fs::write(&referent, plan_json("[]")).expect("write plan");
        let path = directory.path().join("plan.json");
        symlink(&referent, &path).expect("create symlink");
        let expected = Sha256Digest::parse(&"a".repeat(64), "test").expect("valid hash");
        assert!(matches!(
            load_plan(&path, &expected),
            Err(AdoptionError::UnsafePlanPath)
        ));
    }
}
