use std::path::PathBuf;

use clap::{Args, Parser, Subcommand};
use lmm_db_migrate::{
    MigrationError,
    inspect::inspect_sqlite,
    manifest::Manifest,
    migrate::{RehearseOptions, VerifyOptions, rehearse, verify},
    release::{
        CompatibilityRange, ComponentHash, ReleaseBinding, ReleaseId, Sha256Digest, Version,
    },
    report::{FailureAudit, write_atomic},
};

#[derive(Debug, Parser)]
#[command(name = "lmm-db-migrate")]
#[command(about = "Auditable SQLite to PostgreSQL migration tooling")]
struct Cli {
    #[command(subcommand)]
    command: Command,
}

#[derive(Debug, Args)]
struct ReleaseArguments {
    /// Monotonic schema-contract identifier.
    #[arg(long)]
    contract_id: Version,
    /// SHA-256 of the exact schema-contract SQL artifact.
    #[arg(long)]
    contract_sha256: Sha256Digest,
    /// Oldest application schema reader accepted by this contract.
    #[arg(long)]
    min_reader_version: Version,
    /// Newest application schema reader accepted by this contract.
    #[arg(long)]
    max_reader_version: Version,
    /// Oldest application schema writer accepted by this contract.
    #[arg(long)]
    min_writer_version: Version,
    /// Newest application schema writer accepted by this contract.
    #[arg(long)]
    max_writer_version: Version,
    /// Stable immutable release identifier.
    #[arg(long)]
    release_id: ReleaseId,
    /// SHA-256 of the release manifest or canonical release artifact.
    #[arg(long)]
    release_sha256: Sha256Digest,
    /// Immutable release component in `name=sha256` form; repeat for every component.
    #[arg(long = "component-sha256", required = true)]
    components: Vec<ComponentHash>,
}

impl ReleaseArguments {
    fn binding(self) -> Result<ReleaseBinding, MigrationError> {
        Ok(ReleaseBinding::new(
            self.contract_id,
            self.contract_sha256,
            CompatibilityRange::new(self.min_reader_version, self.max_reader_version, "reader")?,
            CompatibilityRange::new(self.min_writer_version, self.max_writer_version, "writer")?,
            self.release_id,
            self.release_sha256,
            self.components,
        )?)
    }
}

#[derive(Debug, Subcommand)]
enum Command {
    /// Validate the checked-in table contract without opening a database.
    ManifestValidate {
        #[arg(long)]
        manifest: PathBuf,
    },
    /// Validate an exported live PostgreSQL catalog against the manifest.
    PostgresCatalogValidate {
        #[arg(long)]
        manifest: PathBuf,
        #[arg(long)]
        catalog: PathBuf,
    },
    /// Inspect SQLite read-only and atomically publish a non-sensitive report.
    Inspect {
        #[arg(long)]
        sqlite: PathBuf,
        #[arg(long)]
        manifest: PathBuf,
        #[arg(long)]
        report: PathBuf,
    },
    /// Create a fresh isolated schema, copy all rows transactionally, and verify it.
    Rehearse {
        #[arg(long)]
        sqlite: PathBuf,
        #[arg(long)]
        manifest: PathBuf,
        #[arg(long)]
        baseline: PathBuf,
        #[arg(long)]
        catalog_sql: PathBuf,
        #[arg(long)]
        contract_migration: PathBuf,
        #[arg(long)]
        schema: String,
        #[arg(long)]
        report: PathBuf,
        #[command(flatten)]
        release: ReleaseArguments,
    },
    /// Independently compare an offline SQLite source with an existing PostgreSQL schema.
    Verify {
        #[arg(long)]
        sqlite: PathBuf,
        #[arg(long)]
        manifest: PathBuf,
        #[arg(long)]
        schema: String,
        #[arg(long)]
        report: PathBuf,
        #[command(flatten)]
        release: ReleaseArguments,
    },
}

