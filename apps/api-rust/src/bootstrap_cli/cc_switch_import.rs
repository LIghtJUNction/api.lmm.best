use std::process::Command;

use clap::ValueEnum;
use reqwest::Url;
use secrecy::{ExposeSecret, SecretString};
use thiserror::Error;

#[derive(Clone, Copy, Debug, Eq, PartialEq, ValueEnum)]
pub enum CcSwitchApp {
    Claude,
    Codex,
}

impl CcSwitchApp {
    const fn slug(self) -> &'static str {
        match self {
            Self::Claude => "claude",
            Self::Codex => "codex",
        }
    }
}

#[derive(Debug, Error)]
pub enum ImportError {
    #[error("construct CC Switch import URI: {0}")]
    InvalidUri(String),
    #[error("unsupported CC Switch URI platform: {0}")]
    UnsupportedPlatform(&'static str),
    #[error("failed to open CC Switch: {0}")]
    Open(String),
    #[error("CC Switch URI handler exited unsuccessfully with status {0}")]
    HandlerFailed(String),
}

pub struct CcSwitchImportUri(SecretString);

impl CcSwitchImportUri {
    fn expose(&self) -> &str {
        self.0.expose_secret()
    }
}

impl std::fmt::Debug for CcSwitchImportUri {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        formatter.write_str("CcSwitchImportUri([REDACTED])")
    }
}

pub fn build_provider_uri(
    app: CcSwitchApp,
    endpoint: &Url,
    api_key: SecretString,
) -> Result<CcSwitchImportUri, ImportError> {
    if endpoint.scheme() != "https" || endpoint.host_str().is_none() {
        return Err(ImportError::InvalidUri(
            "provider endpoint must be HTTPS".to_owned(),
        ));
    }
    let mut import = Url::parse("ccswitch://v1/import")
        .map_err(|error| ImportError::InvalidUri(error.to_string()))?;
    import
        .query_pairs_mut()
        .append_pair("resource", "provider")
        .append_pair("app", app.slug())
        .append_pair("name", "api.lmm.best")
        .append_pair("endpoint", endpoint.as_str())
        .append_pair("apiKey", api_key.expose_secret())
        .append_pair("homepage", endpoint.as_str())
        .append_pair("enabled", "true");
    Ok(CcSwitchImportUri(SecretString::from(String::from(import))))
}

pub fn open_provider_uri(uri: &CcSwitchImportUri) -> Result<(), ImportError> {
    let status = match std::env::consts::OS {
        "linux" => Command::new("xdg-open").arg(uri.expose()).status(),
        "macos" => Command::new("open").arg(uri.expose()).status(),
        "windows" => Command::new("rundll32.exe")
            .arg("url.dll,FileProtocolHandler")
            .arg(uri.expose())
            .status(),
        platform => return Err(ImportError::UnsupportedPlatform(platform)),
    }
    .map_err(|error| ImportError::Open(error.to_string()))?;
    if status.success() {
        Ok(())
    } else {
        Err(ImportError::HandlerFailed(status.to_string()))
    }
}

#[cfg(test)]
mod tests {
    use reqwest::Url;
    use secrecy::SecretString;

    use super::{CcSwitchApp, build_provider_uri};

    #[test]
    fn provider_uri_matches_the_cc_switch_contract_without_debug_secret_leak()
    -> Result<(), Box<dyn std::error::Error>> {
        let endpoint = Url::parse("https://api.lmm.best")?;
        let uri = build_provider_uri(
            CcSwitchApp::Claude,
            &endpoint,
            SecretString::from("fixture-key-value".to_owned()),
        )?;
        let parsed = Url::parse(uri.expose())?;
        let parameters: std::collections::HashMap<_, _> =
            parsed.query_pairs().into_owned().collect();

        assert_eq!(parsed.scheme(), "ccswitch");
        assert_eq!(parsed.host_str(), Some("v1"));
        assert_eq!(parsed.path(), "/import");
        assert_eq!(
            parameters.get("resource").map(String::as_str),
            Some("provider")
        );
        assert_eq!(parameters.get("app").map(String::as_str), Some("claude"));
        assert_eq!(
            parameters.get("apiKey").map(String::as_str),
            Some("fixture-key-value")
        );
        assert!(!format!("{uri:?}").contains("fixture-key-value"));
        Ok(())
    }

    #[test]
    fn provider_uri_rejects_non_https_endpoints() -> Result<(), Box<dyn std::error::Error>> {
        let endpoint = Url::parse("http://api.lmm.best")?;
        assert!(
            build_provider_uri(
                CcSwitchApp::Codex,
                &endpoint,
                SecretString::from("fixture".to_owned())
            )
            .is_err()
        );
        Ok(())
    }
}
