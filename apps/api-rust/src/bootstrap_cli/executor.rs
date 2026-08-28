use std::{
    fs::{self, File, OpenOptions},
    io::Write,
    path::{Path, PathBuf},
    process::Command,
    time::{Duration, SystemTime, UNIX_EPOCH},
};

use futures_util::StreamExt;
use reqwest::{Client, redirect::Policy};
use thiserror::Error;

use super::{
    cc_switch_release::{self, ReleaseError},
    plan::{InstallAction, InstallPlan, Tool},
};

const MAX_INSTALLER_BYTES: u64 = 1024 * 1024;
const MAX_REDIRECTS: usize = 5;

#[derive(Debug, Error)]
pub enum ExecutionError {
    #[error(
        "automatic installation for {tool} requires a verified release format that is not supported"
    )]
    UnsupportedAction { tool: &'static str },
    #[error(transparent)]
    CcSwitchRelease(#[from] ReleaseError),
    #[error("unapproved upstream installer URL: {0}")]
    UnapprovedInstaller(String),
    #[error("build installer HTTP client: {0}")]
    HttpClient(String),
    #[error("download upstream installer: {0}")]
    Download(String),
    #[error("upstream installer returned HTTP {0}")]
    HttpStatus(u16),
    #[error("upstream installer redirected to an unapproved origin: {0}")]
    UnapprovedRedirect(String),
    #[error("upstream installer exceeds the {MAX_INSTALLER_BYTES}-byte limit")]
    InstallerTooLarge,
    #[error("create temporary installer: {0}")]
    CreateTemp(String),
    #[error("write temporary installer: {0}")]
    WriteTemp(String),
    #[error("failed to start {program}: {message}")]
    StartFailed { program: String, message: String },
    #[error("{program} exited unsuccessfully with status {status}")]
    CommandFailed { program: String, status: String },
}

pub fn validate(plan: &InstallPlan) -> Result<(), ExecutionError> {
    for action in &plan.actions {
        match action {
            InstallAction::Command { .. } => {}
            InstallAction::OfficialInstaller {
                url, interpreter, ..
            } => validate_official_installer(url, interpreter)?,
            InstallAction::UpstreamRelease {
                tool: Tool::CcSwitch,
                repository,
                ..
            } => cc_switch_release::validate_action(repository)?,
            InstallAction::UpstreamRelease { .. } => {
                return Err(ExecutionError::UnsupportedAction {
                    tool: action.tool().slug(),
                });
            }
        }
    }
    Ok(())
}

pub async fn execute(plan: &InstallPlan) -> Result<(), ExecutionError> {
    validate(plan)?;
    for action in &plan.actions {
        match action {
            InstallAction::Command {
                program, arguments, ..
            } => run_command(program, arguments)?,
            InstallAction::OfficialInstaller {
                url, interpreter, ..
            } => run_official_installer(url, interpreter).await?,
            InstallAction::UpstreamRelease {
                tool: Tool::CcSwitch,
                repository,
                ..
            } => {
                cc_switch_release::validate_action(repository)?;
                cc_switch_release::install().await?;
            }
            InstallAction::UpstreamRelease { .. } => {
                return Err(ExecutionError::UnsupportedAction {
                    tool: action.tool().slug(),
                });
            }
        }
    }
    Ok(())
}

fn validate_official_installer(url: &str, interpreter: &str) -> Result<(), ExecutionError> {
    let approved = matches!(
        (url, interpreter),
        ("https://claude.ai/install.sh", "sh")
            | ("https://claude.ai/install.ps1", "powershell")
            | ("https://chatgpt.com/codex/install.sh", "sh")
            | ("https://chatgpt.com/codex/install.ps1", "powershell")
    );
    if approved {
        Ok(())
    } else {
        Err(ExecutionError::UnapprovedInstaller(url.to_owned()))
    }
}

async fn run_official_installer(url: &str, interpreter: &str) -> Result<(), ExecutionError> {
    validate_official_installer(url, interpreter)?;
    let client = Client::builder()
        .user_agent(concat!("lmm-api-rs/", env!("CARGO_PKG_VERSION")))
        .connect_timeout(Duration::from_secs(10))
        .timeout(Duration::from_secs(30))
        .redirect(Policy::custom(|attempt| {
            if attempt.previous().len() >= MAX_REDIRECTS || attempt.url().scheme() != "https" {
                attempt.stop()
            } else {
                attempt.follow()
            }
        }))
        .build()
        .map_err(|error| ExecutionError::HttpClient(error.to_string()))?;
    let response = client
        .get(url)
        .send()
        .await
        .map_err(|error| ExecutionError::Download(error.to_string()))?;
    if !response.status().is_success() {
        return Err(ExecutionError::HttpStatus(response.status().as_u16()));
    }
    if !approved_response_origin(url, response.url()) {
        return Err(ExecutionError::UnapprovedRedirect(
            response.url().to_string(),
        ));
    }
    if response
        .content_length()
        .is_some_and(|length| length > MAX_INSTALLER_BYTES)
    {
        return Err(ExecutionError::InstallerTooLarge);
    }

    let extension = if interpreter == "powershell" {
        "ps1"
    } else {
        "sh"
    };
    let (mut installer, temporary_path) = create_temp_installer(extension)?;
    let mut downloaded = 0_u64;
    let mut stream = response.bytes_stream();
    while let Some(chunk) = stream.next().await {
        let chunk = chunk.map_err(|error| ExecutionError::Download(error.to_string()))?;
        downloaded = downloaded.saturating_add(chunk.len() as u64);
        if downloaded > MAX_INSTALLER_BYTES {
            return Err(ExecutionError::InstallerTooLarge);
        }
        installer
            .write_all(&chunk)
            .map_err(|error| ExecutionError::WriteTemp(error.to_string()))?;
    }
    installer
        .sync_all()
        .map_err(|error| ExecutionError::WriteTemp(error.to_string()))?;
    drop(installer);
    make_executable(temporary_path.path())?;

    let path = temporary_path.path().to_string_lossy().into_owned();
    match interpreter {
        "sh" => run_command("sh", &[path]),
        "powershell" => run_command(
            "powershell.exe",
            &[
                "-NoLogo".to_owned(),
                "-NoProfile".to_owned(),
                "-NonInteractive".to_owned(),
                "-ExecutionPolicy".to_owned(),
                "Bypass".to_owned(),
                "-File".to_owned(),
                path,
            ],
        ),
        _ => Err(ExecutionError::UnapprovedInstaller(url.to_owned())),
    }
}

fn approved_response_origin(requested: &str, response: &reqwest::Url) -> bool {
    if response.scheme() != "https" {
        return false;
    }
    let Some(host) = response.host_str() else {
        return false;
    };
    if requested.starts_with("https://claude.ai/") {
        matches!(host, "claude.ai" | "downloads.claude.ai")
    } else if requested.starts_with("https://chatgpt.com/") {
        matches!(host, "chatgpt.com" | "releases.openai.com")
    } else {
        false
    }
}

fn run_command(program: &str, arguments: &[String]) -> Result<(), ExecutionError> {
    let status = Command::new(program)
        .args(arguments)
        .status()
        .map_err(|error| ExecutionError::StartFailed {
            program: program.to_owned(),
            message: error.to_string(),
        })?;
    if !status.success() {
        return Err(ExecutionError::CommandFailed {
            program: program.to_owned(),
            status: status.to_string(),
        });
    }
    Ok(())
}

fn create_temp_installer(extension: &str) -> Result<(File, TemporaryPath), ExecutionError> {
    let timestamp = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map_or(0, |duration| duration.as_nanos());
    for attempt in 0..8_u8 {
        let path = std::env::temp_dir().join(format!(
            "lmm-api-rs-installer-{}-{timestamp}-{attempt}.{extension}",
            std::process::id()
        ));
        match OpenOptions::new().write(true).create_new(true).open(&path) {
            Ok(file) => return Ok((file, TemporaryPath(path))),
            Err(error) if error.kind() == std::io::ErrorKind::AlreadyExists => continue,
            Err(error) => return Err(ExecutionError::CreateTemp(error.to_string())),
        }
    }
    Err(ExecutionError::CreateTemp(
        "could not allocate a unique path".to_owned(),
    ))
}

fn make_executable(path: &Path) -> Result<(), ExecutionError> {
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;

        fs::set_permissions(path, fs::Permissions::from_mode(0o700))
            .map_err(|error| ExecutionError::WriteTemp(error.to_string()))?;
    }
    Ok(())
}

