mod doctor;
mod executor;
mod plan;

use std::io::{self, IsTerminal, Write};

use clap::{Parser, Subcommand};
use thiserror::Error;

use self::{
    doctor::DoctorReport,
    executor::ExecutionError,
    plan::{PlanError, Tool},
};

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum Dispatch {
    StartServer,
    Completed,
}

#[derive(Debug, Parser)]
#[command(
    name = "lmm-api-rs",
    version,
    about = "Run the Rust API server or bootstrap local agent tools"
)]
struct Cli {
    #[command(subcommand)]
    command: Option<Command>,
}

#[derive(Debug, Subcommand)]
enum Command {
    /// Run the Rust API server. This is also the no-argument default.
    Serve,
    /// Inspect supported agent tools and installation capabilities.
    Doctor {
        /// Emit stable machine-readable JSON.
        #[arg(long)]
        json: bool,
    },
    /// Install CC Switch and selected agent tools.
    Bootstrap {
        /// Tool to install. Repeat to select multiple tools.
        #[arg(long = "tool", value_enum)]
        tools: Vec<Tool>,
        /// Print the complete plan without making changes.
        #[arg(long)]
        dry_run: bool,
        /// Apply the plan without an interactive confirmation prompt.
        #[arg(long, conflicts_with = "dry_run")]
        yes: bool,
    },
}

#[derive(Debug, Error)]
pub enum CliError {
    #[error("serialize doctor report: {0}")]
    Serialize(#[from] serde_json::Error),
    #[error(transparent)]
    Plan(#[from] PlanError),
    #[error(transparent)]
    Execution(#[from] ExecutionError),
    #[error("bootstrap execution in a non-interactive terminal requires --yes")]
    ConfirmationRequired,
    #[error("read confirmation: {0}")]
    ConfirmationIo(#[from] io::Error),
}

pub fn run_from_env() -> Result<Dispatch, CliError> {
    run(Cli::parse())
}

fn run(cli: Cli) -> Result<Dispatch, CliError> {
    match cli.command {
        None | Some(Command::Serve) => Ok(Dispatch::StartServer),
        Some(Command::Doctor { json }) => {
            print_doctor(json)?;
            Ok(Dispatch::Completed)
        }
        Some(Command::Bootstrap {
            tools,
            dry_run,
            yes,
        }) => {
            bootstrap(tools, dry_run, yes)?;
            Ok(Dispatch::Completed)
        }
    }
}

fn print_doctor(json: bool) -> Result<(), CliError> {
    let report = DoctorReport::collect();
    if json {
        println!("{}", serde_json::to_string_pretty(&report)?);
    } else {
        print!("{}", report.render_human());
    }
    Ok(())
}

fn bootstrap(tools: Vec<Tool>, dry_run: bool, yes: bool) -> Result<(), CliError> {
    let report = DoctorReport::collect();
    let plan = plan::build(&report, &tools)?;
    print!("{}", plan.render_human());
    if dry_run || plan.actions.is_empty() {
        return Ok(());
    }

    executor::validate(&plan)?;
    if !yes && !confirm()? {
        println!("Bootstrap cancelled; no changes were made.");
        return Ok(());
    }
    executor::execute(&plan)?;
    println!("Bootstrap completed.");
    Ok(())
}

fn confirm() -> Result<bool, CliError> {
    if !io::stdin().is_terminal() {
        return Err(CliError::ConfirmationRequired);
    }
    print!("Apply this bootstrap plan? [y/N] ");
    io::stdout().flush()?;
    let mut answer = String::new();
    io::stdin().read_line(&mut answer)?;
    Ok(matches!(
        answer.trim().to_ascii_lowercase().as_str(),
        "y" | "yes"
    ))
}

#[cfg(test)]
mod tests {
    use clap::Parser;

    use super::{Cli, Command, Dispatch, run};
    use crate::bootstrap_cli::plan::Tool;

    #[test]
    fn no_arguments_preserve_server_startup() {
        let cli = Cli::try_parse_from(["lmm-api-rs"]).expect("no-argument CLI should parse");

        assert_eq!(
            run(cli).expect("dispatch should succeed"),
            Dispatch::StartServer
        );
    }

    #[test]
    fn explicit_serve_starts_the_server() {
        let cli = Cli::try_parse_from(["lmm-api-rs", "serve"]).expect("serve command should parse");

        assert_eq!(
            run(cli).expect("dispatch should succeed"),
            Dispatch::StartServer
        );
    }

    #[test]
    fn doctor_json_command_parses() {
        let cli = Cli::try_parse_from(["lmm-api-rs", "doctor", "--json"])
            .expect("doctor command should parse");
        assert!(matches!(cli.command, Some(Command::Doctor { json: true })));
    }

    #[test]
    fn bootstrap_tools_parse_in_user_order() {
        let cli = Cli::try_parse_from([
            "lmm-api-rs",
            "bootstrap",
            "--tool",
            "dsh",
            "--tool",
            "codex",
            "--dry-run",
        ])
        .expect("bootstrap command should parse");
        assert!(matches!(
            cli.command,
            Some(Command::Bootstrap {
                tools,
                dry_run: true,
                yes: false,
            }) if tools == vec![Tool::Dsh, Tool::Codex]
        ));
    }

    #[test]
    fn bootstrap_rejects_yes_with_dry_run() {
        assert!(Cli::try_parse_from(["lmm-api-rs", "bootstrap", "--dry-run", "--yes"]).is_err());
    }

    #[test]
    fn unknown_server_arguments_are_rejected() {
        assert!(Cli::try_parse_from(["lmm-api-rs", "serve", "--unknown"]).is_err());
    }
}
