#![deny(missing_docs)]
//! Application ports used to keep infrastructure replaceable and testable.
use async_trait::async_trait;
use thiserror::Error;

/// A dependency readiness failure without credentials or topology details.
#[derive(Debug, Error)]
#[error("{dependency} readiness check failed")]
pub struct ProbeError {
    /// Stable dependency name used for structured logging.
    pub dependency: &'static str,
}
/// Readiness operations required by the HTTP application.
#[async_trait]
pub trait ReadinessProbe: Send + Sync {
    /// Confirms PostgreSQL accepts queries.
    async fn postgres(&self) -> Result<(), ProbeError>;
    /// Confirms Valkey accepts commands.
    async fn valkey(&self) -> Result<(), ProbeError>;
    /// Confirms the deployed schema permits this binary to serve traffic.
    async fn schema_compatible(&self) -> Result<(), ProbeError>;
}
/// Structured readiness result separating required truth from cache health.
pub struct ReadinessReport {
    /// PostgreSQL or schema failures that must reject traffic.
    pub required_failures: Vec<ProbeError>,
    /// Optional dependency failures that degrade latency but not correctness.
    pub degraded: Vec<ProbeError>,
}

/// Runs every check without short-circuiting, preserving complete diagnostics.
pub async fn check_readiness(probe: &dyn ReadinessProbe) -> ReadinessReport {
    let (postgres, valkey, schema) =
        tokio::join!(probe.postgres(), probe.valkey(), probe.schema_compatible());
    let required_failures = [postgres, schema]
        .into_iter()
        .filter_map(Result::err)
        .collect::<Vec<_>>();
    let degraded = valkey.err().into_iter().collect();
    ReadinessReport {
        required_failures,
        degraded,
    }
}

#[cfg(test)]
mod tests {
    use super::{ProbeError, ReadinessProbe, check_readiness};
    use async_trait::async_trait;

    struct MockProbe {
        failing: Option<&'static str>,
    }

    #[async_trait]
    impl ReadinessProbe for MockProbe {
        async fn postgres(&self) -> Result<(), ProbeError> {
            self.result("postgres")
        }

        async fn valkey(&self) -> Result<(), ProbeError> {
            self.result("valkey")
        }

        async fn schema_compatible(&self) -> Result<(), ProbeError> {
            self.result("schema")
        }
    }

    impl MockProbe {
        fn result(&self, dependency: &'static str) -> Result<(), ProbeError> {
            if self.failing == Some(dependency) {
                Err(ProbeError { dependency })
            } else {
                Ok(())
            }
        }
    }

    #[tokio::test]
    async fn readiness_should_succeed_when_all_dependencies_are_healthy() {
        let result = check_readiness(&MockProbe { failing: None }).await;
        assert!(result.required_failures.is_empty());
    }

    #[tokio::test]
    async fn readiness_should_report_the_failing_dependency() {
        let report = check_readiness(&MockProbe {
            failing: Some("valkey"),
        })
        .await;
        assert_eq!(report.degraded[0].dependency, "valkey");
        assert!(report.required_failures.is_empty());
    }
}
