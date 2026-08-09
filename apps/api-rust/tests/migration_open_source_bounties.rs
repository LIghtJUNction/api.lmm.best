use std::sync::Arc;

use axum::{body::Body, http::Request};
use lmm_api_rs::{
    auth::{AuthConfig, PgValkeyDashboardAuth},
    migration_routes::open_source_bounties::{OpenSourceBountyState, router},
};
use secrecy::SecretString;
use sqlx::postgres::PgPoolOptions;
use tower::ServiceExt;

#[tokio::test]
async fn public_bounty_router_exposes_only_the_read_method_until_writes_are_migrated() {
    let pg = PgPoolOptions::new()
        .connect_lazy("postgres://route-test:route-test@127.0.0.1:1/route_test")
        .expect("lazy PostgreSQL pool");
    let valkey = redis::Client::open("redis://127.0.0.1:1").expect("lazy Valkey client");
    let auth_config = AuthConfig {
        session_secret: SecretString::from(
            "open-source-bounty-route-test-secret-012345678901234567890123456789",
        ),
        ..AuthConfig::default()
    };
    let auth = Arc::new(
        PgValkeyDashboardAuth::new(pg.clone(), valkey, auth_config)
            .expect("route-test auth adapter"),
    );
    let app = router(OpenSourceBountyState::new(pg, auth));

    let response = app
        .oneshot(
            Request::builder()
                .method("POST")
                .uri("/api/open-source-bounties")
                .body(Body::empty())
                .expect("route request"),
        )
        .await
        .expect("route response");

    assert_eq!(
        response.status(),
        axum::http::StatusCode::METHOD_NOT_ALLOWED
    );
}

#[tokio::test]
async fn public_bounty_detail_rejects_an_invalid_project_id_without_database_access() {
    let pg = PgPoolOptions::new()
        .connect_lazy("postgres://route-test:route-test@127.0.0.1:1/route_test")
        .expect("lazy PostgreSQL pool");
    let valkey = redis::Client::open("redis://127.0.0.1:1").expect("lazy Valkey client");
    let auth_config = AuthConfig {
        session_secret: SecretString::from(
            "open-source-bounty-detail-route-test-secret-012345678901234567890123456789",
        ),
        ..AuthConfig::default()
    };
    let auth = Arc::new(
        PgValkeyDashboardAuth::new(pg.clone(), valkey, auth_config)
            .expect("route-test auth adapter"),
    );
    let app = router(OpenSourceBountyState::new(pg, auth));

    let response = app
        .oneshot(
            Request::get("/api/open-source-bounties/projects/not-an-id")
                .body(Body::empty())
                .expect("route request"),
        )
        .await
        .expect("route response");

    assert_eq!(response.status(), axum::http::StatusCode::OK);
    let body = axum::body::to_bytes(response.into_body(), usize::MAX)
        .await
        .expect("response body");
    assert_eq!(
        serde_json::from_slice::<serde_json::Value>(&body).expect("failure envelope"),
        serde_json::json!({
            "success": false,
            "code": "OPEN_SOURCE_BOUNTY_INVALID_ID",
            "message": "invalid open-source bounty identifier"
        })
    );
}

#[tokio::test]
async fn bounty_config_requires_dashboard_auth_before_options_lookup() {
    let pg = PgPoolOptions::new()
        .connect_lazy("postgres://route-test:route-test@127.0.0.1:1/route_test")
        .expect("lazy PostgreSQL pool");
    let valkey = redis::Client::open("redis://127.0.0.1:1").expect("lazy Valkey client");
    let auth_config = AuthConfig {
        session_secret: SecretString::from(
            "open-source-bounty-config-route-test-secret-012345678901234567890123456789",
        ),
        ..AuthConfig::default()
    };
    let auth = Arc::new(
        PgValkeyDashboardAuth::new(pg.clone(), valkey, auth_config)
            .expect("route-test auth adapter"),
    );
    let app = router(OpenSourceBountyState::new(pg, auth));

    let response = app
        .oneshot(
            Request::get("/api/open-source-bounties/config")
                .body(Body::empty())
                .expect("route request"),
        )
        .await
        .expect("route response");

    assert_eq!(response.status(), axum::http::StatusCode::UNAUTHORIZED);
    let body = axum::body::to_bytes(response.into_body(), usize::MAX)
        .await
        .expect("response body");
    assert_eq!(
        serde_json::from_slice::<serde_json::Value>(&body).expect("failure envelope")["code"],
        "AUTH_UNAUTHORIZED"
    );
}

#[tokio::test]
async fn owned_bounty_list_requires_dashboard_auth_before_project_lookup() {
    let pg = PgPoolOptions::new()
        .connect_lazy("postgres://route-test:route-test@127.0.0.1:1/route_test")
        .expect("lazy PostgreSQL pool");
    let valkey = redis::Client::open("redis://127.0.0.1:1").expect("lazy Valkey client");
    let auth_config = AuthConfig {
        session_secret: SecretString::from(
            "open-source-bounty-mine-route-test-secret-012345678901234567890123456789",
        ),
        ..AuthConfig::default()
    };
    let auth = Arc::new(
        PgValkeyDashboardAuth::new(pg.clone(), valkey, auth_config)
            .expect("route-test auth adapter"),
    );
    let app = router(OpenSourceBountyState::new(pg, auth));

    let response = app
        .oneshot(
            Request::get("/api/open-source-bounties/mine")
                .body(Body::empty())
                .expect("route request"),
        )
        .await
        .expect("route response");

    assert_eq!(response.status(), axum::http::StatusCode::UNAUTHORIZED);
    let body = axum::body::to_bytes(response.into_body(), usize::MAX)
        .await
        .expect("response body");
    assert_eq!(
        serde_json::from_slice::<serde_json::Value>(&body).expect("failure envelope")["code"],
        "AUTH_UNAUTHORIZED"
    );
}

#[tokio::test]
async fn accepted_bounty_list_requires_dashboard_auth_before_challenge_lookup() {
    let pg = PgPoolOptions::new()
        .connect_lazy("postgres://route-test:route-test@127.0.0.1:1/route_test")
        .expect("lazy PostgreSQL pool");
    let valkey = redis::Client::open("redis://127.0.0.1:1").expect("lazy Valkey client");
    let auth_config = AuthConfig {
        session_secret: SecretString::from(
            "open-source-bounty-accepted-route-test-secret-012345678901234567890123456789",
        ),
        ..AuthConfig::default()
    };
    let auth = Arc::new(
        PgValkeyDashboardAuth::new(pg.clone(), valkey, auth_config)
            .expect("route-test auth adapter"),
    );
    let app = router(OpenSourceBountyState::new(pg, auth));

    let response = app
        .oneshot(
            Request::get("/api/open-source-bounties/accepted")
                .body(Body::empty())
                .expect("route request"),
        )
        .await
        .expect("route response");

    assert_eq!(response.status(), axum::http::StatusCode::UNAUTHORIZED);
    let body = axum::body::to_bytes(response.into_body(), usize::MAX)
        .await
        .expect("response body");
    assert_eq!(
        serde_json::from_slice::<serde_json::Value>(&body).expect("failure envelope")["code"],
        "AUTH_UNAUTHORIZED"
    );
}
