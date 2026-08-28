use std::collections::BTreeSet;

use clap::ValueEnum;
use serde::Serialize;
use thiserror::Error;

use super::doctor::{Component, DoctorReport};

#[derive(Clone, Copy, Debug, Eq, Ord, PartialEq, PartialOrd, Serialize, ValueEnum)]
#[serde(rename_all = "kebab-case")]
pub enum Tool {
    CcSwitch,
    Codex,
    ClaudeCode,
    Dsh,
}

impl Tool {
    pub const STABLE_DEFAULTS: [Self; 3] = [Self::CcSwitch, Self::Codex, Self::ClaudeCode];

    const fn component(self) -> Component {
        match self {
            Self::CcSwitch => Component::CcSwitch,
            Self::Codex => Component::Codex,
            Self::ClaudeCode => Component::ClaudeCode,
            Self::Dsh => Component::Dsh,
        }
    }

    pub const fn slug(self) -> &'static str {
        match self {
            Self::CcSwitch => "cc-switch",
            Self::Codex => "codex",
            Self::ClaudeCode => "claude-code",
            Self::Dsh => "dsh",
        }
    }
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
enum Platform {
    Linux,
    MacOs,
    Windows,
}

impl Platform {
    fn parse(value: &str) -> Result<Self, PlanError> {
        match value {
            "linux" => Ok(Self::Linux),
            "macos" => Ok(Self::MacOs),
            "windows" => Ok(Self::Windows),
            other => Err(PlanError::UnsupportedPlatform(other.to_owned())),
        }
    }
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize)]
#[serde(tag = "kind", rename_all = "kebab-case")]
pub enum InstallAction {
    Command {
        tool: Tool,
        program: String,
        arguments: Vec<String>,
        source: &'static str,
    },
    UpstreamRelease {
        tool: Tool,
        repository: &'static str,
        asset_hint: &'static str,
    },
    OfficialInstaller {
        tool: Tool,
        url: &'static str,
        interpreter: &'static str,
    },
}

impl InstallAction {
    pub const fn tool(&self) -> Tool {
        match self {
            Self::Command { tool, .. }
            | Self::UpstreamRelease { tool, .. }
            | Self::OfficialInstaller { tool, .. } => *tool,
        }
    }

    fn render(&self) -> String {
        match self {
            Self::Command {
                program,
                arguments,
                source,
                ..
            } => format!("{program} {}  [{source}]", arguments.join(" ")),
            Self::UpstreamRelease {
                repository,
                asset_hint,
                ..
            } => format!("download verified release from {repository} ({asset_hint})"),
            Self::OfficialInstaller {
                url, interpreter, ..
            } => format!(
                "download {url}, then run its checksum-verifying installer with {interpreter}"
            ),
        }
    }
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize)]
pub struct InstallPlan {
    pub requested: Vec<Tool>,
    pub skipped_installed: Vec<Tool>,
    pub actions: Vec<InstallAction>,
}

impl InstallPlan {
    #[must_use]
    pub fn render_human(&self) -> String {
        let mut output = String::from("Bootstrap plan:\n");
        for tool in &self.skipped_installed {
            output.push_str(&format!("  [skip] {} is already installed\n", tool.slug()));
        }
        for (index, action) in self.actions.iter().enumerate() {
            output.push_str(&format!(
                "  {}. {}: {}\n",
                index + 1,
                action.tool().slug(),
                action.render()
            ));
        }
        if self.actions.is_empty() {
            output.push_str("  Nothing to install.\n");
        }
        output
    }
}

#[derive(Debug, Error, Eq, PartialEq)]
pub enum PlanError {
    #[error("unsupported bootstrap platform: {0}")]
    UnsupportedPlatform(String),
    #[error("{tool} requires {requirement}, but it is unavailable")]
    MissingCapability {
        tool: &'static str,
        requirement: &'static str,
    },
}

pub fn build(report: &DoctorReport, requested: &[Tool]) -> Result<InstallPlan, PlanError> {
    let platform = Platform::parse(report.platform)?;
    let requested = normalize_requested(requested);
    let mut skipped_installed = Vec::new();
    let mut actions = Vec::new();

    for tool in &requested {
        if report
            .components
            .iter()
            .any(|status| status.component == tool.component() && status.installed)
        {
            skipped_installed.push(*tool);
            continue;
        }
        actions.push(plan_tool(platform, report, *tool)?);
    }

    Ok(InstallPlan {
        requested,
        skipped_installed,
        actions,
    })
}