struct TemporaryPath(PathBuf);

impl TemporaryPath {
    fn path(&self) -> &Path {
        &self.0
    }
}

impl Drop for TemporaryPath {
    fn drop(&mut self) {
        let _ = fs::remove_file(&self.0);
    }
}

#[cfg(test)]
mod tests {
    use super::{ExecutionError, approved_response_origin, validate, validate_official_installer};
    use crate::bootstrap_cli::plan::{InstallAction, InstallPlan, Tool};

    #[test]
    fn unsupported_action_rejects_the_whole_plan_before_execution() {
        let plan = InstallPlan {
            requested: vec![Tool::Codex],
            skipped_installed: Vec::new(),
            actions: vec![InstallAction::UpstreamRelease {
                tool: Tool::Codex,
                repository: "example/repository",
                asset_hint: "example",
            }],
        };

        assert!(matches!(
            validate(&plan),
            Err(ExecutionError::UnsupportedAction { tool: "codex" })
        ));
    }

    #[test]
    fn approved_cc_switch_release_passes_preflight() {
        let plan = InstallPlan {
            requested: vec![Tool::CcSwitch],
            skipped_installed: Vec::new(),
            actions: vec![InstallAction::UpstreamRelease {
                tool: Tool::CcSwitch,
                repository: "farion1231/cc-switch",
                asset_hint: "test",
            }],
        };

        assert!(validate(&plan).is_ok());
    }

