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
