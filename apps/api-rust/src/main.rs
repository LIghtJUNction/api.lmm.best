mod config;
mod http;
mod probes;
mod public_content;
mod rate_limit;
mod test_instance;
use config::Config;
use http::{ApiTokenMount, AppState, RuntimeState};
use lmm_api_rs::{
    auth::{
        AuthConfig, AuthHttpState, DashboardAuth, PgValkeyDashboardAuth,
        anonymous_registration_surface,
    },
    migration_routes::{
        admin_catalog::{
            AdminCatalogState, DashboardAdminCatalogAuthorizer, PgCatalogProvider,
            router as admin_catalog_router,
        },
        api_token::{ApiTokenHttpState, PgValkeyApiTokenService},
        billing_subscriptions::{
            BillingSubscriptionsState, router as billing_subscriptions_router,
            spawn_maintenance as spawn_subscription_maintenance,
        },
        control_public::{
            ControlPublicHttpState, PgControlPublicRepository, ReqwestUptimeKumaClient,
            control_public_router,
        },
        identity_admin::{IdentityAdminState, router as identity_admin_router},
        identity_federation::{
            DashboardFederationIdentity, DisabledEmailCodeVerifier, FederationState,
            bindings_router as identity_federation_bindings_router,
        },
        identity_profile::{ProfileState, router as identity_profile_router},
        identity_security::{
            DashboardSecurityAuthorizer, IdentitySecurityState, PgValkeySecurityProvider,
            passkey_read_router, registration_router, sessions_read_router,
        },
        missing_identity_catalog::{
            IdentityCatalogState, protected_read_router as identity_catalog_protected_read_router,
            public_router as identity_catalog_public_router,
            token_router as identity_catalog_token_router,
        },
        missing_identity_checkin_aff::{
            IdentityCheckinAffState, read_router as identity_checkin_read_router,
        },
        missing_identity_topup::{
            IdentityTopupState, admin_read_router as identity_topup_admin_read_router,
            read_router as identity_topup_read_router,
        },
        missing_relay_models_billing::{
            ModelLookupState, PgStaticModelLookup, model_lookup_router,
        },
        observability::{
            DashboardObservabilityAuthorizer, ObservabilityState, PgObservabilityStore,
            PgReadOnlyObservabilityTokenAuthorizer, ValkeyObservabilityMetrics,
            observability_read_router,
        },
        open_source_bounties::{OpenSourceBountyState, router as open_source_bounty_router},
    },
    models::{ModelsHttpState, ModelsListenerMode, PgModelsService},
    status::{PgStatusRepository, StatusHttpState, StatusRepository},
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
    // Local acceptance is an explicit loopback-only development policy. It
    // must never alter the isolated frozen listener's historical contract.
    let local_acceptance = config.local_acceptance && !config.test_instance;
    if config.trusted_proxies.uses_compatibility_defaults() {
        tracing::warn!(
            "TRUSTED_PROXIES is unset or blank; trusting loopback, RFC 1918, and IPv6 ULA proxy addresses for compatibility"
        );
    }
    let version = std::env::var("VERSION").unwrap_or_else(|_| "v0.0.0".to_owned());
    let start_time = i64::try_from(SystemTime::now().duration_since(UNIX_EPOCH)?.as_secs())?;
    let pg = PgPoolOptions::new().connect_lazy(&config.database_url)?;
    let status_repository =
        Arc::new(PgStatusRepository::new(pg.clone()).with_local_acceptance(local_acceptance));
    let turnstile = config
        .auth_turnstile
        .resolve_public(&status_repository.snapshot().await?.options)?;
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
    let auth: Arc<dyn DashboardAuth> = Arc::new(
        PgValkeyDashboardAuth::new(
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
        )?
        .with_local_acceptance(local_acceptance),
    );
    let auth_http = AuthHttpState::new(Arc::clone(&auth), config.auth_cookie_secure)
        .with_password_login_enabled(config.auth_password_login_enabled)
        .with_trusted_origins(&config.auth_trusted_origins)
        .with_anonymous_body_limit_bytes(config.auth_anonymous_body_limit_bytes)
        .with_turnstile_check(turnstile.enabled, config.auth_turnstile.secret_key())
        .with_version(version.clone());
    let models_service = Arc::new(
        PgModelsService::with_valkey(
            pg.clone(),
            valkey.clone(),
            config.crypto_secret.expose_secret(),
            config.models_cache_ttl,
        )
        .with_local_acceptance(local_acceptance),
    );
    let models_http = ModelsHttpState::new(
        Arc::clone(&models_service) as Arc<dyn lmm_api_rs::models::ModelsService>,
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
    if local_acceptance {
        tracing::warn!(
            "LMM_LOCAL_ACCEPTANCE enabled; developer access granted without paid activation"
        );
    }
    let (shutdown_tx, shutdown_rx) = watch::channel(false);
    let app_state = AppState {
        readiness: Arc::new(probe),
        // Dashboard sessions always depend on Valkey even when the
        // separate global API limiter is disabled.
        valkey_readiness_policy: ValkeyReadinessPolicy::RequiredForRateLimiting,
        global_api_rate_limiter: Arc::clone(&global_api_rate_limiter),
        public_content: Arc::new(lmm_application::PublicContentService::new(
            Arc::new(PgPublicContentRepository::new(pg.clone())),
            Arc::new(ValkeyPublicContentCache::new(valkey.clone())),
            config.dependency_timeout,
        )),
        status: StatusHttpState::new(status_repository, version, start_time)
            .with_dashboard_auth(Arc::clone(&auth))
            .with_turnstile_config(turnstile.enabled, turnstile.site_key),
        slot: config.slot.clone(),
        runtime: runtime.clone(),
        trusted_proxies: config.trusted_proxies.clone(),
    };
    let router = if config.test_instance {
        // Only the explicitly isolated historical listener may use the frozen
        // Go 5418ce6 model/API-token contract.
        let models_http = models_http.with_listener_mode(ModelsListenerMode::FrozenGo5418ce6);
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
            Some(api_token.with_historical_frozen_go_parity()),
            Some(candidates),
        )
    } else {
        // C1 exercises the current-Go API-token policy on the normal Rust
        // listener. This does not transfer production ownership from Go.
        let models_http = models_http.with_listener_mode(ModelsListenerMode::CurrentTrustPolicy);
        let identity_profile = http::api_global_rate_limited_surface(
            &app_state,
            identity_profile_router(
                ProfileState::new(pg.clone(), valkey.clone())
                    .with_dashboard_auth(Arc::clone(&auth)),
            ),
        );
        let identity_catalog = http::api_global_rate_limited_surface(
            &app_state,
            identity_catalog_public_router(IdentityCatalogState::new(
                pg.clone(),
                Arc::clone(&auth),
            )),
        );
        let identity_catalog_protected = http::api_global_rate_limited_surface(
            &app_state,
            identity_catalog_protected_read_router(IdentityCatalogState::new(
                pg.clone(),
                Arc::clone(&auth),
            )),
        );
        let identity_catalog_token = http::api_global_rate_limited_surface(
            &app_state,
            identity_catalog_token_router(IdentityCatalogState::new(pg.clone(), Arc::clone(&auth))),
        );
        let catalog_http = reqwest::Client::builder()
            .timeout(config.dependency_timeout)
            .build()
            .map_err(|_| io::Error::other("failed to initialize catalog HTTP client"))?;
        let admin_catalog = http::api_global_rate_limited_surface(
            &app_state,
            admin_catalog_router(AdminCatalogState::new(
                Arc::new(
                    PgCatalogProvider::with_official_upstream(pg.clone(), catalog_http)
                        .map_err(|_| io::Error::other("failed to initialize catalog provider"))?,
                ),
                Arc::new(DashboardAdminCatalogAuthorizer::new(Arc::clone(&auth))),
            )),
        );
        // Administrator user-management routes use the same PostgreSQL and
        // Valkey-backed auth/session fences as the isolated candidate surface.
        // Keep them a Rust candidate while Go retains production ownership.
        let identity_admin = http::api_global_rate_limited_surface(
            &app_state,
            identity_admin_router(IdentityAdminState::new(
                pg.clone(),
                valkey.clone(),
                Arc::clone(&auth),
            )),
        );
        let identity_topup = http::api_global_rate_limited_surface(
            &app_state,
            identity_topup_read_router(IdentityTopupState::new(pg.clone(), Arc::clone(&auth))),
        );
        let identity_topup_admin = http::api_global_rate_limited_surface(
            &app_state,
            identity_topup_admin_read_router(IdentityTopupState::new(
                pg.clone(),
                Arc::clone(&auth),
            )),
        );
        let identity_checkin = http::api_global_rate_limited_surface(
            &app_state,
            identity_checkin_read_router(IdentityCheckinAffState::new(
                pg.clone(),
                Arc::clone(&auth),
            )),
        );
        let identity_sessions = http::api_global_rate_limited_surface(
            &app_state,
            sessions_read_router(IdentitySecurityState::new(
                Arc::new(PgValkeySecurityProvider::new(pg.clone(), valkey.clone())),
                Arc::new(DashboardSecurityAuthorizer::new(Arc::clone(&auth))),
            )),
        );
        let identity_passkey = http::api_global_rate_limited_surface(
            &app_state,
            passkey_read_router(IdentitySecurityState::new(
                Arc::new(PgValkeySecurityProvider::new(pg.clone(), valkey.clone())),
                Arc::new(DashboardSecurityAuthorizer::new(Arc::clone(&auth))),
            )),
        );
        let federation_identity = Arc::new(
            DashboardFederationIdentity::new(
                Arc::clone(&auth),
                pg.clone(),
                &config.auth_session_secret,
                Arc::new(DisabledEmailCodeVerifier),
            )
            .map_err(|_| io::Error::other("failed to initialize federation identity"))?,
        );
        let identity_federation_bindings = http::api_global_rate_limited_surface(
            &app_state,
            identity_federation_bindings_router(FederationState::new(
                pg.clone(),
                federation_identity,
                config.auth_session_secret.expose_secret(),
            )),
        );
        // The helper owns the exact anonymous mount: .route("/api/user/register", post(register)).
        // Keep this evidence beside the normal-listener wiring so the route
        // ledger cannot mistake the frozen security candidates for ownership.
        let registration = http::api_global_rate_limited_surface(
            &app_state,
            anonymous_registration_surface(
                auth_http.clone(),
                registration_router(IdentitySecurityState::new(
                    Arc::new(PgValkeySecurityProvider::new(pg.clone(), valkey.clone())),
                    Arc::new(DashboardSecurityAuthorizer::new(Arc::clone(&auth))),
                )),
            ),
        );
        // Go mounts the subscription groups below the API router's
        // GlobalAPIRateLimit middleware. Keep the Rust candidate behind the
        // same client-keyed boundary before it is ever considered for a
        // production ownership transfer.
        let billing_subscriptions = http::api_global_rate_limited_surface(
            &app_state,
            billing_subscriptions_router(BillingSubscriptionsState::new(
                pg.clone(),
                Some(valkey.clone()),
                Arc::clone(&auth),
            )),
        );
        let _subscription_maintenance =
            spawn_subscription_maintenance(pg.clone(), Some(valkey.clone()));
        let observability = http::api_global_rate_limited_surface(
            &app_state,
            observability_read_router(ObservabilityState::new(
                Arc::new(PgObservabilityStore::postgres_read_only(
                    pg.clone(),
                    Arc::new(ValkeyObservabilityMetrics::new(valkey.clone())),
                )),
                Arc::new(DashboardObservabilityAuthorizer::new(
                    Arc::clone(&auth),
                    Arc::new(PgReadOnlyObservabilityTokenAuthorizer::new(pg.clone())),
                )),
            )),
        );
        let open_source_bounties =
            open_source_bounty_router(OpenSourceBountyState::new(pg.clone(), Arc::clone(&auth)));
        // The single-model GET is a read-only static catalogue lookup. Keep
        // it separate from provider relay methods, and apply the current Go
        // trust gate before exposing whether a model exists.
        let model_lookup = model_lookup_router(ModelLookupState::new(
            Arc::new(PgStaticModelLookup::with_current_policy(
                pg.clone(),
                local_acceptance,
            )),
            app_state.status.version().to_owned(),
        ));
        let control_public = if local_acceptance {
            // Local acceptance must never contact an operator-configured
            // uptime service; the test adapter fails closed instead.
            test_instance::safe_control_public_surface(pg.clone())
        } else {
            let uptime_kuma = ReqwestUptimeKumaClient::new()
                .map_err(|_| io::Error::other("failed to initialize uptime status client"))?;
            control_public_router(ControlPublicHttpState::new(
                Arc::new(PgControlPublicRepository::new(pg.clone())),
                Arc::new(uptime_kuma),
            ))
        };
        let control_public = http::api_global_rate_limited_surface(&app_state, control_public);
        let mut extra_surface = identity_profile
            .merge(identity_catalog)
            .merge(identity_catalog_protected)
            .merge(identity_catalog_token)
            .merge(admin_catalog)
            .merge(identity_admin)
            .merge(identity_topup)
            .merge(identity_topup_admin)
            .merge(identity_checkin)
            .merge(identity_sessions)
            .merge(identity_passkey)
            .merge(identity_federation_bindings)
            .merge(registration)
            .merge(billing_subscriptions)
            .merge(observability)
            .merge(open_source_bounties)
            .merge(model_lookup)
            .merge(control_public);
        if local_acceptance {
            extra_surface = extra_surface.merge(test_instance::safe_system_config_surface(
                pg.clone(),
                valkey.clone(),
                Arc::clone(&auth),
            ));
        }
        http::router_with_api_token_and_extra(
            app_state,
            auth_http,
            models_http,
            Some(api_token.with_current_dashboard_discovery_policy(
                Arc::clone(&models_service) as Arc<dyn lmm_api_rs::models::ModelsService>
            )),
            Some(extra_surface),
        )
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