impl Command {
    const fn stage(&self) -> &'static str {
        match self {
            Self::ManifestValidate { .. } => "manifest_validate",
            Self::PostgresCatalogValidate { .. } => "postgres_catalog_validate",
            Self::Inspect { .. } => "inspect",
            Self::Rehearse { .. } => "rehearse",
            Self::Verify { .. } => "verify",
        }
    }
}

fn run(cli: Cli) -> Result<(), MigrationError> {
    match cli.command {
        Command::ManifestValidate { manifest } => {
            Manifest::load(&manifest)?;
            println!("manifest valid");
        }
        Command::PostgresCatalogValidate { manifest, catalog } => {
            Manifest::load(&manifest)?.validate_postgres_catalog(&catalog)?;
            println!("PostgreSQL catalog valid");
        }
        Command::Inspect {
            sqlite,
            manifest,
            report,
        } => {
            let manifest = Manifest::load(&manifest)?;
            let inspection = inspect_sqlite(&sqlite, &manifest)?;
            write_atomic(&report, &inspection)?;
            if !inspection.drift.is_empty() {
                return Err(MigrationError::Manifest(format!(
                    "source schema has {} drift finding(s); see report",
                    inspection.drift.len()
                )));
            }
            println!("inspection valid");
        }
        Command::Rehearse {
            sqlite,
            manifest,
            baseline,
            catalog_sql,
            contract_migration,
            schema,
            report,
            release,
        } => {
            let outcome = (|| {
                let database_url = std::env::var("LMM_MIGRATE_DATABASE_URL").map_err(|_| {
                    MigrationError::Manifest("LMM_MIGRATE_DATABASE_URL must be set".into())
                })?;
                let manifest = Manifest::load(&manifest)?;
                let release = release.binding()?;
                let fault_after_table = std::env::var("LMM_MIGRATE_FAULT_AFTER_TABLE").ok();
                rehearse(&RehearseOptions {
                    sqlite: &sqlite,
                    manifest: &manifest,
                    baseline: &baseline,
                    catalog_sql: &catalog_sql,
                    contract_migration: &contract_migration,
                    release: &release,
                    schema: &schema,
                    database_url: &database_url,
                    fault_after_table: fault_after_table.as_deref(),
                    fault_before_verify: std::env::var_os("LMM_MIGRATE_FAULT_BEFORE_VERIFY")
                        .is_some(),
                })
            })();
            publish_audited(&report, "rehearse", outcome)?;
            println!("rehearsal verified");
        }
        Command::Verify {
            sqlite,
            manifest,
            schema,
            report,
            release,
        } => {
            let outcome = (|| {
                let database_url = std::env::var("LMM_MIGRATE_DATABASE_URL").map_err(|_| {
                    MigrationError::Manifest("LMM_MIGRATE_DATABASE_URL must be set".into())
                })?;
                let manifest = Manifest::load(&manifest)?;
                let release = release.binding()?;
                verify(&VerifyOptions {
                    sqlite: &sqlite,
                    manifest: &manifest,
                    schema: &schema,
                    database_url: &database_url,
                    release: &release,
                })
            })();
            publish_audited(&report, "verify", outcome)?;
            println!("verification valid");
        }
    }
    Ok(())
}

fn publish_audited<T: serde::Serialize>(
    report: &std::path::Path,
    stage: &str,
    outcome: Result<T, MigrationError>,
) -> Result<T, MigrationError> {
    match outcome {
        Ok(value) => {
            write_atomic(report, &value)?;
            Ok(value)
        }
        Err(error) => {
            write_atomic(
                report,
                &FailureAudit {
                    status: "failed",
                    stage,
                    error_category: error.category(),
                },
            )?;
            Err(error)
        }
    }
}

fn main() -> std::process::ExitCode {
    let cli = Cli::parse();
    let stage = cli.command.stage();
    match run(cli) {
        Ok(()) => std::process::ExitCode::SUCCESS,
        Err(error) => {
            eprintln!(
                "migration failed: stage={stage} error_category={}",
                error.category()
            );
            std::process::ExitCode::FAILURE
        }
    }
}
