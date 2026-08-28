use std::{
    env,
    ffi::OsString,
    fmt, fs,
    path::{Path, PathBuf},
};

use serde::Serialize;

#[derive(Clone, Copy, Debug, Eq, PartialEq, Serialize)]
#[serde(rename_all = "kebab-case")]
pub enum Component {
    CcSwitch,
    Codex,
    ClaudeCode,
    Dsh,
}

impl Component {
    const ALL: [Self; 4] = [Self::CcSwitch, Self::Codex, Self::ClaudeCode, Self::Dsh];

    const fn binary_names(self) -> &'static [&'static str] {
        match self {
            Self::CcSwitch => &["cc-switch", "cc-switch-app", "CC-Switch"],
            Self::Codex => &["codex"],
            Self::ClaudeCode => &["claude"],
            Self::Dsh => &["dsh"],
        }
    }
}

impl fmt::Display for Component {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter.write_str(match self {
            Self::CcSwitch => "CC Switch",
            Self::Codex => "Codex",
            Self::ClaudeCode => "Claude Code",
            Self::Dsh => "DeepSeek Harness (dsh)",
        })
    }
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize)]
pub struct ComponentStatus {
    pub component: Component,
    pub installed: bool,
    pub path: Option<PathBuf>,
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize)]
pub struct InstallerStatus {
    pub name: &'static str,
    pub path: Option<PathBuf>,
}

impl InstallerStatus {
    pub const fn available(&self) -> bool {
        self.path.is_some()
    }
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize)]
pub struct DoctorReport {
    pub platform: &'static str,
    pub architecture: &'static str,
    pub linux_distribution: Option<String>,
    pub components: Vec<ComponentStatus>,
    pub installers: Vec<InstallerStatus>,
    pub aur_helper: Option<&'static str>,
}

impl DoctorReport {
    #[must_use]
    pub fn collect() -> Self {
        let os_release = (env::consts::OS == "linux")
            .then(|| fs::read_to_string("/etc/os-release").ok())
            .flatten();
        Self::collect_from(
            env::var_os("PATH").as_deref(),
            env::consts::OS,
            env::consts::ARCH,
            os_release.as_deref(),
        )
    }

    #[must_use]
    pub fn collect_from(
        search_path: Option<&std::ffi::OsStr>,
        platform: &'static str,
        architecture: &'static str,
        os_release: Option<&str>,
    ) -> Self {
        let linux_distribution = os_release.and_then(linux_distribution);
        let components = Component::ALL
            .iter()
            .map(|component| {
                let path = component
                    .binary_names()
                    .iter()
                    .find_map(|name| find_executable(name, search_path, platform));
                ComponentStatus {
                    component: *component,
                    installed: path.is_some(),
                    path,
                }
            })
            .collect();
        let installers = [
            "cargo", "paru", "yay", "brew", "winget", "npm", "pnpm", "bun",
        ]
        .iter()
        .map(|name| InstallerStatus {
            name,
            path: find_executable(name, search_path, platform),
        })
        .collect::<Vec<_>>();
        let arch_family = platform == "linux"
            && linux_distribution
                .as_deref()
                .is_some_and(|distribution| distribution == "arch");
        let aur_helper = arch_family.then(|| {
            installers
                .iter()
                .find(|installer| matches!(installer.name, "paru" | "yay") && installer.available())
                .map(|installer| installer.name)
        });

        Self {
            platform,
            architecture,
            linux_distribution,
            components,
            installers,
            aur_helper: aur_helper.flatten(),
        }
    }

    #[must_use]
    pub fn render_human(&self) -> String {
        let distribution = self
            .linux_distribution
            .as_deref()
            .map_or_else(String::new, |value| format!("/{value}"));
        let mut output = format!(
            "lmm-api-rs bootstrap doctor\nplatform: {}{} / {}\n\ncomponents:\n",
            self.platform, distribution, self.architecture
        );
        for status in &self.components {
            let detail = status
                .path
                .as_ref()
                .map_or_else(|| "missing".to_owned(), |path| path.display().to_string());
            output.push_str(&format!("  {:<24} {detail}\n", status.component));
        }
        output.push_str("\ninstallers:\n");
        for installer in &self.installers {
            let detail = installer
                .path
                .as_ref()
                .map_or_else(|| "missing".to_owned(), |path| path.display().to_string());
            output.push_str(&format!("  {:<24} {detail}\n", installer.name));
        }
        output
    }
}

