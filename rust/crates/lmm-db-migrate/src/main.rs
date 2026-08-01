use std::path::PathBuf;

use clap::{Parser, Subcommand};
use lmm_db_migrate::{
    MigrationError,
    inspect::inspect_sqlite,
    manifest::Manifest,
    migrate::{RehearseOptions, rehearse, verify},
    report::{FailureAudit, write_atomic},
};

#[derive(Debug, Parser)]
#[command(name = "lmm-db-migrate")]
#[command(about = "Auditable SQLite to PostgreSQL migration tooling")]
struct Cli {
    #[command(subcommand)]
    command: Command,
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
        schema: String,
        #[arg(long)]
        report: PathBuf,
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
            schema,
            report,
        } => {
            let outcome = (|| {
                let database_url = std::env::var("LMM_MIGRATE_DATABASE_URL").map_err(|_| {
                    MigrationError::Manifest("LMM_MIGRATE_DATABASE_URL must be set".into())
                })?;
                let manifest = Manifest::load(&manifest)?;
                let fault_after_table = std::env::var("LMM_MIGRATE_FAULT_AFTER_TABLE").ok();
                rehearse(&RehearseOptions {
                    sqlite: &sqlite,
                    manifest: &manifest,
                    baseline: &baseline,
                    catalog_sql: &catalog_sql,
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
        } => {
            let outcome = (|| {
                let database_url = std::env::var("LMM_MIGRATE_DATABASE_URL").map_err(|_| {
                    MigrationError::Manifest("LMM_MIGRATE_DATABASE_URL must be set".into())
                })?;
                let manifest = Manifest::load(&manifest)?;
                verify(&sqlite, &manifest, &schema, &database_url)
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
