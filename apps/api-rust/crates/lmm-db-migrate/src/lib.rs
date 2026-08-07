//! Auditable primitives for the SQLite to PostgreSQL migration.

pub mod canonical;
pub mod contract;
pub mod inspect;
pub mod manifest;
pub mod migrate;
pub mod postgres_adopt;
pub mod postgres_catalog;
pub mod release;
pub mod report;

use thiserror::Error;

/// Failures that make a migration inspection unsafe or inconclusive.
#[derive(Debug, Error)]
pub enum MigrationError {
    /// A filesystem operation failed.
    #[error("filesystem operation failed: {0}")]
    Io(#[from] std::io::Error),
    /// SQLite could not be opened read-only or inspected.
    #[error("SQLite inspection failed: {0}")]
    Sqlite(#[from] rusqlite::Error),
    /// JSON input or output was invalid.
    #[error("JSON processing failed: {0}")]
    Json(#[from] serde_json::Error),
    /// The checked-in table map does not match its contract.
    #[error("manifest validation failed: {0}")]
    Manifest(String),
    /// A source value cannot be converted without information loss.
    #[error("canonical conversion failed: {0}")]
    Canonical(String),
    /// PostgreSQL baseline, copy, or verification failed.
    #[error("PostgreSQL migration failed: {0}")]
    Postgres(#[from] postgres::Error),
    /// The application schema contract or release ledger was unsafe or inconsistent.
    #[error("schema contract failed: {0}")]
    Contract(#[from] contract::ContractError),
    /// PostgreSQL existing-schema adoption was unsafe or inconsistent.
    #[error("PostgreSQL adoption failed: {0}")]
    PostgresAdoption(#[from] postgres_adopt::AdoptionError),
    /// Required release metadata was absent, malformed, or ambiguous.
    #[error("release binding failed: {0}")]
    ReleaseBinding(#[from] release::ReleaseBindingError),
}

impl MigrationError {
    /// Stable non-sensitive category suitable for an audit report.
    #[must_use]
    pub const fn category(&self) -> &'static str {
        match self {
            Self::Io(_) => "filesystem",
            Self::Sqlite(_) => "sqlite",
            Self::Json(_) => "json",
            Self::Manifest(_) => "contract",
            Self::Canonical(_) => "conversion",
            Self::Postgres(_) => "postgresql",
            Self::Contract(_) => "schema_contract",
            Self::PostgresAdoption(_) => "postgres_adoption",
            Self::ReleaseBinding(_) => "release_binding",
        }
    }
}