fn normalize_requested(requested: &[Tool]) -> Vec<Tool> {
    let requested = if requested.is_empty() {
        Tool::STABLE_DEFAULTS.as_slice()
    } else {
        requested
    };
    let mut unique: BTreeSet<_> = requested.iter().copied().collect();
    unique.insert(Tool::CcSwitch);

    let mut normalized = Vec::with_capacity(unique.len());
    normalized.push(Tool::CcSwitch);
    normalized.extend(unique.into_iter().filter(|tool| *tool != Tool::CcSwitch));
    normalized
}

fn plan_tool(
    platform: Platform,
    report: &DoctorReport,
    tool: Tool,
) -> Result<InstallAction, PlanError> {
    match tool {
        Tool::CcSwitch => Ok(plan_cc_switch(platform, report)),
        Tool::Codex => Ok(plan_codex(platform, report)),
        Tool::ClaudeCode => Ok(plan_claude_code(platform)),
        Tool::Dsh => plan_dsh(report),
    }
}

fn plan_cc_switch(platform: Platform, report: &DoctorReport) -> InstallAction {
    match platform {
        Platform::Linux => {
            if let Some(helper) = report.aur_helper {
                return command(
                    Tool::CcSwitch,
                    helper,
                    &["-S", "--needed", "cc-switch-bin"],
                    "AUR: cc-switch-bin",
                );
            }
            InstallAction::UpstreamRelease {
                tool: Tool::CcSwitch,
                repository: "farion1231/cc-switch",
                asset_hint: "Linux AppImage or native package",
            }
        }
        Platform::MacOs if has_installer(report, "brew") => command(
            Tool::CcSwitch,
            "brew",
            &["install", "--cask", "cc-switch"],
            "Homebrew cask: cc-switch",
        ),
        Platform::MacOs => InstallAction::UpstreamRelease {
            tool: Tool::CcSwitch,
            repository: "farion1231/cc-switch",
            asset_hint: "signed and notarized macOS DMG",
        },
        Platform::Windows if has_installer(report, "winget") => command(
            Tool::CcSwitch,
            "winget",
            &[
                "install",
                "--id",
                "farion1231.CC-Switch",
                "--exact",
                "--accept-package-agreements",
                "--accept-source-agreements",
            ],
            "WinGet: farion1231.CC-Switch",
        ),
        Platform::Windows => InstallAction::UpstreamRelease {
            tool: Tool::CcSwitch,
            repository: "farion1231/cc-switch",
            asset_hint: "Minisign-verified Windows MSI",
        },
    }
}

fn plan_codex(platform: Platform, report: &DoctorReport) -> InstallAction {
    if platform == Platform::MacOs && has_installer(report, "brew") {
        return command(
            Tool::Codex,
            "brew",
            &["install", "--cask", "codex"],
            "Homebrew cask: codex",
        );
    }
    if has_installer(report, "npm") {
        return command(
            Tool::Codex,
            "npm",
            &["install", "--global", "@openai/codex"],
            "npm: @openai/codex",
        );
    }
    match platform {
        Platform::Windows => InstallAction::OfficialInstaller {
            tool: Tool::Codex,
            url: "https://chatgpt.com/codex/install.ps1",
            interpreter: "powershell",
        },
        Platform::Linux | Platform::MacOs => InstallAction::OfficialInstaller {
            tool: Tool::Codex,
            url: "https://chatgpt.com/codex/install.sh",
            interpreter: "sh",
        },
    }
}

const fn plan_claude_code(platform: Platform) -> InstallAction {
    match platform {
        Platform::Windows => InstallAction::OfficialInstaller {
            tool: Tool::ClaudeCode,
            url: "https://claude.ai/install.ps1",
            interpreter: "powershell",
        },
        Platform::Linux | Platform::MacOs => InstallAction::OfficialInstaller {
            tool: Tool::ClaudeCode,
            url: "https://claude.ai/install.sh",
            interpreter: "sh",
        },
    }
}

fn plan_dsh(report: &DoctorReport) -> Result<InstallAction, PlanError> {
    if !has_installer(report, "npm") {
        return Err(PlanError::MissingCapability {
            tool: "dsh",
            requirement: "npm",
        });
    }
    Ok(command(
        Tool::Dsh,
        "npm",
        &["install", "--global", "@deepseek-ai/dsh@latest"],
        "npm: @deepseek-ai/dsh",
    ))
}

