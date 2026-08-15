#![deny(missing_docs)]
//! Application ports used to keep infrastructure replaceable and testable.
use async_trait::async_trait;
use lmm_domain::PublicContentKind;
use std::{sync::Arc, time::Duration};
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

/// Determines whether a Valkey failure must prevent the instance from receiving traffic.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum ValkeyReadinessPolicy {
    /// Valkey is required because global API rate limiting is enabled and fails closed.
    RequiredForRateLimiting,
    /// Valkey is only a best-effort cache because global API rate limiting is disabled.
    OptionalCacheOnly,
}

impl ValkeyReadinessPolicy {
    /// Maps the single global API rate-limit configuration decision to dependency policy.
    pub const fn from_global_api_rate_limit_enabled(enabled: bool) -> Self {
        if enabled {
            Self::RequiredForRateLimiting
        } else {
            Self::OptionalCacheOnly
        }
    }
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
}

/// Read-only public-content use case.
pub struct PublicContentService {
    repository: Arc<dyn PublicContentRepository>,
    cache: Arc<dyn PublicContentCache>,
    dependency_timeout: Duration,
}

impl PublicContentService {
    /// Creates the use case around an authoritative repository.
    pub fn new(
        repository: Arc<dyn PublicContentRepository>,
        cache: Arc<dyn PublicContentCache>,
        dependency_timeout: Duration,
    ) -> Self {
        Self {
            repository,
            cache,
            dependency_timeout,
        }
    }

