use std::{collections::HashMap, env, sync::Arc, time::Duration};

use axum::{
    body::{Body, to_bytes},
    http::{Request, StatusCode, header},
};
use lmm_api_rs::models::{ModelsHttpState, PgModelsService, models_router};
use serde_json::Value;
use sqlx::{PgPool, postgres::PgPoolOptions};
use tower::ServiceExt;

#[tokio::test]
#[ignore = "requires isolated PostgreSQL 18 and Valkey; run-real-integration-gates.sh models"]
async fn models_route_uses_authoritative_postgres_and_tolerates_valkey_failure() {
    let database_url = env::var("LMM_MODELS_TEST_DATABASE_URL")
        .expect("LMM_MODELS_TEST_DATABASE_URL is required for the isolated PostgreSQL 18 harness");
    let valkey_url = env::var("LMM_MODELS_TEST_VALKEY_URL")
        .expect("LMM_MODELS_TEST_VALKEY_URL is required for the isolated Valkey harness");
    let pool = PgPoolOptions::new()
        .max_connections(3)
        .acquire_timeout(Duration::from_secs(3))
        .connect(&database_url)
        .await
        .expect("test PostgreSQL must be reachable");
    reset_schema(&pool).await;
    seed(&pool).await;

    let valkey = redis::Client::open(valkey_url).expect("Valkey URL");
    let mut connection = valkey
        .get_multiplexed_async_connection()
        .await
        .expect("test Valkey must be reachable");
    redis::cmd("FLUSHDB")
        .query_async::<()>(&mut connection)
        .await
        .expect("isolated Valkey reset");

    let router = models_router(ModelsHttpState::new(
        Arc::new(PgModelsService::with_valkey(
            pool.clone(),
            valkey.clone(),
            "models-oracle-crypto-secret",
            Duration::from_secs(60),
        )),
        "v0.0.0",
    ));
    let success = call(&router, "Bearer sk-oraclemodelstoken", "127.0.0.1").await;
    assert_eq!(success.status(), StatusCode::OK);
    assert_eq!(
        json_body(success).await["data"],
        serde_json::json!([
            {"id":"gpt-4o","object":"model","created":1626777600,"owned_by":"openai","supported_endpoint_types":["openai"]},
            {"id":"text-embedding-3-small","object":"model","created":1626777600,"owned_by":"openai","supported_endpoint_types":["openai"]}
        ])
    );
    let token_key = token_cache_key("oraclemodelstoken");
    let cached_fields: Vec<String> = redis::cmd("HKEYS")
        .arg(&token_key)
        .query_async(&mut connection)
        .await
        .expect("token cache populated on PostgreSQL miss");
    assert!(cached_fields.contains(&"Key".to_owned()));
    let token_hash: HashMap<String, String> = redis::cmd("HGETALL")
        .arg(&token_key)
        .query_async(&mut connection)
        .await
        .expect("token cache hash");
    assert_eq!(
        token_hash,
        HashMap::from([
            ("Id".to_owned(), "73".to_owned()),
            ("UserId".to_owned(), "42".to_owned()),
            ("Key".to_owned(), String::new()),
            ("Status".to_owned(), "1".to_owned()),
            ("Name".to_owned(), String::new()),
            ("CreatedTime".to_owned(), "0".to_owned()),
            ("AccessedTime".to_owned(), "0".to_owned()),
            ("ExpiredTime".to_owned(), "-1".to_owned()),
            ("RemainQuota".to_owned(), "0".to_owned()),
            ("UnlimitedQuota".to_owned(), "true".to_owned()),
            ("ModelLimitsEnabled".to_owned(), "false".to_owned()),
            ("ModelLimits".to_owned(), String::new()),
            ("AllowIps".to_owned(), String::new()),
            ("UsedQuota".to_owned(), "0".to_owned()),
            ("Group".to_owned(), String::new()),
            ("CrossGroupRetry".to_owned(), "false".to_owned()),
        ]),
        "cold PostgreSQL lookup must populate the legacy Token cache shape"
    );
    let token_ttl = redis::cmd("TTL")
        .arg(&token_key)
        .query_async::<i64>(&mut connection)
        .await
        .expect("token cache TTL");
    assert!(
        (1..=60).contains(&token_ttl),
        "legacy token hash must receive the configured 60 second TTL"
    );
    assert_eq!(
        redis::cmd("GET")
            .arg("auth:user:version:42")
            .query_async::<String>(&mut connection)
            .await
            .expect("auth version floor"),
        "1",
    );
    assert_eq!(
        redis::cmd("TTL")
            .arg("auth:user:version:42")
            .query_async::<i64>(&mut connection)
            .await
            .expect("auth version floor TTL"),
        -1,
    );
    let user_hash: HashMap<String, String> = redis::cmd("HGETALL")
        .arg("user:42")
        .query_async(&mut connection)
        .await
        .expect("user cache hash");
    assert_eq!(
        user_hash,
        HashMap::from([
            ("Id".to_owned(), "42".to_owned()),
            ("Group".to_owned(), "default".to_owned()),
            ("Email".to_owned(), String::new()),
            ("Quota".to_owned(), "0".to_owned()),
            ("Status".to_owned(), "1".to_owned()),
            ("Role".to_owned(), "1".to_owned()),
            ("Username".to_owned(), "oracle-model-user".to_owned()),
            ("Setting".to_owned(), "{}".to_owned()),
            ("AuthVersion".to_owned(), "1".to_owned()),
            ("CacheSchema".to_owned(), "2".to_owned()),
        ]),
        "cold PostgreSQL lookup must populate the legacy UserBase cache shape"
    );
    let user_ttl = redis::cmd("TTL")
        .arg("user:42")
        .query_async::<i64>(&mut connection)
        .await
        .expect("user cache TTL");
    assert!(
        (1..=60).contains(&user_ttl),
        "legacy user hash must receive the configured 60 second TTL"
    );

    sqlx::query("UPDATE tokens SET model_limits_enabled = TRUE, model_limits = 'gpt-4o'")
        .execute(&pool)
        .await
        .expect("restrict token models");
    let hot = call(&router, "Bearer sk-oraclemodelstoken", "127.0.0.1").await;
    assert_eq!(
        json_body(hot).await["data"].as_array().map(Vec::len),
        Some(2),
        "hot legacy token hash remains authoritative until an invalidator removes it",
    );
    let hot_token_ttl = redis::cmd("TTL")
        .arg(&token_key)
        .query_async::<i64>(&mut connection)
        .await
        .expect("hot token cache TTL");
    assert!(
        (1..=token_ttl).contains(&hot_token_ttl),
        "a hot cache read must not rewrite or extend the legacy token TTL"
    );
    redis::cmd("DEL")
        .arg(&token_key)
        .query_async::<()>(&mut connection)
        .await
        .expect("invalidate legacy token cache after token mutation");
    let restricted = call(&router, "Bearer sk-oraclemodelstoken", "127.0.0.1").await;
    assert_eq!(
        json_body(restricted).await["data"].as_array().map(Vec::len),
        Some(1)
    );

    redis::cmd("SET")
        .arg("auth:user:version:42")
        .arg(2)
        .query_async::<()>(&mut connection)
        .await
        .expect("publish restrictive user version");
    assert_eq!(
        call(&router, "Bearer sk-oraclemodelstoken", "127.0.0.1")
            .await
            .status(),
        StatusCode::INTERNAL_SERVER_ERROR,
        "a newer auth version invalidates cached and database user snapshots fail closed",
    );
    redis::cmd("SET")
        .arg("auth:user:version:42")
        .arg(1)
        .query_async::<()>(&mut connection)
        .await
        .expect("restore user version");

    sqlx::query("UPDATE tokens SET allow_ips = '10.0.0.0/8'")
        .execute(&pool)
        .await
        .expect("restrict token IP");
    redis::cmd("DEL")
        .arg(&token_key)
        .query_async::<()>(&mut connection)
        .await
        .expect("invalidate token cache after IP restriction mutation");
    assert_eq!(
        call(&router, "Bearer sk-oraclemodelstoken", "192.0.2.1")
            .await
            .status(),
        StatusCode::FORBIDDEN
    );

    sqlx::query("UPDATE tokens SET allow_ips = ''")
        .execute(&pool)
        .await
        .expect("restore token IP");
    let outage_router = models_router(ModelsHttpState::new(
        Arc::new(PgModelsService::with_valkey(
            pool.clone(),
            redis::Client::open("redis://127.0.0.1:9/").expect("unreachable Valkey URL"),
            "models-oracle-crypto-secret",
            Duration::from_secs(60),
        )),
        "v0.0.0",
    ));
    assert_eq!(
        call(&outage_router, "Bearer sk-oraclemodelstoken", "127.0.0.1")
            .await
            .status(),
        StatusCode::OK,
        "Valkey outage must not override authoritative PostgreSQL"
    );

    sqlx::query("UPDATE users SET status = 2")
        .execute(&pool)
        .await
        .expect("ban user");
    assert_eq!(
        call(&outage_router, "Bearer sk-oraclemodelstoken", "127.0.0.1")
            .await
            .status(),
        StatusCode::FORBIDDEN
    );
}

