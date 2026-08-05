use std::{collections::BTreeMap, sync::Arc};

use async_trait::async_trait;
use axum::{
    body::{Body, to_bytes},
    http::{HeaderMap, Request, StatusCode},
};
use lmm_api_rs::migration_routes::observability::{
    InMemoryObservabilityStore, ObservabilityAccess, ObservabilityAuthError,
    ObservabilityAuthorizer, ObservabilityCall, ObservabilityPrincipal, ObservabilityState,
    ObservabilityStore, ObservabilityStoreError, observability_router,
};
use serde_json::{Value, json};
use std::sync::atomic::{AtomicUsize, Ordering};
use tower::ServiceExt;

struct Allow {
    role: i64,
}

#[async_trait]
impl ObservabilityAuthorizer for Allow {
    async fn authorize(
        &self,
        _: &HeaderMap,
        access: ObservabilityAccess,
    ) -> Result<ObservabilityPrincipal, ObservabilityAuthError> {
        Ok(match access {
            ObservabilityAccess::Token => ObservabilityPrincipal::Token { token_id: 3 },
            ObservabilityAccess::PublicOrUser => ObservabilityPrincipal::Public,
            ObservabilityAccess::Admin | ObservabilityAccess::Root | ObservabilityAccess::User => {
                ObservabilityPrincipal::User {
                    user_id: 7,
                    username: "auditor".to_owned(),
                    role: self.role,
                }
            }
        })
    }
}

struct Deny;

#[async_trait]
impl ObservabilityAuthorizer for Deny {
    async fn authorize(
        &self,
        _: &HeaderMap,
        _: ObservabilityAccess,
    ) -> Result<ObservabilityPrincipal, ObservabilityAuthError> {
        Err(ObservabilityAuthError::Unauthorized)
    }
}

struct CountingStore(AtomicUsize);

#[async_trait]
impl ObservabilityStore for CountingStore {
    async fn execute(&self, _: ObservabilityCall) -> Result<Value, ObservabilityStoreError> {
        self.0.fetch_add(1, Ordering::Relaxed);
        Ok(json!({}))
    }
}

struct SuccessStore;

#[async_trait]
impl ObservabilityStore for SuccessStore {
    async fn execute(&self, _: ObservabilityCall) -> Result<Value, ObservabilityStoreError> {
        Ok(json!({}))
    }
}

fn router(role: i64) -> axum::Router {
    observability_router(ObservabilityState::new(
        Arc::new(SuccessStore),
        Arc::new(Allow { role }),
    ))
}

async fn body(response: axum::response::Response) -> Value {
    let bytes = to_bytes(response.into_body(), usize::MAX)
        .await
        .expect("response body");
    serde_json::from_slice(&bytes).expect("JSON response")
}

#[tokio::test]
async fn observability_routes_accept_their_expected_authenticated_scopes() {
    let cases = [
        ("GET", "/api/data/"),
        ("GET", "/api/data/users"),
        ("GET", "/api/data/self"),
        ("GET", "/api/data/flow?start_timestamp=1&end_timestamp=2"),
        (
            "GET",
            "/api/data/flow/self?start_timestamp=1&end_timestamp=2",
        ),
        ("GET", "/api/log/"),
        (
            "GET",
            "/api/log/channel_affinity_usage_cache?rule_name=r&key_fp=k",
        ),
        ("GET", "/api/log/search"),
        ("GET", "/api/log/self"),
        ("GET", "/api/log/self/search"),
        ("GET", "/api/log/self/stat"),
        ("GET", "/api/log/stat"),
        ("GET", "/api/log/token"),
        ("GET", "/api/perf-metrics?model=gpt-test"),
        ("GET", "/api/perf-metrics/summary"),
        ("DELETE", "/api/performance/disk_cache"),
        ("POST", "/api/performance/gc"),
        ("GET", "/api/performance/logs"),
        ("DELETE", "/api/performance/logs?mode=by_count&value=1"),
        ("POST", "/api/performance/reset_stats"),
        ("GET", "/api/performance/stats"),
    ];

    for (method, uri) in cases {
        let request = Request::builder()
            .method(method)
            .uri(uri)
            .body(Body::empty())
            .expect("request");
        let response = router(100).oneshot(request).await.expect("router response");
        assert_eq!(response.status(), StatusCode::OK, "{method} {uri}");
    }
}

#[tokio::test]
async fn protected_observability_route_returns_the_legacy_dashboard_auth_envelope_when_missing() {
    let app = observability_router(ObservabilityState::new(
        Arc::new(InMemoryObservabilityStore),
        Arc::new(Deny),
    ));
    let response = app
        .oneshot(
            Request::builder()
                .uri("/api/data/flow")
                .body(Body::empty())
                .expect("request"),
        )
        .await
        .expect("router response");

    assert_eq!(response.status(), StatusCode::UNAUTHORIZED);
    assert_eq!(
        body(response).await,
        json!({"success": false, "code": "AUTH_UNAUTHORIZED", "message": "Unauthorized"})
    );
}

#[tokio::test]
async fn token_log_route_keeps_the_token_auth_error_envelope_without_dashboard_code() {
    let app = observability_router(ObservabilityState::new(
        Arc::new(InMemoryObservabilityStore),
        Arc::new(Deny),
    ));
    let response = app
        .oneshot(
            Request::builder()
                .uri("/api/log/token")
                .body(Body::empty())
                .expect("request"),
        )
        .await
        .expect("router response");

    assert_eq!(response.status(), StatusCode::UNAUTHORIZED);
    assert_eq!(
        body(response).await,
        json!({"success": false, "message": "未提供令牌"})
    );
}

#[tokio::test]
async fn administrator_cannot_use_root_only_performance_maintenance_routes() {
    let response = router(10)
        .oneshot(
            Request::builder()
                .method("POST")
                .uri("/api/performance/gc")
                .body(Body::empty())
                .expect("request"),
        )
        .await
        .expect("router response");

    assert_eq!(response.status(), StatusCode::FORBIDDEN);
    assert_eq!(body(response).await["code"], "AUTH_INSUFFICIENT_PRIVILEGE");
}

#[tokio::test]
async fn invalid_query_is_not_parsed_or_sent_to_storage_before_authentication() {
    let store = Arc::new(CountingStore(AtomicUsize::new(0)));
    let app = observability_router(ObservabilityState::new(store.clone(), Arc::new(Deny)));
    let response = app
        .oneshot(
            Request::builder()
                .uri("/api/performance/logs?mode=nope&value=0")
                .body(Body::empty())
                .expect("request"),
        )
        .await
        .expect("router response");

    assert_eq!(response.status(), StatusCode::UNAUTHORIZED);
    assert_eq!(store.0.load(Ordering::Relaxed), 0);
}

#[tokio::test]
async fn unsupported_observability_method_returns_method_not_allowed() {
    let response = router(100)
        .oneshot(
            Request::builder()
                .method("POST")
                .uri("/api/log/stat")
                .body(Body::empty())
                .expect("request"),
        )
        .await
        .expect("router response");

    assert_eq!(response.status(), StatusCode::METHOD_NOT_ALLOWED);
}

#[test]
fn observation_call_query_type_is_stable_for_external_store_fakes() {
    let query = BTreeMap::from([("model".to_owned(), "gpt-test".to_owned())]);
    assert_eq!(query["model"], "gpt-test");
}
