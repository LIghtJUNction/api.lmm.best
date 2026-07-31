use std::{env, net::SocketAddr, time::Duration};
use thiserror::Error;
#[derive(Clone)]
pub struct Config {
    pub listen_addr: SocketAddr,
    pub database_url: String,
    pub valkey_url: String,
    pub schema_contract: i64,
    pub dependency_timeout: Duration,
    pub drain_timeout: Duration,
}

impl std::fmt::Debug for Config {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        formatter
            .debug_struct("Config")
            .field("listen_addr", &self.listen_addr)
            .field("database_url", &"[REDACTED]")
            .field("valkey_url", &"[REDACTED]")
            .field("schema_contract", &self.schema_contract)
            .field("dependency_timeout", &self.dependency_timeout)
            .field("drain_timeout", &self.drain_timeout)
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
        })
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

#[cfg(test)]
mod tests {
    use super::Config;
    use std::{net::SocketAddr, time::Duration};

    #[test]
    fn debug_should_redact_connection_urls() {
        let config = Config {
            listen_addr: SocketAddr::from(([127, 0, 0, 1], 3001)),
            database_url: "postgres://secret@localhost/database".to_owned(),
            valkey_url: "redis://:secret@localhost".to_owned(),
            schema_contract: 1,
            dependency_timeout: Duration::from_secs(2),
            drain_timeout: Duration::from_secs(30),
        };
        let rendered = format!("{config:?}");
        assert!(!rendered.contains("secret"));
    }
}