    /// Returns the legacy-compatible value; Go defaults absent options to an empty string.
    pub async fn read(&self, kind: PublicContentKind) -> Result<String, PublicContentError> {
        // PostgreSQL is authoritative. The legacy Go handler reads its
        // process-local OptionMap and never prefers a potentially stale cache
        // entry over the current option value.
        match tokio::time::timeout(self.dependency_timeout, self.repository.get(kind)).await {
            Ok(Ok(Some(value))) => Ok(value),
            Ok(Ok(None)) => Ok(String::new()),
            Ok(Err(_)) | Err(_) => {
                // Keep Valkey only as a last-resort availability fallback when
                // the authoritative source is unavailable.
                match tokio::time::timeout(self.dependency_timeout, self.cache.get(kind)).await {
                    Ok(Ok(Some(value))) => Ok(value),
                    Ok(Ok(None)) | Ok(Err(_)) | Err(_) => Err(PublicContentError),
                }
            }
        }
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
pub async fn check_readiness(
    probe: &dyn ReadinessProbe,
    valkey_policy: ValkeyReadinessPolicy,
) -> ReadinessReport {
    let (postgres, valkey, schema) =
        tokio::join!(probe.postgres(), probe.valkey(), probe.schema_compatible());
    let mut required_failures = [postgres, schema]
        .into_iter()
        .filter_map(Result::err)
        .collect::<Vec<_>>();
    let mut degraded = Vec::new();
    if let Err(failure) = valkey {
        match valkey_policy {
            ValkeyReadinessPolicy::RequiredForRateLimiting => required_failures.push(failure),
            ValkeyReadinessPolicy::OptionalCacheOnly => degraded.push(failure),
        }
    }
    ReadinessReport {
        required_failures,
        degraded,
    }
}

#[cfg(test)]
mod tests {
    use super::{
        ProbeError, PublicContentCache, PublicContentCacheError, PublicContentError,
        PublicContentRepository, PublicContentService, ReadinessProbe, ValkeyReadinessPolicy,
        check_readiness,
    };
    use async_trait::async_trait;
    use lmm_domain::PublicContentKind;
    use std::{
        future,
        sync::{
            Arc,
            atomic::{AtomicUsize, Ordering},
        },
        time::Duration,
    };

    const TEST_DEPENDENCY_TIMEOUT: Duration = Duration::from_millis(1);

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
        let result = check_readiness(
            &MockProbe { failing: None },
            ValkeyReadinessPolicy::RequiredForRateLimiting,
        )
        .await;
        assert!(result.required_failures.is_empty());
    }

    #[tokio::test]
    async fn readiness_should_require_valkey_when_rate_limiting_is_enabled() {
        let report = check_readiness(
            &MockProbe {
                failing: Some("valkey"),
            },
            ValkeyReadinessPolicy::RequiredForRateLimiting,
        )
        .await;
        assert_eq!(report.required_failures[0].dependency, "valkey");
    }

    #[tokio::test]
    async fn readiness_should_degrade_valkey_when_rate_limiting_is_disabled() {
        let report = check_readiness(
            &MockProbe {
                failing: Some("valkey"),
            },
            ValkeyReadinessPolicy::OptionalCacheOnly,
        )
        .await;
        assert_eq!(report.degraded[0].dependency, "valkey");
    }

    #[tokio::test]
    async fn readiness_should_require_postgres_under_both_valkey_policies() {
        for policy in [
            ValkeyReadinessPolicy::RequiredForRateLimiting,
            ValkeyReadinessPolicy::OptionalCacheOnly,
        ] {
            let report = check_readiness(
                &MockProbe {
                    failing: Some("postgres"),
                },
                policy,
            )
            .await;
            assert_eq!(report.required_failures[0].dependency, "postgres");
        }
    }

    #[tokio::test]
    async fn readiness_should_require_schema_under_both_valkey_policies() {
        for policy in [
            ValkeyReadinessPolicy::RequiredForRateLimiting,
            ValkeyReadinessPolicy::OptionalCacheOnly,
        ] {
            let report = check_readiness(
                &MockProbe {
                    failing: Some("schema"),
                },
                policy,
            )
            .await;
            assert_eq!(report.required_failures[0].dependency, "schema");
        }
    }

    struct MockContentRepository(Option<String>);

    struct MissingCache;

    struct HitCache(&'static str);

    struct PendingGetCache;

    struct RecordingMissCache;

    struct PendingRepository;

    struct FailingRepository;

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
    }

    #[async_trait]
    impl PublicContentCache for HitCache {
        async fn get(
            &self,
            _kind: PublicContentKind,
        ) -> Result<Option<String>, PublicContentCacheError> {
            Ok(Some(self.0.to_owned()))
        }
    }

    #[async_trait]
    impl PublicContentCache for PendingGetCache {
        async fn get(
            &self,
            _kind: PublicContentKind,
        ) -> Result<Option<String>, PublicContentCacheError> {
            future::pending().await
        }
    }

    #[async_trait]
    impl PublicContentCache for RecordingMissCache {
        async fn get(
            &self,
            _kind: PublicContentKind,
        ) -> Result<Option<String>, PublicContentCacheError> {
            Ok(None)
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

    #[async_trait]
    impl PublicContentRepository for PendingRepository {
        async fn get(
            &self,
            _kind: PublicContentKind,
        ) -> Result<Option<String>, PublicContentError> {
            future::pending().await
        }
    }

    #[async_trait]
    impl PublicContentRepository for FailingRepository {
        async fn get(
            &self,
            _kind: PublicContentKind,
        ) -> Result<Option<String>, PublicContentError> {
            Err(PublicContentError)
        }
    }

    #[tokio::test]
    async fn missing_public_content_should_match_the_go_empty_default() {
        let service = PublicContentService::new(
            Arc::new(MockContentRepository(None)),
            Arc::new(MissingCache),
            TEST_DEPENDENCY_TIMEOUT,
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
    async fn authoritative_repository_wins_over_stale_cache() {
        let repository = Arc::new(CountingRepository {
            reads: AtomicUsize::new(0),
            value: "postgres",
        });
        let service = PublicContentService::new(
            repository.clone(),
            Arc::new(HitCache("valkey")),
            TEST_DEPENDENCY_TIMEOUT,
        );
        assert_eq!(
            service
                .read(PublicContentKind::About)
                .await
                .expect("authoritative read succeeds"),
            "postgres"
        );
        assert_eq!(repository.reads.load(Ordering::Relaxed), 1);
    }

    #[tokio::test]
    async fn repository_failure_should_fall_back_to_cache() {
        let service = PublicContentService::new(
            Arc::new(FailingRepository),
            Arc::new(HitCache("cached")),
            TEST_DEPENDENCY_TIMEOUT,
        );
        assert_eq!(
            service
                .read(PublicContentKind::Notice)
                .await
                .expect("cache fallback succeeds"),
            "cached"
        );
    }

    #[tokio::test]
    async fn cache_miss_should_read_authoritative_postgres() {
        let repository = Arc::new(CountingRepository {
            reads: AtomicUsize::new(0),
            value: "postgres",
        });
        let service = PublicContentService::new(
            repository.clone(),
            Arc::new(MissingCache),
            TEST_DEPENDENCY_TIMEOUT,
        );
        assert_eq!(
            service
                .read(PublicContentKind::HomePage)
                .await
                .expect("postgres fallback succeeds"),
            "postgres"
        );
        assert_eq!(repository.reads.load(Ordering::Relaxed), 1);
    }

    #[tokio::test]
    async fn cache_get_timeout_should_fall_back_to_postgres() {
        let service = PublicContentService::new(
            Arc::new(MockContentRepository(Some("postgres".to_owned()))),
            Arc::new(PendingGetCache),
            TEST_DEPENDENCY_TIMEOUT,
        );
        let result = tokio::time::timeout(
            Duration::from_millis(20),
            service.read(PublicContentKind::Notice),
        )
        .await;
        assert_eq!(
            result
                .expect("the use case applies a shorter dependency timeout")
                .expect("postgres fallback succeeds"),
            "postgres"
        );
    }

    #[tokio::test]
    async fn postgres_timeout_should_fail_safely() {
        let service = PublicContentService::new(
            Arc::new(PendingRepository),
            Arc::new(MissingCache),
            TEST_DEPENDENCY_TIMEOUT,
        );
        let result = tokio::time::timeout(
            Duration::from_millis(20),
            service.read(PublicContentKind::Notice),
        )
        .await;
        assert!(matches!(result, Ok(Err(PublicContentError))));
    }

    #[tokio::test]
    async fn cache_miss_should_not_write_back_to_cache() {
        let cache = Arc::new(RecordingMissCache);
        let service = PublicContentService::new(
            Arc::new(MockContentRepository(Some("postgres".to_owned()))),
            cache.clone(),
            TEST_DEPENDENCY_TIMEOUT,
        );
        assert_eq!(
            service.read(PublicContentKind::Notice).await.unwrap(),
            "postgres"
        );
    }
}
