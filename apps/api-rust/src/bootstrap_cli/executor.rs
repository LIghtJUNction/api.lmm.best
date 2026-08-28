use std::process::Command;

use thiserror::Error;

use super::plan::{InstallAction, InstallPlan};

#[derive(Debug, Error, Eq, PartialEq)]
pub enum ExecutionError {
    #[error(
        "automatic installation for {tool} requires the verified release downloader, which is not available yet"
    )]
    UnsupportedAction { tool: &'static str },
    #[error("failed to start {program}: {message}")]
    StartFailed { program: String, message: String },
    #[error("{program} exited unsuccessfully with status {status}")]
    CommandFailed { program: String, status: String },
}

pub fn validate(plan: &InstallPlan) -> Result<(), ExecutionError> {
    for action in &plan.actions {
        if !matches!(action, InstallAction::Command { .. }) {
            return Err(ExecutionError::UnsupportedAction {
                tool: action.tool().slug(),
            });
        }
    }
    Ok(())
}

pub fn execute(plan: &InstallPlan) -> Result<(), ExecutionError> {
    validate(plan)?;
    for action in &plan.actions {
        let InstallAction::Command {
            program, arguments, ..
        } = action
        else {
            return Err(ExecutionError::UnsupportedAction {
                tool: action.tool().slug(),
            });
        };
        let status = Command::new(program)
            .args(arguments)
            .status()
            .map_err(|error| ExecutionError::StartFailed {
                program: program.clone(),
                message: error.to_string(),
            })?;
        if !status.success() {
            return Err(ExecutionError::CommandFailed {
                program: program.clone(),
                status: status.to_string(),
            });
        }
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::{ExecutionError, validate};
    use crate::bootstrap_cli::plan::{InstallAction, InstallPlan, Tool};

    #[test]
    fn unsupported_action_rejects_the_whole_plan_before_execution() {
        let plan = InstallPlan {
            requested: vec![Tool::CcSwitch],
            skipped_installed: Vec::new(),
            actions: vec![InstallAction::UpstreamRelease {
                tool: Tool::CcSwitch,
                repository: "example/repository",
                asset_hint: "example",
            }],
        };

        assert_eq!(
            validate(&plan),
            Err(ExecutionError::UnsupportedAction { tool: "cc-switch" })
        );
    }

    #[test]
    fn command_only_plan_passes_preflight() {
        let plan = InstallPlan {
            requested: vec![Tool::Dsh],
            skipped_installed: Vec::new(),
            actions: vec![InstallAction::Command {
                tool: Tool::Dsh,
                program: "npm".to_owned(),
                arguments: vec!["--version".to_owned()],
                source: "test",
            }],
        };

        assert_eq!(validate(&plan), Ok(()));
    }
}
