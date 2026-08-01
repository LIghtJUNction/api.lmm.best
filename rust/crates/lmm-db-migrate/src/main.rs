use std::path::PathBuf;

use clap::{Parser, Subcommand};
use lmm_db_migrate::{
    MigrationError, inspect::inspect_sqlite, manifest::Manifest, report::write_atomic,
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
    }
    Ok(())
}

fn main() -> std::process::ExitCode {
    match run(Cli::parse()) {
        Ok(()) => std::process::ExitCode::SUCCESS,
        Err(error) => {
            eprintln!("error: {error}");
            std::process::ExitCode::FAILURE
        }
    }
}