    #[test]
    fn command_and_approved_installer_plan_passes_preflight() {
        let plan = InstallPlan {
            requested: vec![Tool::Dsh, Tool::ClaudeCode],
            skipped_installed: Vec::new(),
            actions: vec![
                InstallAction::Command {
                    tool: Tool::Dsh,
                    program: "npm".to_owned(),
                    arguments: vec!["--version".to_owned()],
                    source: "test",
                },
                InstallAction::OfficialInstaller {
                    tool: Tool::ClaudeCode,
                    url: "https://claude.ai/install.sh",
                    interpreter: "sh",
                },
            ],
        };

        assert!(validate(&plan).is_ok());
    }

    #[test]
    fn arbitrary_download_and_execute_url_is_rejected() {
        assert!(matches!(
            validate_official_installer("https://example.com/install.sh", "sh"),
            Err(ExecutionError::UnapprovedInstaller(_))
        ));
    }

    #[test]
    fn redirect_origin_must_match_the_upstream_allowlist() -> Result<(), Box<dyn std::error::Error>>
    {
        let claude_cdn =
            reqwest::Url::parse("https://downloads.claude.ai/claude-code-releases/bootstrap.sh")?;
        let codex_cdn = reqwest::Url::parse("https://releases.openai.com/codex/install.sh")?;
        let rejected = reqwest::Url::parse("https://example.com/install.sh")?;

        assert!(approved_response_origin(
            "https://claude.ai/install.sh",
            &claude_cdn
        ));
        assert!(approved_response_origin(
            "https://chatgpt.com/codex/install.sh",
            &codex_cdn
        ));
        assert!(!approved_response_origin(
            "https://claude.ai/install.sh",
            &rejected
        ));
        Ok(())
    }
}