async fn call(router: &axum::Router, token: &str, ip: &str) -> axum::response::Response {
    router
        .clone()
        .oneshot(
            Request::builder()
                .uri("/v1/models")
                .header(header::AUTHORIZATION, token)
                .header("x-real-ip", ip)
                .body(Body::empty())
                .expect("request"),
        )
        .await
        .expect("response")
}

async fn json_body(response: axum::response::Response) -> Value {
    serde_json::from_slice(
        &to_bytes(response.into_body(), usize::MAX)
            .await
            .expect("body"),
    )
    .expect("JSON response")
}

async fn reset_schema(pool: &PgPool) {
    for statement in [
        "DROP TABLE IF EXISTS options",
        "DROP TABLE IF EXISTS abilities",
        "DROP TABLE IF EXISTS channels",
        "DROP TABLE IF EXISTS tokens",
        "DROP TABLE IF EXISTS users",
        r#"CREATE TABLE users (
            id BIGINT PRIMARY KEY, username TEXT UNIQUE, password TEXT NOT NULL,
            role BIGINT DEFAULT 1, status INTEGER DEFAULT 1, email TEXT DEFAULT '',
            quota BIGINT DEFAULT 0, "group" VARCHAR(64) DEFAULT 'default',
            setting TEXT, auth_version BIGINT DEFAULT 1, deleted_at TIMESTAMPTZ
        )"#,
        "CREATE TABLE options (key TEXT PRIMARY KEY, value TEXT)",
        r#"CREATE TABLE tokens (
            id BIGINT PRIMARY KEY, user_id BIGINT NOT NULL, key VARCHAR(128) UNIQUE,
            name TEXT DEFAULT '', created_time BIGINT DEFAULT 0, accessed_time BIGINT DEFAULT 0,
            status INTEGER DEFAULT 1, expired_time BIGINT DEFAULT -1,
            remain_quota BIGINT DEFAULT 0, unlimited_quota BOOLEAN DEFAULT FALSE,
            model_limits_enabled BOOLEAN DEFAULT FALSE, model_limits TEXT,
            allow_ips TEXT DEFAULT '', used_quota BIGINT DEFAULT 0, "group" TEXT DEFAULT '',
            cross_group_retry BOOLEAN DEFAULT FALSE, deleted_at TIMESTAMPTZ
        )"#,
        r#"CREATE TABLE channels (
            id BIGINT PRIMARY KEY, type INTEGER DEFAULT 0, status INTEGER DEFAULT 1
        )"#,
        r#"CREATE TABLE abilities (
            "group" VARCHAR(64), model VARCHAR(255), channel_id BIGINT,
            enabled BOOLEAN, priority INTEGER DEFAULT 0, weight INTEGER DEFAULT 0,
            PRIMARY KEY ("group", model, channel_id)
        )"#,
    ] {
        sqlx::query(statement)
            .execute(pool)
            .await
            .expect("isolated models schema statement");
    }
}

