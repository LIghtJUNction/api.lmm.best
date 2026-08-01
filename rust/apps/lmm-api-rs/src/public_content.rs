use async_trait::async_trait;
use lmm_application::{
    PublicContentCache, PublicContentCacheError, PublicContentError, PublicContentRepository,
};
use lmm_domain::PublicContentKind;
use redis::AsyncCommands;
use sqlx::PgPool;
use std::time::Duration;

pub struct PgPublicContentRepository {
    pg: PgPool,
}

impl PgPublicContentRepository {
    pub fn new(pg: PgPool) -> Self {
        Self { pg }
    }
}

#[async_trait]
impl PublicContentRepository for PgPublicContentRepository {
    async fn get(&self, kind: PublicContentKind) -> Result<Option<String>, PublicContentError> {
        let key = match kind {
            PublicContentKind::Notice => "Notice",
            PublicContentKind::About => "About",
            PublicContentKind::HomePage => "HomePageContent",
        };
        sqlx::query_scalar::<_, Option<String>>("SELECT value FROM options WHERE key = $1")
            .bind(key)
            .fetch_optional(&self.pg)
            .await
            .map(|value| value.flatten())
            .map_err(|_| PublicContentError)
    }
}

pub struct ValkeyPublicContentCache {
    client: redis::Client,
    ttl: Duration,
}

impl ValkeyPublicContentCache {
    pub fn new(client: redis::Client, ttl: Duration) -> Self {
        Self { client, ttl }
    }
}

#[async_trait]
impl PublicContentCache for ValkeyPublicContentCache {
    async fn get(
        &self,
        kind: PublicContentKind,
    ) -> Result<Option<String>, PublicContentCacheError> {
        let mut connection = self
            .client
            .get_multiplexed_async_connection()
            .await
            .map_err(|_| PublicContentCacheError)?;
        connection
            .get(cache_key(kind))
            .await
            .map_err(|_| PublicContentCacheError)
    }

    async fn put(
        &self,
        kind: PublicContentKind,
        value: &str,
    ) -> Result<(), PublicContentCacheError> {
        let mut connection = self
            .client
            .get_multiplexed_async_connection()
            .await
            .map_err(|_| PublicContentCacheError)?;
        connection
            .set_ex(cache_key(kind), value, self.ttl.as_secs())
            .await
            .map_err(|_| PublicContentCacheError)
    }
}

fn cache_key(kind: PublicContentKind) -> &'static str {
    match kind {
        PublicContentKind::Notice => "lmm:public-content:v1:notice",
        PublicContentKind::About => "lmm:public-content:v1:about",
        PublicContentKind::HomePage => "lmm:public-content:v1:home-page",
    }
}
