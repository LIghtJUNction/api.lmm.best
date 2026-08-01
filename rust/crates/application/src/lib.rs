#![deny(missing_docs)]
//! Application ports used to keep infrastructure replaceable and testable.
use async_trait::async_trait;
use lmm_domain::PublicContentKind;
use std::sync::Arc;
use thiserror::Error;

/// Safe failure returned when public content cannot be read from authoritative storage.
#[derive(Debug, Error)]
#[error("public content read failed")]
pub struct PublicContentError;

/// Optional cache failure. Callers must fall back to PostgreSQL.
#[derive(Debug, Error)]
#[error("public content cache failed")]
pub struct PublicContentCacheError;

/// Outcome of one global API fixed-window rate-limit check.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum RateLimitOutcome {
    /// Request is within the configured window allowance.
    Allowed,
    /// Request exceeded the allowance.
    Rejected {
        /// Remaining fixed-window lifetime in seconds, when Valkey reports one.
        retry_after_seconds: Option<u64>,
    },
}

/// Fail-closed Valkey rate-limit error.
#[derive(Debug, Error)]
#[error("global API rate limit check failed")]
pub struct RateLimitError;

/// Global API rate-limit port.
#[async_trait]
pub trait GlobalApiRateLimiter: Send + Sync {
    /// Atomically consumes one request for a canonical client IP.
    async fn check(&self, client_ip: &str) -> Result<RateLimitOutcome, RateLimitError>;
}

/// Authoritative storage port for public content.
#[async_trait]
pub trait PublicContentRepository: Send + Sync {
    /// Reads a content value. A missing or SQL `NULL` value is represented as `None`.
    async fn get(&self, kind: PublicContentKind) -> Result<Option<String>, PublicContentError>;
}

/// Non-authoritative cache port for public content.
#[async_trait]
pub trait PublicContentCache: Send + Sync {
    /// Returns a cached value or `None` on a cache miss.
    async fn get(&self, kind: PublicContentKind)
    -> Result<Option<String>, PublicContentCacheError>;
    /// Stores a value with the adapter's bounded TTL.
    async fn put(
        &self,
        kind: PublicContentKind,
        value: &str,
    ) -> Result<(), PublicContentCacheError>;
}

/// Read-only public-content use case.
pub struct PublicContentService {
    repository: Arc<dyn PublicContentRepository>,
    cache: Arc<dyn PublicContentCache>,
}

impl PublicContentService {
    /// Creates the use case around an authoritative repository.
    pub fn new(
        repository: Arc<dyn PublicContentRepository>,
        cache: Arc<dyn PublicContentCache>,
    ) -> Self {
        Self { repository, cache }
    }

    /// Returns the legacy-compatible value; Go defaults absent options to an empty string.
    pub async fn read(&self, kind: PublicContentKind) -> Result<String, PublicContentError> {
        if let Ok(Some(value)) = self.cache.get(kind).await {
            return Ok(value);
        }
        let value = self.repository.get(kind).await?.unwrap_or_default();
        let _ = self.cache.put(kind, &value).await;
        Ok(value)
    }
}

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
    use super::{
        ProbeError, PublicContentCache, PublicContentCacheError, PublicContentError,
        PublicContentRepository, PublicContentService, ReadinessProbe, check_readiness,
    };
    use async_trait::async_trait;
    use lmm_domain::PublicContentKind;
    use std::sync::{
        Arc,
        atomic::{AtomicUsize, Ordering},
    };

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

    struct MockContentRepository(Option<String>);

    struct MissingCache;

    struct HitCache(&'static str);

    struct CountingRepository {
        reads: AtomicUsize,
        value: &'static str,
    }

    #[async_trait]
    impl PublicContentCache for MissingCache {
        async fn get(
            &self,
            _kind: PublicContentKind,
        ) -> Result<Option<String>, PublicContentCacheError> {
            Ok(None)
        }

        async fn put(
            &self,
            _kind: PublicContentKind,
            _value: &str,
        ) -> Result<(), PublicContentCacheError> {
            Ok(())
        }
    }

    #[async_trait]
    impl PublicContentCache for HitCache {
        async fn get(
            &self,
            _kind: PublicContentKind,
        ) -> Result<Option<String>, PublicContentCacheError> {
            Ok(Some(self.0.to_owned()))
        }

        async fn put(
            &self,
            _kind: PublicContentKind,
            _value: &str,
        ) -> Result<(), PublicContentCacheError> {
            Ok(())
        }
    }

    #[async_trait]
    impl PublicContentRepository for CountingRepository {
        async fn get(
            &self,
            _kind: PublicContentKind,
        ) -> Result<Option<String>, PublicContentError> {
            self.reads.fetch_add(1, Ordering::Relaxed);
            Ok(Some(self.value.to_owned()))
        }
    }

    #[async_trait]
    impl PublicContentRepository for MockContentRepository {
        async fn get(
            &self,
            _kind: PublicContentKind,
        ) -> Result<Option<String>, PublicContentError> {
            Ok(self.0.clone())
        }
    }

    #[tokio::test]
    async fn missing_public_content_should_match_the_go_empty_default() {
        let service = PublicContentService::new(
            Arc::new(MockContentRepository(None)),
            Arc::new(MissingCache),
        );
        assert_eq!(
            service
                .read(PublicContentKind::Notice)
                .await
                .expect("read succeeds"),
            ""
        );
    }

    #[tokio::test]
    async fn cache_hit_should_not_read_postgres() {
        let repository = Arc::new(CountingRepository {
            reads: AtomicUsize::new(0),
            value: "postgres",
        });
        let service = PublicContentService::new(repository.clone(), Arc::new(HitCache("valkey")));
        assert_eq!(
            service
                .read(PublicContentKind::About)
                .await
                .expect("cache read succeeds"),
            "valkey"
        );
        assert_eq!(repository.reads.load(Ordering::Relaxed), 0);
    }

    #[tokio::test]
    async fn cache_miss_should_read_authoritative_postgres() {
        let repository = Arc::new(CountingRepository {
            reads: AtomicUsize::new(0),
            value: "postgres",
        });
        let service = PublicContentService::new(repository.clone(), Arc::new(MissingCache));
        assert_eq!(
            service
                .read(PublicContentKind::HomePage)
                .await
                .expect("postgres fallback succeeds"),
            "postgres"
        );
        assert_eq!(repository.reads.load(Ordering::Relaxed), 1);
    }
}