fn command(tool: Tool, program: &str, arguments: &[&str], source: &'static str) -> InstallAction {
    InstallAction::Command {
        tool,
        program: program.to_owned(),
        arguments: arguments
            .iter()
            .map(|argument| (*argument).to_owned())
            .collect(),
        source,
    }
}

fn has_installer(report: &DoctorReport, name: &str) -> bool {
    report
        .installers
        .iter()
        .any(|installer| installer.name == name && installer.available())
}

#[cfg(test)]
mod tests {
    use std::path::PathBuf;

    use super::{InstallAction, PlanError, Tool, build};
    use crate::bootstrap_cli::doctor::{Component, ComponentStatus, DoctorReport, InstallerStatus};

    fn report(
        platform: &'static str,
        installed: &[Component],
        installers: &[&'static str],
        arch_family: bool,
    ) -> DoctorReport {
        let components = [
            Component::CcSwitch,
            Component::Codex,
            Component::ClaudeCode,
            Component::Dsh,
        ]
        .into_iter()
        .map(|component| ComponentStatus {
            component,
            installed: installed.contains(&component),
            path: installed
                .contains(&component)
                .then(|| PathBuf::from(format!("/test/{component}"))),
        })
        .collect();
        let installers: Vec<_> = installers
            .iter()
            .map(|name| InstallerStatus {
                name,
                path: Some(PathBuf::from(format!("/test/{name}"))),
            })
            .collect();
        let aur_helper = arch_family
            .then(|| {
                installers
                    .iter()
                    .find(|installer| matches!(installer.name, "paru" | "yay"))
                    .map(|installer| installer.name)
            })
            .flatten();
        DoctorReport {
            platform,
            architecture: "test",
            linux_distribution: arch_family.then(|| "arch".to_owned()),
            components,
            installers,
            aur_helper,
        }
    }

    #[test]
    fn cc_switch_is_always_first_and_uses_aur_on_arch_linux() -> Result<(), PlanError> {
        let report = report("linux", &[], &["paru", "npm"], true);
        let plan = build(&report, &[Tool::Dsh])?;

        assert_eq!(plan.requested, vec![Tool::CcSwitch, Tool::Dsh]);
        assert!(matches!(
            &plan.actions[0],
            InstallAction::Command { program, arguments, .. }
                if program == "paru" && arguments.last().is_some_and(|value| value == "cc-switch-bin")
        ));
        Ok(())
    }

    #[test]
    fn non_arch_linux_does_not_use_an_incidental_aur_helper() -> Result<(), PlanError> {
        let report = report("linux", &[], &["paru", "npm"], false);
        let plan = build(&report, &[Tool::CcSwitch])?;

        assert!(matches!(
            plan.actions.as_slice(),
            [InstallAction::UpstreamRelease {
                tool: Tool::CcSwitch,
                ..
            }]
        ));
        Ok(())
    }

    #[test]
    fn installed_tools_are_skipped_without_losing_mandatory_ordering() -> Result<(), PlanError> {
        let report = report(
            "linux",
            &[Component::CcSwitch, Component::Codex],
            &["npm"],
            false,
        );
        let plan = build(&report, &[])?;

        assert_eq!(plan.skipped_installed, vec![Tool::CcSwitch, Tool::Codex]);
        assert_eq!(plan.actions.len(), 1);
        assert_eq!(plan.actions[0].tool(), Tool::ClaudeCode);
        Ok(())
    }

    #[test]
    fn macos_prefers_homebrew_for_cc_switch_and_codex() -> Result<(), PlanError> {
        let report = report("macos", &[], &["brew"], false);
        let plan = build(&report, &[Tool::Codex])?;

        assert!(plan.actions.iter().all(|action| matches!(
            action,
            InstallAction::Command { program, .. } if program == "brew"
        )));
        Ok(())
    }

    #[test]
    fn dsh_requires_npm() {
        let report = report("windows", &[Component::CcSwitch], &[], false);
        assert_eq!(
            build(&report, &[Tool::Dsh]),
            Err(PlanError::MissingCapability {
                tool: "dsh",
                requirement: "npm"
            })
        );
    }

    #[test]
    fn unsupported_platform_is_rejected() {
        let report = report("plan9", &[], &[], false);
        assert_eq!(
            build(&report, &[]),
            Err(PlanError::UnsupportedPlatform("plan9".to_owned()))
        );
    }
}
