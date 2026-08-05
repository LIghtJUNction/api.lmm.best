mod config;
mod http;
mod probes;
mod public_content;
mod rate_limit;
mod test_instance;
use config::Config;
use http::{ApiTokenMount, AppState, RuntimeState};
use lmm_api_rs::{
    auth::{AuthConfig, AuthHttpState, DashboardAuth, PgValkeyDashboardAuth},
    migration_routes::api_token::{ApiTokenHttpState, PgValkeyApiTokenService},
    models::{ModelsHttpState, PgModelsService},
    status::{PgStatusRepository, StatusHttpState},
};
use lmm_application::{GlobalApiRateLimiter, ValkeyReadinessPolicy};
use probes::InfrastructureProbe;
use public_content::{PgPublicContentRepository, ValkeyPublicContentCache};
use rate_limit::ValkeyGlobalApiRateLimiter;
use secrecy::ExposeSecret;
use sqlx::postgres::PgPoolOptions;
use std::{
    future::IntoFuture,
    io,
    sync::Arc,
    time::{SystemTime, UNIX_EPOCH},
};
use tokio::{net::TcpListener, sync::watch};
#[tokio::main]
async fn main() -> Result<(), Box<dyn std::error::Error>> {
    lmm_observability::init()?;
    let config = Config::from_env()?;
    if config.trusted_proxies.uses_compatibility_defaults() {
        tracing::warn!(
            "TRUSTED_PROXIES is unset or blank; trusting loopback, RFC 1918, and IPv6 ULA proxy addresses for compatibility"
        );
    }
    let version = std::env::var("VERSION").unwrap_or_else(|_| "v0.0.0".to_owned());
    let start_time = i64::try_from(SystemTime::now().duration_since(UNIX_EPOCH)?.as_secs())?;
    let pg = PgPoolOptions::new().connect_lazy(&config.database_url)?;
    let valkey = redis::Client::open(config.valkey_url.as_str())?;
    let probe = InfrastructureProbe::new(
        pg.clone(),
        valkey.clone(),
        config.schema_contract,
        config.dependency_timeout,
    );
    let global_api_rate_limiter: Arc<dyn GlobalApiRateLimiter> =
        Arc::new(ValkeyGlobalApiRateLimiter::new(
            valkey.clone(),
            config.valkey_readiness_policy,
            config.global_api_rate_limit,
            config.global_api_rate_limit_window,
            config.dependency_timeout,
        ));
    let auth: Arc<dyn DashboardAuth> = Arc::new(PgValkeyDashboardAuth::new(
        pg.clone(),
        valkey.clone(),
        AuthConfig {
            session_secret: config.auth_session_secret.clone(),
            active_session_limit: config.auth_active_session_limit,
            issuance_limit: config.auth_issuance_limit,
            issuance_window: config.auth_issuance_window,
            session_cache_ttl: config.auth_session_cache_ttl,
            dependency_timeout: config.dependency_timeout,
            critical_rate_limit_enabled: config.auth_critical_rate_limit_enabled,
            critical_rate_limit: config.auth_critical_rate_limit,
            critical_rate_limit_window: config.auth_critical_rate_limit_window,
        },
    )?);
    let auth_http = AuthHttpState::new(Arc::clone(&auth), config.auth_cookie_secure)
        .with_password_login_enabled(config.auth_password_login_enabled)
        .with_trusted_origins(&config.auth_trusted_origins)
        .with_anonymous_body_limit_bytes(config.auth_anonymous_body_limit_bytes)
        .with_version(version.clone());
    let models_http = ModelsHttpState::new(
        Arc::new(PgModelsService::with_valkey(
            pg.clone(),
            valkey.clone(),
            config.crypto_secret.expose_secret(),
            config.models_cache_ttl,
        )),
        version.clone(),
    );
    let api_token = ApiTokenMount::new(
        ApiTokenHttpState::new(Arc::new(
            PgValkeyApiTokenService::new(pg.clone(), valkey.clone())
                .with_cache_ttl(config.models_cache_ttl)
                .with_crypto_secret(config.crypto_secret.expose_secret()),
        )),
        Arc::clone(&auth),
        valkey.clone(),
        config.dependency_timeout,
        config.api_token_search_rate_limit_enabled,
        config.api_token_search_rate_limit,
        config.api_token_search_rate_limit_window,
    );
    let listener = TcpListener::bind(config.listen_addr).await?;
    let runtime = RuntimeState::default();
    tracing::info!(
        listen_addr = %config.listen_addr,
        slot = %config.slot,
        revision = option_env!("LMM_BUILD_REVISION").unwrap_or("unknown"),
        "Rust migration edge listening"
    );
    let (shutdown_tx, shutdown_rx) = watch::channel(false);
    let app_state = AppState {
        readiness: Arc::new(probe),
        // Dashboard sessions always depend on Valkey even when the
        // separate global API limiter is disabled.
        valkey_readiness_policy: ValkeyReadinessPolicy::RequiredForRateLimiting,
        global_api_rate_limiter: Arc::clone(&global_api_rate_limiter),
        public_content: Arc::new(lmm_application::PublicContentService::new(
            Arc::new(PgPublicContentRepository::new(pg.clone())),
            Arc::new(ValkeyPublicContentCache::new(
                valkey.clone(),
                config.public_content_cache_ttl,
            )),
            config.dependency_timeout,
        )),
        status: StatusHttpState::new(
            Arc::new(PgStatusRepository::new(pg.clone())),
            version,
            start_time,
        ),
        slot: config.slot.clone(),
        runtime: runtime.clone(),
        trusted_proxies: config.trusted_proxies.clone(),
    };
    let router = if config.test_instance {
        tracing::warn!(
            "test-instance candidate surface enabled; remote catalog and uptime clients are denied"
        );
        let candidates = http::migration_candidate_test_surface(
            &app_state,
            test_instance::safe_candidate_surface(pg.clone(), valkey.clone(), Arc::clone(&auth)),
        );
        http::router_with_api_token_and_extra(
            app_state,
            auth_http,
            models_http,
            Some(api_token),
            Some(candidates),
        )
    } else {
        // Production route ownership remains with Go. Only the explicit
        // test-instance candidate listener above may mount API-token routes.
        http::router_with_api_token(app_state, auth_http, models_http, None)
    };
    let server = axum::serve(
        listener,
        router.into_make_service_with_connect_info::<std::net::SocketAddr>(),
    )
    .with_graceful_shutdown(wait_for_shutdown(shutdown_rx))
    .into_future();
    tokio::pin!(server);
    tokio::select! {
        result = &mut server => result?,
        () = shutdown_signal() => {
            runtime.begin_drain();
            tracing::info!(
                slot = %config.slot,
                inflight = runtime.inflight(),
                drain_timeout_seconds = config.drain_timeout.as_secs(),
                "shutdown requested; readiness closed, listener closing and in-flight requests draining"
            );
            let _ = shutdown_tx.send(true);
            bounded_drain(config.drain_timeout, &mut server).await??;
            tracing::info!(slot = %config.slot, remaining_inflight = runtime.inflight(), "slot drain completed");
        }
    }
    Ok(())
}
async fn bounded_drain<F, T>(timeout: std::time::Duration, drain: F) -> io::Result<T>
where
    F: std::future::Future<Output = T>,
{
    tokio::time::timeout(timeout, drain)
        .await
        .map_err(|_| io::Error::new(io::ErrorKind::TimedOut, "in-flight request drain timed out"))
}
async fn wait_for_shutdown(mut receiver: watch::Receiver<bool>) {
    while !*receiver.borrow_and_update() {
        if receiver.changed().await.is_err() {
            break;
        }
    }
}
async fn shutdown_signal() {
    let terminate = async {
        #[cfg(unix)]
        if let Ok(mut signal) =
            tokio::signal::unix::signal(tokio::signal::unix::SignalKind::terminate())
        {
            signal.recv().await;
        }
    };
    tokio::select! { result = tokio::signal::ctrl_c() => { if let Err(error) = result { tracing::error!(%error, "failed to install ctrl-c handler"); } } () = terminate => {} }
}

#[cfg(test)]
mod tests {
    use super::bounded_drain;
    use std::{future, io, time::Duration};

    #[tokio::test]
    async fn bounded_drain_should_complete_finished_work() {
        let result = bounded_drain(Duration::from_secs(1), future::ready(7)).await;
        assert_eq!(result.expect("ready work completes"), 7);
    }

    #[tokio::test]
    async fn bounded_drain_should_time_out_stuck_work() {
        let result = bounded_drain(Duration::from_millis(1), future::pending::<()>()).await;
        assert_eq!(
            result.expect_err("stuck work times out").kind(),
            io::ErrorKind::TimedOut
        );
    }
}
