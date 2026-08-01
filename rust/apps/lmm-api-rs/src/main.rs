mod config;
mod http;
mod probes;
mod public_content;
use config::Config;
use http::AppState;
use probes::InfrastructureProbe;
use public_content::{PgPublicContentRepository, ValkeyPublicContentCache};
use sqlx::postgres::PgPoolOptions;
use std::{future::IntoFuture, io, sync::Arc};
use tokio::{net::TcpListener, sync::watch};
#[tokio::main]
async fn main() -> Result<(), Box<dyn std::error::Error>> {
    lmm_observability::init()?;
    let config = Config::from_env()?;
    let pg = PgPoolOptions::new()
        .acquire_timeout(config.dependency_timeout)
        .connect_lazy(&config.database_url)?;
    let valkey = redis::Client::open(config.valkey_url.as_str())?;
    let probe = InfrastructureProbe::new(
        pg.clone(),
        valkey.clone(),
        config.schema_contract,
        config.dependency_timeout,
    );
    let listener = TcpListener::bind(config.listen_addr).await?;
    tracing::info!(listen_addr = %config.listen_addr, "Rust migration edge listening");
    let (shutdown_tx, shutdown_rx) = watch::channel(false);
    let server = axum::serve(
        listener,
        http::router(AppState {
            readiness: Arc::new(probe),
            public_content: Arc::new(lmm_application::PublicContentService::new(
                Arc::new(PgPublicContentRepository::new(pg)),
                Arc::new(ValkeyPublicContentCache::new(
                    valkey,
                    config.public_content_cache_ttl,
                )),
            )),
            slot: config.slot.clone(),
        }),
    )
    .with_graceful_shutdown(wait_for_shutdown(shutdown_rx))
    .into_future();
    tokio::pin!(server);
    tokio::select! {
        result = &mut server => result?,
        () = shutdown_signal() => {
            tracing::info!(drain_timeout_seconds = config.drain_timeout.as_secs(), "shutdown requested; listener closing and in-flight requests draining");
            let _ = shutdown_tx.send(true);
            bounded_drain(config.drain_timeout, &mut server).await??;
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
