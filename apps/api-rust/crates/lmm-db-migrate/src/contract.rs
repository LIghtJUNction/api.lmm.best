//! Transactional installation and verification of the application schema contract ledger.

use std::{collections::BTreeMap, fs, path::Path, str::FromStr};

use postgres::Transaction;
use serde::Serialize;
use serde_json::Value;
use sha2::{Digest, Sha256};
use thiserror::Error;

use crate::release::{
    ComponentHash, MANDATORY_COMPONENT_NAMES, ReleaseBinding, ReleaseId, Sha256Digest,
};

const SCHEMA_TOKEN: &str = "__LMM_APP_SCHEMA__";
const CONTRACT_TABLE: &str = "lmm_schema_contract";
const LEDGER_TABLE: &str = "lmm_schema_release_ledger";

/// Fail-closed schema-contract installation or validation error.
#[derive(Debug, Error)]
pub enum ContractError {
    /// The contract ledger must never be installed in PostgreSQL's shared `public` schema.
    #[error("schema contract cannot be installed in public")]
    PublicSchema,
    /// The versioned SQL artifact is missing its explicit application-schema placeholder.
    #[error("schema contract SQL is not explicitly schema-qualified")]
    UnqualifiedMigration,
    /// The supplied contract hash does not bind the exact SQL artifact being executed.
    #[error("schema contract SQL hash does not match its binding")]
    ContractHashMismatch,
    /// Only one of the contract tables exists, or persisted rows violate ledger invariants.
    #[error("schema contract ledger is in an unknown state")]
    UnknownState,
    /// An existing contract identifier is bound to a different SQL artifact.
    #[error("schema contract identifier is already bound to a different hash")]
    ContractIdentityConflict,
    /// An existing release identifier is bound to different immutable metadata.
    #[error("release identifier is already bound to different metadata")]
    ReleaseIdentityConflict,
    /// The requested contract precedes the currently installed contract.
    #[error("schema contract downgrade is forbidden")]
    Downgrade,
    /// Reading the versioned SQL artifact failed.
    #[error("schema contract filesystem operation failed: {0}")]
    Io(#[from] std::io::Error),
    /// PostgreSQL rejected a ledger operation.
    #[error("schema contract PostgreSQL operation failed: {0}")]
    Postgres(#[from] postgres::Error),
}

/// Result of a successful contract installation transaction.
#[derive(Clone, Copy, Debug, Eq, PartialEq, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum ContractInstallOutcome {
    /// A fresh ledger and its first release were installed.
    Installed,
    /// A new release or next schema contract was appended to an existing ledger.
    Advanced,
    /// The exact release binding was already present and was verified without writes.
    AlreadyApplied,
}

/// Installs or advances a release binding inside the caller's PostgreSQL transaction.
///
/// The SQL artifact is content-addressed by `binding.contract_sha256()`. The function rejects
/// partial or contradictory ledger state before executing the artifact, and verifies the exact
/// persisted binding before returning. The caller retains responsibility for committing.
///
/// # Errors
///
/// Returns [`ContractError`] for an unsafe schema, artifact mismatch, downgrade, identity
/// conflict, unknown persisted state, filesystem failure, or PostgreSQL failure.
pub fn install_or_verify(
    transaction: &mut Transaction<'_>,
    schema: &str,
    migration: &Path,
    binding: &ReleaseBinding,
) -> Result<ContractInstallOutcome, ContractError> {
    reject_public_schema(schema)?;
    let migration_sql = bound_migration_sql(migration, schema, binding.contract_sha256())?;
    transaction.batch_execute("SET LOCAL search_path = pg_catalog")?;
    match registry_presence(transaction, schema)? {
        RegistryPresence::Missing => {
            if binding.contract_id().as_i64() != 1 {
                return Err(ContractError::UnknownState);
            }
            transaction.batch_execute(&migration_sql)?;
            if registry_presence(transaction, schema)? != RegistryPresence::Complete
                || table_count(transaction, schema, CONTRACT_TABLE)? != 0
                || table_count(transaction, schema, LEDGER_TABLE)? != 0
            {
                return Err(ContractError::UnknownState);
            }
            write_current_contract(transaction, schema, binding, None)?;
            insert_release(transaction, schema, binding)?;
            verify_exact(transaction, schema, binding)?;
            Ok(ContractInstallOutcome::Installed)
        }
        RegistryPresence::Partial => Err(ContractError::UnknownState),
        RegistryPresence::Complete => {
            let state = load_state(transaction, schema)?;
            reconcile_existing(transaction, schema, &migration_sql, binding, &state)
        }
    }
}

/// Verifies that an existing ledger authorizes the exact expected release binding.
///
/// # Errors
///
/// Returns [`ContractError`] when tables or rows are absent, inconsistent, downgraded, or do not
/// match the expected immutable release metadata.
/// Records an immutable contract whose schema was already materialized by a verified cumulative
/// baseline. This path never executes migration SQL and requires a complete existing ledger.
pub(crate) fn record_preapplied(
    transaction: &mut Transaction<'_>,
    schema: &str,
    migration: &Path,
    binding: &ReleaseBinding,
) -> Result<ContractInstallOutcome, ContractError> {
    reject_public_schema(schema)?;
    let sql = fs::read(migration)?;
    let actual_hash = format!("{:x}", Sha256::digest(sql));
    if actual_hash != binding.contract_sha256().as_str() {
        return Err(ContractError::ContractHashMismatch);
    }
    transaction.batch_execute("SET LOCAL search_path = pg_catalog")?;
    if registry_presence(transaction, schema)? != RegistryPresence::Complete {
        return Err(ContractError::UnknownState);
    }
    let state = load_state(transaction, schema)?;
    reconcile_existing(transaction, schema, "", binding, &state)
}

pub fn verify_release(
    transaction: &mut Transaction<'_>,
    schema: &str,
    binding: &ReleaseBinding,
) -> Result<(), ContractError> {
    reject_public_schema(schema)?;
    transaction.batch_execute("SET LOCAL search_path = pg_catalog")?;
    if registry_presence(transaction, schema)? != RegistryPresence::Complete {
        return Err(ContractError::UnknownState);
    }
    let state = load_state(transaction, schema)?;
    if binding.contract_id().as_i64() < state.current.contract_id {
        return Err(ContractError::Downgrade);
    }
    verify_binding_against_state(binding, &state)
}

fn reconcile_existing(
    transaction: &mut Transaction<'_>,
    schema: &str,
    migration_sql: &str,
    binding: &ReleaseBinding,
    state: &InstalledState,
) -> Result<ContractInstallOutcome, ContractError> {
    let incoming_id = binding.contract_id().as_i64();
    if incoming_id < state.current.contract_id {
        return Err(ContractError::Downgrade);
    }
    if incoming_id == state.current.contract_id
        && binding.contract_sha256().as_str() != state.current.contract_sha256
    {
        return Err(ContractError::ContractIdentityConflict);
    }
    if incoming_id > state.current.contract_id.saturating_add(1) {
        return Err(ContractError::UnknownState);
    }
    if state.releases.iter().any(|release| {
        release.contract_id == incoming_id
            && release.contract_sha256 != binding.contract_sha256().as_str()
    }) {
        return Err(ContractError::ContractIdentityConflict);
    }
    if let Some(release) = state
        .releases
        .iter()
        .find(|release| release.release_id == binding.release_id().as_str())
    {
        if incoming_id == state.current.contract_id && release.matches(binding) {
            verify_binding_against_state(binding, state)?;
            return Ok(ContractInstallOutcome::AlreadyApplied);
        }
        return Err(ContractError::ReleaseIdentityConflict);
    }

    if incoming_id > state.current.contract_id {
        transaction.batch_execute(migration_sql)?;
        write_current_contract(
            transaction,
            schema,
            binding,
            Some(state.current.contract_id),
        )?;
    }
    insert_release(transaction, schema, binding)?;
    verify_exact(transaction, schema, binding)?;
    Ok(ContractInstallOutcome::Advanced)
}

fn verify_exact(
    transaction: &mut Transaction<'_>,
    schema: &str,
    binding: &ReleaseBinding,
) -> Result<(), ContractError> {
    let state = load_state(transaction, schema)?;
    verify_binding_against_state(binding, &state)
}

fn verify_binding_against_state(
    binding: &ReleaseBinding,
    state: &InstalledState,
) -> Result<(), ContractError> {
    let incoming_id = binding.contract_id().as_i64();
    if state.current.contract_id != incoming_id
        || state.current.contract_sha256 != binding.contract_sha256().as_str()
        || state.current.min_reader_version != binding.readers().minimum().as_i64()
        || state.current.max_reader_version != binding.readers().maximum().as_i64()
        || state.current.min_writer_version != binding.writers().minimum().as_i64()
        || state.current.max_writer_version != binding.writers().maximum().as_i64()
    {
        return Err(ContractError::UnknownState);
    }
    match state
        .releases
        .iter()
        .find(|release| release.release_id == binding.release_id().as_str())
    {
        Some(release) if release.matches(binding) => Ok(()),
        Some(_) => Err(ContractError::ReleaseIdentityConflict),
        None => Err(ContractError::UnknownState),
    }
}

fn reject_public_schema(schema: &str) -> Result<(), ContractError> {
    if schema == "public" {
        Err(ContractError::PublicSchema)
    } else {
        Ok(())
    }
}

fn bound_migration_sql(
    path: &Path,
    schema: &str,
    expected_hash: &Sha256Digest,
) -> Result<String, ContractError> {
    let sql = fs::read_to_string(path)?;
    let actual_hash = format!("{:x}", Sha256::digest(sql.as_bytes()));
    if actual_hash != expected_hash.as_str() {
        return Err(ContractError::ContractHashMismatch);
    }
    if !sql.contains(SCHEMA_TOKEN) || sql.contains("public.") {
        return Err(ContractError::UnqualifiedMigration);
    }
    let qualified = sql.replace(SCHEMA_TOKEN, &quote_ident(schema));
    if qualified.contains(SCHEMA_TOKEN) {
        return Err(ContractError::UnqualifiedMigration);
    }
    Ok(qualified)
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
enum RegistryPresence {
    Missing,
    Partial,
    Complete,
}

fn registry_presence(
    transaction: &mut Transaction<'_>,
    schema: &str,
) -> Result<RegistryPresence, ContractError> {
    let row = transaction.query_one(
        r#"
        SELECT
          EXISTS (
            SELECT 1 FROM pg_catalog.pg_class c
            JOIN pg_catalog.pg_namespace n ON n.oid = c.relnamespace
            WHERE n.nspname = $1 AND c.relname = $2 AND c.relkind = 'r'
          ),
          EXISTS (
            SELECT 1 FROM pg_catalog.pg_class c
            JOIN pg_catalog.pg_namespace n ON n.oid = c.relnamespace
            WHERE n.nspname = $1 AND c.relname = $3 AND c.relkind = 'r'
          )
        "#,
        &[&schema, &CONTRACT_TABLE, &LEDGER_TABLE],
    )?;
    match (row.get::<_, bool>(0), row.get::<_, bool>(1)) {
        (false, false) => Ok(RegistryPresence::Missing),
        (true, true) => Ok(RegistryPresence::Complete),
        _ => Ok(RegistryPresence::Partial),
    }
}

fn table_count(
    transaction: &mut Transaction<'_>,
    schema: &str,
    table: &str,
) -> Result<i64, ContractError> {
    let query = format!(
        "SELECT count(*)::bigint FROM {}.{}",
        quote_ident(schema),
        quote_ident(table)
    );
    Ok(transaction.query_one(&query, &[])?.get(0))
}

#[derive(Debug)]
struct StoredContract {
    contract_id: i64,
    contract_sha256: String,
    min_reader_version: i64,
    max_reader_version: i64,
    min_writer_version: i64,
    max_writer_version: i64,
}

#[derive(Debug)]
struct StoredRelease {
    release_id: String,
    release_sha256: String,
    contract_id: i64,
    contract_sha256: String,
    min_reader_version: i64,
    max_reader_version: i64,
    min_writer_version: i64,
    max_writer_version: i64,
    components: BTreeMap<String, String>,
}

impl StoredRelease {
    fn matches(&self, binding: &ReleaseBinding) -> bool {
        self.release_sha256 == binding.release_sha256().as_str()
            && self.contract_id == binding.contract_id().as_i64()
            && self.contract_sha256 == binding.contract_sha256().as_str()
            && self.min_reader_version == binding.readers().minimum().as_i64()
            && self.max_reader_version == binding.readers().maximum().as_i64()
            && self.min_writer_version == binding.writers().minimum().as_i64()
            && self.max_writer_version == binding.writers().maximum().as_i64()
            && self.components.len() == binding.components().len()
            && self.components.iter().all(|(name, hash)| {
                binding
                    .components()
                    .get(name)
                    .is_some_and(|expected| expected.as_str() == hash)
            })
    }

    fn has_same_contract_as(&self, other: &Self) -> bool {
        self.contract_id == other.contract_id
            && self.contract_sha256 == other.contract_sha256
            && self.min_reader_version == other.min_reader_version
            && self.max_reader_version == other.max_reader_version
            && self.min_writer_version == other.min_writer_version
            && self.max_writer_version == other.max_writer_version
    }

    fn matches_current_contract(&self, current: &StoredContract) -> bool {
        self.contract_id == current.contract_id
            && self.contract_sha256 == current.contract_sha256
            && self.min_reader_version == current.min_reader_version
            && self.max_reader_version == current.max_reader_version
            && self.min_writer_version == current.min_writer_version
            && self.max_writer_version == current.max_writer_version
    }
}

struct InstalledState {
    current: StoredContract,
    releases: Vec<StoredRelease>,
}

fn load_state(
    transaction: &mut Transaction<'_>,
    schema: &str,
) -> Result<InstalledState, ContractError> {
    let contract_query = format!(
        "SELECT contract_id, contract_sha256, min_reader_version, max_reader_version, \
         min_writer_version, max_writer_version FROM {}.{} WHERE singleton = TRUE",
        quote_ident(schema),
        quote_ident(CONTRACT_TABLE)
    );
    let contract_rows = transaction.query(&contract_query, &[])?;
    if contract_rows.len() != 1 {
        return Err(ContractError::UnknownState);
    }
    let row = &contract_rows[0];
    let current = StoredContract {
        contract_id: row.get(0),
        contract_sha256: row.get(1),
        min_reader_version: row.get(2),
        max_reader_version: row.get(3),
        min_writer_version: row.get(4),
        max_writer_version: row.get(5),
    };
    if !valid_contract(&current) {
        return Err(ContractError::UnknownState);
    }

    let ledger_query = format!(
        "SELECT release_id, release_sha256, contract_id, contract_sha256, min_reader_version, \
         max_reader_version, min_writer_version, max_writer_version, component_hashes \
         FROM {}.{} ORDER BY contract_id, release_id",
        quote_ident(schema),
        quote_ident(LEDGER_TABLE)
    );
    let rows = transaction.query(&ledger_query, &[])?;
    if rows.is_empty() {
        return Err(ContractError::UnknownState);
    }
    let mut releases = Vec::with_capacity(rows.len());
    for row in rows {
        let release = StoredRelease {
            release_id: row.get(0),
            release_sha256: row.get(1),
            contract_id: row.get(2),
            contract_sha256: row.get(3),
            min_reader_version: row.get(4),
            max_reader_version: row.get(5),
            min_writer_version: row.get(6),
            max_writer_version: row.get(7),
            components: parse_components(row.get(8))?,
        };
        if !valid_release(&release) {
            return Err(ContractError::UnknownState);
        }
        releases.push(release);
    }
    let Some(first) = releases.first() else {
        return Err(ContractError::UnknownState);
    };
    if first.contract_id != 1 {
        return Err(ContractError::UnknownState);
    }
    for adjacent in releases.windows(2) {
        let previous = &adjacent[0];
        let next = &adjacent[1];
        if next.contract_id == previous.contract_id {
            if !next.has_same_contract_as(previous) {
                return Err(ContractError::UnknownState);
            }
        } else if previous.contract_id.checked_add(1) != Some(next.contract_id) {
            return Err(ContractError::UnknownState);
        }
    }
    if !releases
        .last()
        .is_some_and(|release| release.matches_current_contract(&current))
    {
        return Err(ContractError::UnknownState);
    }
    Ok(InstalledState { current, releases })
}

fn valid_contract(contract: &StoredContract) -> bool {
    contract.contract_id > 0
        && valid_hash(&contract.contract_sha256)
        && valid_range(contract.min_reader_version, contract.max_reader_version)
        && valid_range(contract.min_writer_version, contract.max_writer_version)
}

fn valid_release(release: &StoredRelease) -> bool {
    ReleaseId::from_str(&release.release_id).is_ok()
        && valid_hash(&release.release_sha256)
        && release.contract_id > 0
        && valid_hash(&release.contract_sha256)
        && valid_range(release.min_reader_version, release.max_reader_version)
        && valid_range(release.min_writer_version, release.max_writer_version)
        && !release.components.is_empty()
}

fn valid_hash(value: &str) -> bool {
    Sha256Digest::parse(value, "stored_sha256").is_ok()
}

fn valid_range(minimum: i64, maximum: i64) -> bool {
    minimum > 0 && maximum >= minimum
}

fn parse_components(value: Value) -> Result<BTreeMap<String, String>, ContractError> {
    let object = value.as_object().ok_or(ContractError::UnknownState)?;
    if object.is_empty() {
        return Err(ContractError::UnknownState);
    }
    let mut components = BTreeMap::new();
    for (name, value) in object {
        if !MANDATORY_COMPONENT_NAMES.contains(&name.as_str()) {
            return Err(ContractError::UnknownState);
        }
        let hash = value.as_str().ok_or(ContractError::UnknownState)?;
        ComponentHash::from_str(&format!("{name}={hash}"))
            .map_err(|_| ContractError::UnknownState)?;
        components.insert(name.clone(), hash.to_owned());
    }
    if components.len() != MANDATORY_COMPONENT_NAMES.len()
        || MANDATORY_COMPONENT_NAMES
            .iter()
            .any(|name| !components.contains_key(*name))
    {
        return Err(ContractError::UnknownState);
    }
    Ok(components)
}

fn write_current_contract(
    transaction: &mut Transaction<'_>,
    schema: &str,
    binding: &ReleaseBinding,
    previous_contract_id: Option<i64>,
) -> Result<(), ContractError> {
    let table = format!("{}.{}", quote_ident(schema), quote_ident(CONTRACT_TABLE));
    let arguments: [&(dyn postgres::types::ToSql + Sync); 6] = [
        &binding.contract_id().as_i64(),
        &binding.contract_sha256().as_str(),
        &binding.readers().minimum().as_i64(),
        &binding.readers().maximum().as_i64(),
        &binding.writers().minimum().as_i64(),
        &binding.writers().maximum().as_i64(),
    ];
    let changed = if let Some(previous_contract_id) = previous_contract_id {
        transaction.execute(
            &format!(
                "UPDATE {table} SET contract_id=$1, contract_sha256=$2, min_reader_version=$3, \
                 max_reader_version=$4, min_writer_version=$5, max_writer_version=$6 \
                 WHERE singleton=TRUE AND contract_id={previous_contract_id}"
            ),
            &arguments,
        )?
    } else {
        transaction.execute(
            &format!(
                "INSERT INTO {table} (singleton, contract_id, contract_sha256, min_reader_version, \
                 max_reader_version, min_writer_version, max_writer_version) \
                 VALUES (TRUE, $1, $2, $3, $4, $5, $6)"
            ),
            &arguments,
        )?
    };
    if changed != 1 {
        return Err(ContractError::UnknownState);
    }
    Ok(())
}

fn insert_release(
    transaction: &mut Transaction<'_>,
    schema: &str,
    binding: &ReleaseBinding,
) -> Result<(), ContractError> {
    let query = format!(
        "INSERT INTO {}.{} (release_id, release_sha256, contract_id, contract_sha256, \
         min_reader_version, max_reader_version, min_writer_version, max_writer_version, \
         component_hashes) VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9)",
        quote_ident(schema),
        quote_ident(LEDGER_TABLE)
    );
    let inserted = transaction.execute(
        &query,
        &[
            &binding.release_id().as_str(),
            &binding.release_sha256().as_str(),
            &binding.contract_id().as_i64(),
            &binding.contract_sha256().as_str(),
            &binding.readers().minimum().as_i64(),
            &binding.readers().maximum().as_i64(),
            &binding.writers().minimum().as_i64(),
            &binding.writers().maximum().as_i64(),
            &binding.component_json(),
        ],
    )?;
    if inserted != 1 {
        return Err(ContractError::UnknownState);
    }
    Ok(())
}

fn quote_ident(value: &str) -> String {
    format!("\"{}\"", value.replace('"', "\"\""))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn migration_sql_should_reject_public_schema_before_reading() {
        let error = reject_public_schema("public").expect_err("public must be rejected");
        assert!(matches!(error, ContractError::PublicSchema));
    }
}
