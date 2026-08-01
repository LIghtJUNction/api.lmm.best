use async_trait::async_trait;
use lmm_application::{GlobalApiRateLimiter, RateLimitError, RateLimitOutcome};
use std::time::Duration;

const FIXED_WINDOW_SCRIPT: &str = r#"
local count = redis.call('INCR', KEYS[1])
if count == 1 then
  redis.call('EXPIRE', KEYS[1], ARGV[2])
end
local ttl = redis.call('TTL', KEYS[1])
if ttl < 0 then
  redis.call('EXPIRE', KEYS[1], ARGV[2])
  ttl = redis.call('TTL', KEYS[1])
end
if count > tonumber(ARGV[1]) then
  return {0, count, ttl}
end
return {1, count, ttl}
"#;

pub struct ValkeyGlobalApiRateLimiter {
    client: redis::Client,
    enabled: bool,
    maximum: u64,
    window: Duration,
}

impl ValkeyGlobalApiRateLimiter {
    pub fn new(client: redis::Client, enabled: bool, maximum: u64, window: Duration) -> Self {
        Self {
            client,
            enabled,
            maximum,
            window,
        }
    }
}

#[async_trait]
impl GlobalApiRateLimiter for ValkeyGlobalApiRateLimiter {
    async fn check(&self, client_ip: &str) -> Result<RateLimitOutcome, RateLimitError> {
        if !self.enabled {
            return Ok(RateLimitOutcome::Allowed);
        }
        let mut connection = self
            .client
            .get_multiplexed_async_connection()
            .await
            .map_err(|_| RateLimitError)?;
        let key = format!("rateLimit:v2:ip:GA:{client_ip}");
        let reply = redis::Script::new(FIXED_WINDOW_SCRIPT)
            .key(key)
            .arg(self.maximum)
            .arg(self.window.as_secs())
            .invoke_async::<Vec<i64>>(&mut connection)
            .await
            .map_err(|_| RateLimitError)?;
        if reply.len() != 3 {
            return Err(RateLimitError);
        }
        if reply[0] == 1 {
            Ok(RateLimitOutcome::Allowed)
        } else {
            Ok(RateLimitOutcome::Rejected {
                retry_after_seconds: u64::try_from(reply[2]).ok().filter(|ttl| *ttl > 0),
            })
        }
    }
}