async fn seed(pool: &PgPool) {
    sqlx::query("INSERT INTO options (key, value) VALUES ('ModelRatio', '{\"gpt-4o\":1,\"text-embedding-3-small\":1}')")
        .execute(pool)
        .await
        .expect("billing option fixture");
    sqlx::query("INSERT INTO users (id, username, password, status, \"group\", setting) VALUES (42, 'oracle-model-user', 'unused', 1, 'default', '{}')")
        .execute(pool)
        .await
        .expect("user fixture");
    sqlx::query("INSERT INTO tokens (id, user_id, key, status, expired_time, unlimited_quota, model_limits_enabled, model_limits, allow_ips, \"group\") VALUES (73, 42, 'oraclemodelstoken', 1, -1, TRUE, FALSE, '', '', '')")
        .execute(pool)
        .await
        .expect("token fixture");
    sqlx::query("INSERT INTO channels (id, type, status) VALUES (101, 1, 1)")
        .execute(pool)
        .await
        .expect("channel fixture");
    sqlx::query("INSERT INTO abilities (\"group\", model, channel_id, enabled, priority, weight) VALUES ('default', 'gpt-4o', 101, TRUE, 20, 10), ('default', 'text-embedding-3-small', 101, TRUE, 10, 10), ('default', 'oracle-unpriced', 101, TRUE, 0, 10)")
        .execute(pool)
        .await
        .expect("ability fixtures");
}

fn token_cache_key(token: &str) -> String {
    use hmac::{Hmac, Mac};
    use sha2::Sha256;
    let mut mac = Hmac::<Sha256>::new_from_slice(b"models-oracle-crypto-secret").expect("HMAC key");
    mac.update(token.as_bytes());
    let hash = mac
        .finalize()
        .into_bytes()
        .iter()
        .map(|byte| format!("{byte:02x}"))
        .collect::<String>();
    format!("token:{hash}")
}
