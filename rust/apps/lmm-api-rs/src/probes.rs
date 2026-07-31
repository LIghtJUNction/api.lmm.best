use async_trait::async_trait;
use lmm_application::{ProbeError, ReadinessProbe};
use sqlx::{PgPool, Row};
use std::time::Duration;
pub struct InfrastructureProbe {
    pg: PgPool,
    valkey: redis::Client,
    schema_contract: i64,
    timeout: Duration,
}
impl InfrastructureProbe {
    pub fn new(pg: PgPool, valkey: redis::Client, schema_contract: i64, timeout: Duration) -> Self {
        Self {
            pg,
            valkey,
            schema_contract,
            timeout,
        }
    }
}
#[async_trait]
impl ReadinessProbe for InfrastructureProbe {
    async fn postgres(&self) -> Result<(), ProbeError> {
        tokio::time::timeout(self.timeout, sqlx::query("SELECT 1").execute(&self.pg))
            .await
            .map_err(|_| failed("postgres"))?
            .map_err(|_| failed("postgres"))?;
        Ok(())
    }
    async fn valkey(&self) -> Result<(), ProbeError> {
        tokio::time::timeout(self.timeout, async {
            let mut connection = self.valkey.get_multiplexed_async_connection().await?;
            redis::cmd("PING")
                .query_async::<String>(&mut connection)
                .await
        })
        .await
        .map_err(|_| failed("valkey"))?
        .map_err(|_| failed("valkey"))?;
        Ok(())
    }
    async fn schema_compatible(&self) -> Result<(), ProbeError> {
        let row = tokio::time::timeout(self.timeout, sqlx::query("SELECT min_reader_version, max_reader_version FROM lmm_schema_contract WHERE singleton = TRUE").fetch_one(&self.pg)).await.map_err(|_| failed("schema"))?.map_err(|_| failed("schema"))?;
        let min: i64 = row
            .try_get("min_reader_version")
            .map_err(|_| failed("schema"))?;
        let max: i64 = row
            .try_get("max_reader_version")
            .map_err(|_| failed("schema"))?;
        if (min..=max).contains(&self.schema_contract) {
            Ok(())
        } else {
            Err(failed("schema"))
        }
    }
}
fn failed(dependency: &'static str) -> ProbeError {
    ProbeError { dependency }
}
