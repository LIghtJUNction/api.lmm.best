use lmm_application::ValkeyReadinessPolicy;
use std::{env, net::SocketAddr, time::Duration};
use thiserror::Error;
#[derive(Clone)]
pub struct Config {
    pub listen_addr: SocketAddr,
    pub slot: String,
    pub database_url: String,
    pub valkey_url: String,
    pub schema_contract: i64,
    pub dependency_timeout: Duration,
    pub drain_timeout: Duration,
    pub public_content_cache_ttl: Duration,
    pub valkey_readiness_policy: ValkeyReadinessPolicy,
    pub global_api_rate_limit: u64,
    pub global_api_rate_limit_window: Duration,
}

impl std::fmt::Debug for Config {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        formatter
            .debug_struct("Config")
            .field("listen_addr", &self.listen_addr)
            .field("slot", &self.slot)
            .field("database_url", &"[REDACTED]")
            .field("valkey_url", &"[REDACTED]")
            .field("schema_contract", &self.schema_contract)
            .field("dependency_timeout", &self.dependency_timeout)
            .field("drain_timeout", &self.drain_timeout)
            .field("public_content_cache_ttl", &self.public_content_cache_ttl)
            .field("valkey_readiness_policy", &self.valkey_readiness_policy)
            .field("global_api_rate_limit", &self.global_api_rate_limit)
            .field(
                "global_api_rate_limit_window",
                &self.global_api_rate_limit_window,
            )
            .finish()
    }
}
#[derive(Debug, Error)]
pub enum ConfigError {
    #[error("required environment variable {0} is missing")]
    Missing(&'static str),
    #[error("environment variable {0} is invalid")]
    Invalid(&'static str),
}
impl Config {
    pub fn from_env() -> Result<Self, ConfigError> {
        Ok(Self {
            slot: validated_slot(read("LMM_RS_SLOT")?)?,
            listen_addr: read("LMM_RS_LISTEN_ADDR")?
                .parse()
                .map_err(|_| ConfigError::Invalid("LMM_RS_LISTEN_ADDR"))?,
            database_url: read("DATABASE_URL")?,
            valkey_url: read("VALKEY_URL")?,
            schema_contract: read("LMM_SCHEMA_CONTRACT")?
                .parse()
                .map_err(|_| ConfigError::Invalid("LMM_SCHEMA_CONTRACT"))?,
            dependency_timeout: seconds("LMM_DEPENDENCY_TIMEOUT_SECONDS", 2)?,
            drain_timeout: seconds("LMM_DRAIN_TIMEOUT_SECONDS", 30)?,
            public_content_cache_ttl: positive_seconds("LMM_PUBLIC_CONTENT_CACHE_TTL_SECONDS", 5)?,
            valkey_readiness_policy: ValkeyReadinessPolicy::from_global_api_rate_limit_enabled(
                boolean("GLOBAL_API_RATE_LIMIT_ENABLE", true)?,
            ),
            global_api_rate_limit: positive_integer("GLOBAL_API_RATE_LIMIT", 360)?,
            global_api_rate_limit_window: positive_seconds("GLOBAL_API_RATE_LIMIT_DURATION", 180)?,
        })
    }
}
fn validated_slot(value: String) -> Result<String, ConfigError> {
    match value.as_str() {
        "blue" | "green" => Ok(value),
        _ => Err(ConfigError::Invalid("LMM_RS_SLOT")),
    }
}
fn read(name: &'static str) -> Result<String, ConfigError> {
    env::var(name).map_err(|_| ConfigError::Missing(name))
}
fn seconds(name: &'static str, default: u64) -> Result<Duration, ConfigError> {
    let value = env::var(name).map_or_else(
        |_| Ok(default),
        |raw| raw.parse().map_err(|_| ConfigError::Invalid(name)),
    )?;
    Ok(Duration::from_secs(value))
}
fn positive_seconds(name: &'static str, default: u64) -> Result<Duration, ConfigError> {
    let value = seconds(name, default)?;
    if value.is_zero() {
        Err(ConfigError::Invalid(name))
    } else {
        Ok(value)
    }
}
fn positive_integer(name: &'static str, default: u64) -> Result<u64, ConfigError> {
    let value = env::var(name).map_or_else(
        |_| Ok(default),
        |raw| raw.parse().map_err(|_| ConfigError::Invalid(name)),
    )?;
    if value == 0 {
        Err(ConfigError::Invalid(name))
    } else {
        Ok(value)
    }
}
fn boolean(name: &'static str, default: bool) -> Result<bool, ConfigError> {
    env::var(name).map_or(Ok(default), |raw| match raw.as_str() {
        "true" | "1" => Ok(true),
        "false" | "0" => Ok(false),
        _ => Err(ConfigError::Invalid(name)),
    })
}

#[cfg(test)]
mod tests {
    use super::Config;
    use lmm_application::ValkeyReadinessPolicy;
    use std::{net::SocketAddr, time::Duration};

    #[test]
    fn debug_should_redact_connection_urls() {
        let config = Config {
            listen_addr: SocketAddr::from(([127, 0, 0, 1], 3001)),
            slot: "green".to_owned(),
            database_url: "postgres://secret@localhost/database".to_owned(),
            valkey_url: "redis://:secret@localhost".to_owned(),
            schema_contract: 1,
            dependency_timeout: Duration::from_secs(2),
            drain_timeout: Duration::from_secs(30),
            public_content_cache_ttl: Duration::from_secs(5),
            valkey_readiness_policy: ValkeyReadinessPolicy::RequiredForRateLimiting,
            global_api_rate_limit: 360,
            global_api_rate_limit_window: Duration::from_secs(180),
        };
        let rendered = format!("{config:?}");
        assert!(!rendered.contains("secret"));
    }
}
