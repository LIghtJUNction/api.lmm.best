use async_trait::async_trait;
use lmm_application::{ProbeError, ReadinessProbe, ValkeyReadinessPolicy, check_readiness};
use std::sync::{
    Arc, Mutex,
    atomic::{AtomicBool, Ordering},
};

struct RecordingProbe {
    failures: &'static [&'static str],
    calls: Arc<Mutex<Vec<&'static str>>>,
}

impl RecordingProbe {
    fn result(&self, dependency: &'static str) -> Result<(), ProbeError> {
        self.calls
            .lock()
            .expect("call recording lock")
            .push(dependency);
        if self.failures.contains(&dependency) {
            Err(ProbeError { dependency })
        } else {
            Ok(())
        }
    }
}

#[async_trait]
impl ReadinessProbe for RecordingProbe {
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

#[tokio::test]
async fn a_candidate_slot_requires_postgres_schema_and_fail_closed_valkey() {
    let calls = Arc::new(Mutex::new(Vec::new()));
    let probe = RecordingProbe {
        failures: &["postgres", "valkey"],
        calls: Arc::clone(&calls),
    };

    let report = check_readiness(&probe, ValkeyReadinessPolicy::RequiredForRateLimiting).await;

    assert_eq!(
        report
            .required_failures
            .iter()
            .map(|failure| failure.dependency)
            .collect::<Vec<_>>(),
        vec!["postgres", "valkey"]
    );
    let calls = calls.lock().expect("call recording lock");
    assert!(calls.contains(&"postgres"));
    assert!(calls.contains(&"valkey"));
    assert!(calls.contains(&"schema"));
}

#[tokio::test]
async fn valkey_is_degraded_only_when_its_fail_closed_features_are_disabled() {
    let calls = Arc::new(Mutex::new(Vec::new()));
    let probe = RecordingProbe {
        failures: &["valkey"],
        calls,
    };

    let report = check_readiness(&probe, ValkeyReadinessPolicy::OptionalCacheOnly).await;

    assert!(report.required_failures.is_empty());
    assert_eq!(report.degraded[0].dependency, "valkey");
}

struct RecoveringProbe {
    postgres_available: AtomicBool,
    valkey_available: AtomicBool,
    schema_available: AtomicBool,
}

impl RecoveringProbe {
    fn unavailable() -> Self {
        Self {
            postgres_available: AtomicBool::new(false),
            valkey_available: AtomicBool::new(false),
            schema_available: AtomicBool::new(false),
        }
    }

    fn set_healthy(&self) {
        self.postgres_available.store(true, Ordering::Release);
        self.valkey_available.store(true, Ordering::Release);
        self.schema_available.store(true, Ordering::Release);
    }

    fn result(available: &AtomicBool, dependency: &'static str) -> Result<(), ProbeError> {
        available
            .load(Ordering::Acquire)
            .then_some(())
            .ok_or(ProbeError { dependency })
    }
}

#[async_trait]
impl ReadinessProbe for RecoveringProbe {
    async fn postgres(&self) -> Result<(), ProbeError> {
        Self::result(&self.postgres_available, "postgres")
    }

    async fn valkey(&self) -> Result<(), ProbeError> {
        Self::result(&self.valkey_available, "valkey")
    }

    async fn schema_compatible(&self) -> Result<(), ProbeError> {
        Self::result(&self.schema_available, "schema")
    }
}

#[tokio::test]
async fn a_slot_becomes_eligible_only_after_postgres_valkey_and_schema_recover() {
    let probe = RecoveringProbe::unavailable();

    let unavailable = check_readiness(&probe, ValkeyReadinessPolicy::RequiredForRateLimiting).await;
    assert_eq!(unavailable.required_failures.len(), 3);

    probe.set_healthy();
    let recovered = check_readiness(&probe, ValkeyReadinessPolicy::RequiredForRateLimiting).await;
    assert!(recovered.required_failures.is_empty());
    assert!(recovered.degraded.is_empty());
}