fn linux_distribution(content: &str) -> Option<String> {
    let mut id = None;
    let mut id_like = None;
    for line in content.lines() {
        let Some((key, raw_value)) = line.split_once('=') else {
            continue;
        };
        let value = raw_value.trim().trim_matches('"');
        match key {
            "ID" => id = Some(value),
            "ID_LIKE" => id_like = Some(value),
            _ => {}
        }
    }
    if id == Some("arch")
        || id_like.is_some_and(|value| value.split_ascii_whitespace().any(|item| item == "arch"))
    {
        return Some("arch".to_owned());
    }
    id.filter(|value| !value.is_empty()).map(str::to_owned)
}

fn find_executable(
    name: &str,
    search_path: Option<&std::ffi::OsStr>,
    platform: &str,
) -> Option<PathBuf> {
    env::split_paths(search_path?).find_map(|directory| {
        executable_candidates(name, platform)
            .into_iter()
            .map(|candidate| directory.join(candidate))
            .find(|candidate| is_executable(candidate, platform))
    })
}

fn executable_candidates(name: &str, platform: &str) -> Vec<OsString> {
    let base = OsString::from(name);
    if platform == "windows" && Path::new(name).extension().is_none() {
        vec![
            base.clone(),
            OsString::from(format!("{name}.exe")),
            OsString::from(format!("{name}.cmd")),
        ]
    } else {
        vec![base]
    }
}

fn is_executable(path: &Path, platform: &str) -> bool {
    let Ok(metadata) = path.metadata() else {
        return false;
    };
    if !metadata.is_file() {
        return false;
    }
    if platform == "windows" {
        return true;
    }
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        metadata.permissions().mode() & 0o111 != 0
    }
    #[cfg(not(unix))]
    {
        true
    }
}

#[cfg(test)]
mod tests {
    use std::{ffi::OsString, fs};

    use super::{DoctorReport, find_executable};

    #[cfg(unix)]
    fn make_executable(path: &std::path::Path) {
        use std::os::unix::fs::PermissionsExt;

        fs::write(path, b"fixture").expect("fixture should be writable");
        fs::set_permissions(path, fs::Permissions::from_mode(0o700))
            .expect("fixture permissions should be writable");
    }

    #[cfg(unix)]
    #[test]
    fn find_executable_returns_matching_file_from_explicit_path() {
        let directory = std::env::temp_dir().join(format!(
            "lmm-api-rs-doctor-{}-{}",
            std::process::id(),
            "find"
        ));
        fs::create_dir_all(&directory).expect("fixture directory should be created");
        let executable = directory.join("codex");
        make_executable(&executable);
        let search_path = OsString::from(directory.as_os_str());

        let found = find_executable("codex", Some(&search_path), "linux");

        fs::remove_dir_all(&directory).expect("fixture directory should be removed");
        assert_eq!(found, Some(executable));
    }

    #[cfg(unix)]
    #[test]
    fn find_executable_ignores_non_executable_file() {
        use std::os::unix::fs::PermissionsExt;

        let directory = std::env::temp_dir().join(format!(
            "lmm-api-rs-doctor-{}-{}",
            std::process::id(),
            "mode"
        ));
        fs::create_dir_all(&directory).expect("fixture directory should be created");
        let candidate = directory.join("claude");
        fs::write(&candidate, b"fixture").expect("fixture should be writable");
        fs::set_permissions(&candidate, fs::Permissions::from_mode(0o600))
            .expect("fixture permissions should be writable");
        let search_path = OsString::from(directory.as_os_str());

        let found = find_executable("claude", Some(&search_path), "linux");

        fs::remove_dir_all(&directory).expect("fixture directory should be removed");
        assert_eq!(found, None);
    }

    #[test]
    fn collect_from_marks_arch_like_distribution_for_aur_planning() {
        let report = DoctorReport::collect_from(
            Some(OsString::new().as_os_str()),
            "linux",
            "x86_64",
            Some("ID=manjaro\nID_LIKE=\"arch\"\n"),
        );

        assert_eq!(report.linux_distribution.as_deref(), Some("arch"));
    }

    #[test]
    fn human_report_does_not_include_environment_values() {
        let report = DoctorReport::collect_from(
            Some(OsString::new().as_os_str()),
            "linux",
            "x86_64",
            Some("ID=arch\n"),
        );

        let rendered = report.render_human();

        assert!(!rendered.contains("API_KEY"));
    }
}
