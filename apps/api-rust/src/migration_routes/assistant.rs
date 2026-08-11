//! Current Go-compatible assistant routes.

use std::{
    collections::HashMap,
    sync::Arc,
    time::{Duration, SystemTime, UNIX_EPOCH},
};

use async_trait::async_trait;
use axum::{
    Json, Router,
    body::to_bytes,
    extract::{Path, RawQuery, State},
    http::{HeaderMap, StatusCode, header},
    response::{IntoResponse, Response},
    routing::{get, post},
};
use secrecy::SecretString;
use serde::{Deserialize, Serialize};
use serde_json::{Map, Value, json};
use sqlx::{PgPool, Row, postgres::PgRow};

use crate::auth::{
    AuthErrorKind, CriticalRateLimitOutcome, DashboardAuth, DashboardUserView, UserAuthPolicyError,
    enforce_user_auth_view, user_auth_message, user_auth_status,
};
use crate::{ClientIpKey, legacy_empty_response};

use super::billing_subscriptions::{enabled_plan_views, payment_compliance_confirmed};

const AUTH_VERSION: &str = "864b7076dbcd0a3c01b5520316720ebf";
const ADMIN_ROLE: i64 = 10;
const ASSISTANT_HANDOFF_SOURCE: &str = "handoff";
const ASSISTANT_HANDOFF_PENDING: &str = "pending";
const ASSISTANT_HANDOFF_RESOLVED: &str = "resolved";
const ASSISTANT_HANDOFF_INTENT: &str = "human_support";
const ASSISTANT_HANDOFF_MESSAGE_MAX_CHARS: usize = 2_000;
const ASSISTANT_ADMIN_NOTE_MAX_CHARS: usize = 2_000;
const ASSISTANT_BODY_LIMIT_BYTES: usize = 64 * 1_024;

#[derive(Clone, Debug, Serialize, PartialEq, Eq)]
struct AssistantLead {
    id: i64,
    user_id: i64,
    source: String,
    intent: String,
    message: String,
    status: String,
    admin_user_id: i64,
    admin_note: String,
    created_at: i64,
    resolved_at: i64,
}

#[derive(Clone, Debug, Serialize, PartialEq, Eq)]
struct AssistantLeadView {
    #[serde(flatten)]
    lead: AssistantLead,
    username: String,
    email: String,
}

#[derive(Clone, Debug, Serialize, PartialEq, Eq)]
struct AssistantIntentSummary {
    intent: String,
    count: i64,
}

#[derive(Clone, Debug, PartialEq, Eq)]
struct AssistantAdminAudit {
    actor_id: i64,
    actor_username: String,
    actor_role: i64,
    auth_method: &'static str,
    client_ip: String,
    lead_id: String,
    status: StatusCode,
    success: bool,
}

#[derive(Clone, Debug, PartialEq, Eq)]
enum ResolveHandoffError {
    NotFound,
    AlreadyResolved,
    Unavailable(String),
}

#[derive(Clone, Copy, Debug)]
pub struct AssistantRateLimitConfig {
    pub enabled: bool,
    pub max_requests: u64,
    pub window: Duration,
    pub dependency_timeout: Duration,
}

#[async_trait]
trait AssistantUserRateLimiter: Send + Sync {
    async fn check(
        &self,
        scope: &str,
        user_id: i64,
    ) -> Result<CriticalRateLimitOutcome, ()>;
}

#[derive(Clone)]
struct ValkeyAssistantUserRateLimiter {
    valkey: redis::Client,
    config: AssistantRateLimitConfig,
}

#[async_trait]
impl AssistantUserRateLimiter for ValkeyAssistantUserRateLimiter {
    async fn check(
        &self,
        scope: &str,
        user_id: i64,
    ) -> Result<CriticalRateLimitOutcome, ()> {
        if !self.config.enabled {
            return Ok(CriticalRateLimitOutcome::Allowed);
        }
        let mut connection = tokio::time::timeout(
            self.config.dependency_timeout,
            self.valkey.get_multiplexed_async_connection(),
        )
        .await
        .map_err(|_| ())?
        .map_err(|_| ())?;
        let key = format!("rateLimit:v2:user:UC:{scope}:{user_id}");
        let script = redis::Script::new(
            r#"
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
"#,
        );
        let (allowed, _, ttl): (i64, i64, i64) = tokio::time::timeout(
            self.config.dependency_timeout,
            script
                .key(key)
                .arg(self.config.max_requests)
                .arg(self.config.window.as_secs())
                .invoke_async(&mut connection),
        )
        .await
        .map_err(|_| ())?
        .map_err(|_| ())?;
        if allowed == 1 {
            Ok(CriticalRateLimitOutcome::Allowed)
        } else {
            Ok(CriticalRateLimitOutcome::Rejected {
                retry_after_seconds: ttl.max(0) as u64,
            })
        }
    }
}

#[derive(Clone, Debug, PartialEq, Eq)]
struct AssistantSettingsView {
    enabled: bool,
    model: String,
    agent_loop_enabled: bool,
    max_steps: i64,
    timeout_seconds: i64,
    cache_enabled: bool,
    cache_ttl_minutes: i64,
}

impl Default for AssistantSettingsView {
    fn default() -> Self {
        Self {
            enabled: true,
            model: "deepseek-v4-flash".to_owned(),
            agent_loop_enabled: true,
            max_steps: 6,
            timeout_seconds: 45,
            cache_enabled: true,
            cache_ttl_minutes: 1_440,
        }
    }
}

impl AssistantSettingsView {
    fn from_options(options: &HashMap<String, String>) -> Self {
        let defaults = Self::default();
        Self {
            enabled: options
                .get("AssistantEnabled")
                .map_or(defaults.enabled, |value| value == "true"),
            model: options
                .get("AssistantModel")
                .map(|value| value.trim())
                .filter(|value| !value.is_empty() && value.len() <= 128)
                .map_or(defaults.model, str::to_owned),
            agent_loop_enabled: options
                .get("AssistantAgentLoopEnabled")
                .map_or(defaults.agent_loop_enabled, |value| value == "true"),
            max_steps: bounded_option(options, "AssistantMaxSteps", 1, 12)
                .unwrap_or(defaults.max_steps),
            timeout_seconds: bounded_option(options, "AssistantTimeoutSeconds", 5, 120)
                .unwrap_or(defaults.timeout_seconds),
            cache_enabled: options
                .get("AssistantCacheEnabled")
                .map_or(defaults.cache_enabled, |value| value == "true"),
            cache_ttl_minutes: bounded_option(options, "AssistantCacheTTLMinutes", 0, 10_080)
                .unwrap_or(defaults.cache_ttl_minutes),
        }
    }
}

fn bounded_option(
    options: &HashMap<String, String>,
    key: &str,
    minimum: i64,
    maximum: i64,
) -> Option<i64> {
    options
        .get(key)?
        .trim()
        .parse::<i64>()
        .ok()
        .filter(|value| (minimum..=maximum).contains(value))
}

#[async_trait]
trait AssistantReadStore: Send + Sync {
    async fn settings(&self) -> Result<AssistantSettingsView, String>;
    async fn latest_handoff(&self, user_id: i64) -> Result<Option<AssistantLead>, String>;
    async fn list_handoffs(
        &self,
        status: &str,
        limit: i64,
    ) -> Result<Vec<AssistantLeadView>, String>;
    async fn intent_summary(&self, since: i64) -> Result<Vec<AssistantIntentSummary>, String>;
    async fn submit_handoff(
        &self,
        user_id: i64,
        username: &str,
        message: &str,
    ) -> Result<AssistantLead, String>;
    async fn resolve_handoff(
        &self,
        admin_user_id: i64,
        admin_username: &str,
        lead_id: i64,
        note: &str,
    ) -> Result<AssistantLead, ResolveHandoffError>;
    async fn record_admin_audit(&self, audit: AssistantAdminAudit);
}

#[derive(Clone)]
struct PgAssistantReadStore {
    pg: PgPool,
}

impl PgAssistantReadStore {
    async fn record_system_log(&self, user_id: i64, username: &str, content: String) {
        let _ = sqlx::query(
            "INSERT INTO logs (user_id, created_at, type, content, username, request_id) \
             VALUES ($1, $2, 4, $3, $4, $5)",
        )
        .bind(user_id)
        .bind(unix_seconds())
        .bind(content)
        .bind(username)
        .bind(uuid::Uuid::new_v4().to_string())
        .execute(&self.pg)
        .await;
    }
}

#[async_trait]
impl AssistantReadStore for PgAssistantReadStore {
    async fn settings(&self) -> Result<AssistantSettingsView, String> {
        let rows = sqlx::query(
            "SELECT key, value FROM options WHERE key IN \
             ('AssistantEnabled', 'AssistantModel', 'AssistantAgentLoopEnabled', \
              'AssistantMaxSteps', 'AssistantTimeoutSeconds', 'AssistantCacheEnabled', \
              'AssistantCacheTTLMinutes')",
        )
        .fetch_all(&self.pg)
        .await
        .map_err(|error| error.to_string())?;
        let options = rows
            .into_iter()
            .map(|row| {
                Ok((
                    row.try_get::<String, _>("key")?,
                    row.try_get::<String, _>("value")?,
                ))
            })
            .collect::<Result<HashMap<_, _>, sqlx::Error>>()
            .map_err(|error| error.to_string())?;
        Ok(AssistantSettingsView::from_options(&options))
    }

    async fn latest_handoff(&self, user_id: i64) -> Result<Option<AssistantLead>, String> {
        sqlx::query(
            "SELECT id::BIGINT AS id, user_id::BIGINT AS user_id, COALESCE(source, '') AS source, \
             COALESCE(intent, '') AS intent, COALESCE(message, '') AS message, \
             COALESCE(status, '') AS status, COALESCE(admin_user_id, 0)::BIGINT AS admin_user_id, \
             COALESCE(admin_note, '') AS admin_note, COALESCE(created_at, 0)::BIGINT AS created_at, \
             COALESCE(resolved_at, 0)::BIGINT AS resolved_at \
             FROM assistant_leads WHERE user_id = $1 AND source = $2 ORDER BY id DESC LIMIT 1",
        )
        .bind(user_id)
        .bind(ASSISTANT_HANDOFF_SOURCE)
        .fetch_optional(&self.pg)
        .await
        .map_err(|error| error.to_string())?
        .map(|row| assistant_lead_from_row(&row).map_err(|error| error.to_string()))
        .transpose()
    }

    async fn list_handoffs(
        &self,
        status: &str,
        limit: i64,
    ) -> Result<Vec<AssistantLeadView>, String> {
        sqlx::query(
            "SELECT lead.id::BIGINT AS id, lead.user_id::BIGINT AS user_id, \
             COALESCE(lead.source, '') AS source, COALESCE(lead.intent, '') AS intent, \
             COALESCE(lead.message, '') AS message, COALESCE(lead.status, '') AS status, \
             COALESCE(lead.admin_user_id, 0)::BIGINT AS admin_user_id, \
             COALESCE(lead.admin_note, '') AS admin_note, \
             COALESCE(lead.created_at, 0)::BIGINT AS created_at, \
             COALESCE(lead.resolved_at, 0)::BIGINT AS resolved_at, \
             COALESCE(users.username, '') AS username, COALESCE(users.email, '') AS email \
             FROM assistant_leads AS lead JOIN users ON users.id = lead.user_id \
             WHERE lead.source = $1 AND lead.status = $2 ORDER BY lead.id DESC LIMIT $3",
        )
        .bind(ASSISTANT_HANDOFF_SOURCE)
        .bind(status)
        .bind(limit)
        .fetch_all(&self.pg)
        .await
        .map_err(|error| error.to_string())?
        .into_iter()
        .map(|row| {
            let lead = assistant_lead_from_row(&row).map_err(|error| error.to_string())?;
            Ok(AssistantLeadView {
                lead,
                username: row
                    .try_get("username")
                    .map_err(|error: sqlx::Error| error.to_string())?,
                email: row
                    .try_get("email")
                    .map_err(|error: sqlx::Error| error.to_string())?,
            })
        })
        .collect()
    }

    async fn intent_summary(&self, since: i64) -> Result<Vec<AssistantIntentSummary>, String> {
        sqlx::query(
            "SELECT COALESCE(intent, '') AS intent, COUNT(*)::BIGINT AS count \
             FROM assistant_leads WHERE created_at >= $1 \
             GROUP BY intent ORDER BY count DESC, intent ASC",
        )
        .bind(since)
        .fetch_all(&self.pg)
        .await
        .map_err(|error| error.to_string())?
        .into_iter()
        .map(|row| {
            Ok(AssistantIntentSummary {
                intent: row
                    .try_get("intent")
                    .map_err(|error: sqlx::Error| error.to_string())?,
                count: row
                    .try_get("count")
                    .map_err(|error: sqlx::Error| error.to_string())?,
            })
        })
        .collect()
    }

    async fn submit_handoff(
        &self,
        user_id: i64,
        username: &str,
        message: &str,
    ) -> Result<AssistantLead, String> {
        let mut transaction = self.pg.begin().await.map_err(|error| error.to_string())?;
        sqlx::query("SELECT id FROM users WHERE id = $1 FOR UPDATE")
            .bind(user_id)
            .fetch_one(&mut *transaction)
            .await
            .map_err(|error| error.to_string())?;
        let existing = sqlx::query(
            "SELECT id::BIGINT AS id, user_id::BIGINT AS user_id, \
             COALESCE(source, '') AS source, COALESCE(intent, '') AS intent, \
             COALESCE(message, '') AS message, COALESCE(status, '') AS status, \
             COALESCE(admin_user_id, 0)::BIGINT AS admin_user_id, \
             COALESCE(admin_note, '') AS admin_note, \
             COALESCE(created_at, 0)::BIGINT AS created_at, \
             COALESCE(resolved_at, 0)::BIGINT AS resolved_at \
             FROM assistant_leads WHERE user_id = $1 AND source = $2 AND status = $3 \
             ORDER BY id DESC LIMIT 1",
        )
        .bind(user_id)
        .bind(ASSISTANT_HANDOFF_SOURCE)
        .bind(ASSISTANT_HANDOFF_PENDING)
        .fetch_optional(&mut *transaction)
        .await
        .map_err(|error| error.to_string())?;
        let lead = if let Some(row) = existing {
            assistant_lead_from_row(&row).map_err(|error| error.to_string())?
        } else {
            let created_at = unix_seconds();
            let row = sqlx::query(
                "INSERT INTO assistant_leads \
                 (user_id, source, intent, message, status, created_at) \
                 VALUES ($1, $2, $3, $4, $5, $6) \
                 RETURNING id::BIGINT AS id, user_id::BIGINT AS user_id, \
                 COALESCE(source, '') AS source, COALESCE(intent, '') AS intent, \
                 COALESCE(message, '') AS message, COALESCE(status, '') AS status, \
                 COALESCE(admin_user_id, 0)::BIGINT AS admin_user_id, \
                 COALESCE(admin_note, '') AS admin_note, \
                 COALESCE(created_at, 0)::BIGINT AS created_at, \
                 COALESCE(resolved_at, 0)::BIGINT AS resolved_at",
            )
            .bind(user_id)
            .bind(ASSISTANT_HANDOFF_SOURCE)
            .bind(ASSISTANT_HANDOFF_INTENT)
            .bind(message)
            .bind(ASSISTANT_HANDOFF_PENDING)
            .bind(created_at)
            .fetch_one(&mut *transaction)
            .await
            .map_err(|error| error.to_string())?;
            assistant_lead_from_row(&row).map_err(|error| error.to_string())?
        };
        transaction
            .commit()
            .await
            .map_err(|error| error.to_string())?;
        self.record_system_log(
            user_id,
            username,
            format!("submitted assistant support request {}", lead.id),
        )
        .await;
        Ok(lead)
    }

    async fn resolve_handoff(
        &self,
        admin_user_id: i64,
        admin_username: &str,
        lead_id: i64,
        note: &str,
    ) -> Result<AssistantLead, ResolveHandoffError> {
        let mut transaction = self
            .pg
            .begin()
            .await
            .map_err(|error| ResolveHandoffError::Unavailable(error.to_string()))?;
        let row = sqlx::query(
            "SELECT id::BIGINT AS id, user_id::BIGINT AS user_id, \
             COALESCE(source, '') AS source, COALESCE(intent, '') AS intent, \
             COALESCE(message, '') AS message, COALESCE(status, '') AS status, \
             COALESCE(admin_user_id, 0)::BIGINT AS admin_user_id, \
             COALESCE(admin_note, '') AS admin_note, \
             COALESCE(created_at, 0)::BIGINT AS created_at, \
             COALESCE(resolved_at, 0)::BIGINT AS resolved_at \
             FROM assistant_leads WHERE id = $1 AND source = $2 FOR UPDATE",
        )
        .bind(lead_id)
        .bind(ASSISTANT_HANDOFF_SOURCE)
        .fetch_optional(&mut *transaction)
        .await
        .map_err(|error| ResolveHandoffError::Unavailable(error.to_string()))?;
        let Some(row) = row else {
            return Err(ResolveHandoffError::NotFound);
        };
        let mut lead = assistant_lead_from_row(&row)
            .map_err(|error| ResolveHandoffError::Unavailable(error.to_string()))?;
        if lead.status != ASSISTANT_HANDOFF_PENDING {
            return Err(ResolveHandoffError::AlreadyResolved);
        }
        let resolved_at = unix_seconds();
        sqlx::query(
            "UPDATE assistant_leads SET status = $2, admin_user_id = $3, admin_note = $4, \
             resolved_at = $5 WHERE id = $1",
        )
        .bind(lead_id)
        .bind(ASSISTANT_HANDOFF_RESOLVED)
        .bind(admin_user_id)
        .bind(note)
        .bind(resolved_at)
        .execute(&mut *transaction)
        .await
        .map_err(|error| ResolveHandoffError::Unavailable(error.to_string()))?;
        transaction
            .commit()
            .await
            .map_err(|error| ResolveHandoffError::Unavailable(error.to_string()))?;

        lead.status = ASSISTANT_HANDOFF_RESOLVED.to_owned();
        lead.admin_user_id = admin_user_id;
        lead.admin_note = note.to_owned();
        lead.resolved_at = resolved_at;

        self.record_system_log(
            admin_user_id,
            admin_username,
            format!("resolved assistant support request {lead_id}"),
        )
        .await;
        Ok(lead)
    }

    async fn record_admin_audit(&self, audit: AssistantAdminAudit) {
        let route = "/api/assistant/admin/handoffs/:id/resolve";
        let path = format!("/api/assistant/admin/handoffs/{}/resolve", audit.lead_id);
        let other = json!({
            "op": {
                "action": "generic",
                "params": {"method": "POST", "route": route},
            },
            "admin_info": {
                "admin_id": audit.actor_id,
                "admin_username": audit.actor_username,
                "admin_role": audit.actor_role,
                "auth_method": audit.auth_method,
            },
            "audit_info": {
                "method": "POST",
                "route": route,
                "path": path,
                "status": audit.status.as_u16(),
                "success": audit.success,
                "params": {"id": audit.lead_id},
            },
        });
        let _ = sqlx::query(
            "INSERT INTO logs (user_id, created_at, type, content, username, ip, other, request_id) \
             VALUES ($1, $2, 3, $3, $4, $5, $6, $7)",
        )
        .bind(audit.actor_id)
        .bind(unix_seconds())
        .bind(format!("POST {route}"))
        .bind(audit.actor_username)
        .bind(audit.client_ip)
        .bind(other.to_string())
        .bind(uuid::Uuid::new_v4().to_string())
        .execute(&self.pg)
        .await;
    }
}

fn unix_seconds() -> i64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map_or(0, |duration| duration.as_secs() as i64)
}

fn assistant_lead_from_row(row: &PgRow) -> Result<AssistantLead, sqlx::Error> {
    Ok(AssistantLead {
        id: row.try_get("id")?,
        user_id: row.try_get("user_id")?,
        source: row.try_get("source")?,
        intent: row.try_get("intent")?,
        message: row.try_get("message")?,
        status: row.try_get("status")?,
        admin_user_id: row.try_get("admin_user_id")?,
        admin_note: row.try_get("admin_note")?,
        created_at: row.try_get("created_at")?,
        resolved_at: row.try_get("resolved_at")?,
    })
}

#[derive(Clone)]
pub struct AssistantReadState {
    pg: PgPool,
    auth: Arc<dyn DashboardAuth>,
    store: Arc<dyn AssistantReadStore>,
}

impl AssistantReadState {
    #[must_use]
    pub fn new(pg: PgPool, auth: Arc<dyn DashboardAuth>) -> Self {
        let store = Arc::new(PgAssistantReadStore { pg: pg.clone() });
        Self { pg, auth, store }
    }

    #[cfg(test)]
    fn with_store(mut self, store: Arc<dyn AssistantReadStore>) -> Self {
        self.store = store;
        self
    }
}

#[derive(Serialize)]
struct Envelope<T> {
    success: bool,
    message: &'static str,
    data: T,
}

pub fn assistant_read_router(state: AssistantReadState) -> Router {
    Router::new()
        .route("/api/assistant/status", get(assistant_status))
        .route("/api/assistant/offers", get(offers))
        .route("/api/assistant/handoffs/self", get(self_handoff))
        .route("/api/assistant/admin/handoffs", get(admin_handoffs))
        .route(
            "/api/assistant/admin/handoffs/{id}/resolve",
            post(admin_resolve_handoff),
        )
        .route("/api/assistant/admin/intents", get(admin_intents))
        .with_state(state)
}

struct AssistantPrincipal {
    user: DashboardUserView,
    credential: String,
}

async fn assistant_status(State(state): State<AssistantReadState>, headers: HeaderMap) -> Response {
    let principal = match authenticated_user(&state, &headers).await {
        Ok(principal) => principal,
        Err(response) => return response,
    };
    let settings = match state.store.settings().await {
        Ok(settings) => settings,
        Err(error) => return api_error(error),
    };
    success(json!({
        "enabled": settings.enabled,
        "model": settings.model,
        "funding": {
            "mode": "super_administrator",
        },
        "developer_access_granted": principal.user.developer_access_granted,
        "agent": {
            "enabled": settings.agent_loop_enabled,
            "max_steps": settings.max_steps,
            "timeout_seconds": settings.timeout_seconds,
            "cache_enabled": settings.cache_enabled,
            "cache_ttl_minutes": settings.cache_ttl_minutes,
        },
    }))
}

async fn self_handoff(State(state): State<AssistantReadState>, headers: HeaderMap) -> Response {
    let principal = match authenticated_user(&state, &headers).await {
        Ok(principal) => principal,
        Err(response) => return response,
    };
    with_no_store(match state.store.latest_handoff(principal.user.id).await {
        Ok(lead) => success(json!(lead)),
        Err(error) => api_error(error),
    })
}

async fn admin_handoffs(
    State(state): State<AssistantReadState>,
    RawQuery(raw_query): RawQuery,
    headers: HeaderMap,
) -> Response {
    if let Err(response) = authenticated_admin(&state, &headers).await {
        return response;
    }
    let status = query_value(raw_query.as_deref(), "status")
        .trim()
        .to_owned();
    let status = if status.is_empty() {
        ASSISTANT_HANDOFF_PENDING
    } else if matches!(
        status.as_str(),
        ASSISTANT_HANDOFF_PENDING | ASSISTANT_HANDOFF_RESOLVED
    ) {
        status.as_str()
    } else {
        return assistant_error(
            StatusCode::BAD_REQUEST,
            "ASSISTANT_HANDOFF_INVALID_STATUS",
            "assistant support request status is invalid",
        );
    };
    match state.store.list_handoffs(status, 100).await {
        Ok(leads) => success(json!(leads)),
        Err(error) => api_error(error),
    }
}

async fn admin_intents(
    State(state): State<AssistantReadState>,
    RawQuery(raw_query): RawQuery,
    headers: HeaderMap,
) -> Response {
    if let Err(response) = authenticated_admin(&state, &headers).await {
        return response;
    }
    let days = match intent_days(&query_value(raw_query.as_deref(), "days")) {
        Ok(days) => days,
        Err(message) => {
            return assistant_error(
                StatusCode::BAD_REQUEST,
                "ASSISTANT_INTENT_DAYS_INVALID",
                message,
            );
        }
    };
    let now = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map_or(0, |duration| duration.as_secs() as i64);
    let since = now.saturating_sub(days.saturating_mul(24 * 60 * 60));
    match state.store.intent_summary(since).await {
        Ok(summary) => success(json!(summary)),
        Err(error) => api_error(error),
    }
}

#[derive(Debug, Default, Deserialize)]
struct AssistantResolveHandoffInput {
    #[serde(default, deserialize_with = "deserialize_nullable_string")]
    note: String,
}

fn deserialize_nullable_string<'de, D>(deserializer: D) -> Result<String, D::Error>
where
    D: serde::Deserializer<'de>,
{
    Option::<String>::deserialize(deserializer).map(Option::unwrap_or_default)
}

async fn admin_resolve_handoff(
    State(state): State<AssistantReadState>,
    Path(lead_id_raw): Path<String>,
    request: axum::extract::Request,
) -> Response {
    let principal = match authenticated_admin(&state, request.headers()).await {
        Ok(principal) => principal,
        Err(response) => return response,
    };
    let client_ip = request
        .extensions()
        .get::<ClientIpKey>()
        .map_or_else(|| "unknown".to_owned(), |key| key.0.clone());
    let auth_method = if state
        .auth
        .current_session(SecretString::from(principal.credential.clone()))
        .await
        .is_ok()
    {
        "session"
    } else {
        "access_token"
    };

    let rate_limit_response = match state.auth.check_critical_rate_limit(&client_ip).await {
        Ok(CriticalRateLimitOutcome::Allowed) => None,
        Ok(CriticalRateLimitOutcome::Rejected {
            retry_after_seconds,
        }) => Some(with_auth_version(legacy_empty_response(
            StatusCode::TOO_MANY_REQUESTS,
            Some(retry_after_seconds),
        ))),
        Err(_) => Some(with_auth_version(legacy_empty_response(
            StatusCode::INTERNAL_SERVER_ERROR,
            None,
        ))),
    };
    if let Some(response) = rate_limit_response {
        return audited_admin_resolve_response(
            &state,
            &principal,
            auth_method,
            client_ip,
            lead_id_raw,
            response,
            false,
        )
        .await;
    }

    let lead_id = match lead_id_raw.parse::<i64>() {
        Ok(lead_id) if lead_id > 0 => lead_id,
        _ => {
            let response = assistant_error(
                StatusCode::BAD_REQUEST,
                "ASSISTANT_HANDOFF_INVALID_ID",
                "invalid support request id",
            );
            return audited_admin_resolve_response(
                &state,
                &principal,
                auth_method,
                client_ip,
                lead_id_raw,
                response,
                false,
            )
            .await;
        }
    };
    let input = match assistant_resolve_input(request).await {
        Ok(input) => input,
        Err(response) => {
            return audited_admin_resolve_response(
                &state,
                &principal,
                auth_method,
                client_ip,
                lead_id_raw,
                response,
                false,
            )
            .await;
        }
    };
    let note = input.note.trim();
    if note.chars().count() > ASSISTANT_ADMIN_NOTE_MAX_CHARS {
        let response = assistant_error(
            StatusCode::UNPROCESSABLE_ENTITY,
            "ASSISTANT_HANDOFF_NOTE_TOO_LONG",
            "assistant support note must be at most 2000 characters",
        );
        return audited_admin_resolve_response(
            &state,
            &principal,
            auth_method,
            client_ip,
            lead_id_raw,
            response,
            false,
        )
        .await;
    }
    let (response, success) = match state
        .store
        .resolve_handoff(principal.user.id, &principal.user.username, lead_id, note)
        .await
    {
        Ok(lead) => (success(json!(lead)), true),
        Err(ResolveHandoffError::NotFound) => (
            assistant_error(
                StatusCode::NOT_FOUND,
                "ASSISTANT_HANDOFF_NOT_FOUND",
                "assistant support request not found",
            ),
            false,
        ),
        Err(ResolveHandoffError::AlreadyResolved) => (
            assistant_error(
                StatusCode::CONFLICT,
                "ASSISTANT_HANDOFF_ALREADY_RESOLVED",
                "assistant support request is already resolved",
            ),
            false,
        ),
        Err(ResolveHandoffError::Unavailable(error)) => (api_error(error), false),
    };
    audited_admin_resolve_response(
        &state,
        &principal,
        auth_method,
        client_ip,
        lead_id_raw,
        response,
        success,
    )
    .await
}

async fn assistant_resolve_input(
    request: axum::extract::Request,
) -> Result<AssistantResolveHandoffInput, Response> {
    let body = to_bytes(request.into_body(), ASSISTANT_RESOLVE_BODY_LIMIT_BYTES)
        .await
        .map_err(|_| invalid_assistant_resolve_request())?;
    if body.is_empty() {
        return Ok(AssistantResolveHandoffInput::default());
    }
    let value: Value =
        serde_json::from_slice(&body).map_err(|_| invalid_assistant_resolve_request())?;
    if value.is_null() {
        return Ok(AssistantResolveHandoffInput::default());
    }
    serde_json::from_value(value).map_err(|_| invalid_assistant_resolve_request())
}

fn invalid_assistant_resolve_request() -> Response {
    assistant_error(
        StatusCode::BAD_REQUEST,
        "ASSISTANT_INVALID_REQUEST",
        "invalid support resolution",
    )
}

async fn audited_admin_resolve_response(
    state: &AssistantReadState,
    principal: &AssistantPrincipal,
    auth_method: &'static str,
    client_ip: String,
    lead_id: String,
    response: Response,
    success: bool,
) -> Response {
    state
        .store
        .record_admin_audit(AssistantAdminAudit {
            actor_id: principal.user.id,
            actor_username: principal.user.username.clone(),
            actor_role: principal.user.role,
            auth_method,
            client_ip,
            lead_id,
            status: response.status(),
            success,
        })
        .await;
    response
}

fn query_value(query: Option<&str>, target: &str) -> String {
    form_urlencoded::parse(query.unwrap_or_default().as_bytes())
        .find_map(|(key, value)| (key == target).then(|| value.into_owned()))
        .unwrap_or_default()
}

fn intent_days(raw: &str) -> Result<i64, &'static str> {
    let raw = raw.trim();
    if raw.is_empty() {
        return Ok(30);
    }
    raw.parse::<i64>()
        .ok()
        .filter(|days| (1..=365).contains(days))
        .ok_or("days must be between 1 and 365")
}

async fn offers(State(state): State<AssistantReadState>, headers: HeaderMap) -> Response {
    let user = match browser_user(&state, &headers).await {
        Ok(user) => user,
        Err(response) => return response,
    };
    if !user.developer_access_granted {
        return success(access_denied_offer_payload());
    }
    let restricted = match payment_restricted(&state.pg, user.id).await {
        Ok(Some(restricted)) => restricted,
        Ok(None) | Err(_) => {
            return success(json!({
                "ok": false,
                "error": "account access could not be loaded",
            }));
        }
    };
    let compliance = match payment_compliance_confirmed(&state.pg).await {
        Ok(compliance) => compliance,
        Err(_) => {
            return success(json!({
                "ok": false,
                "error": "plan offers could not be loaded",
            }));
        }
    };
    if !compliance {
        return success(offer_payload(
            false,
            restricted,
            Value::Array(Vec::new()),
            Map::new(),
        ));
    }
    let plans = match enabled_plan_views(&state.pg).await {
        Ok(plans) => json!(plans),
        Err(_) => {
            return success(json!({
                "ok": false,
                "error": "subscription plans could not be loaded",
            }));
        }
    };
    let discounts = if restricted {
        Map::new()
    } else {
        match amount_discounts(&state.pg).await {
            Ok(discounts) => discounts,
            Err(_) => {
                return success(json!({
                    "ok": false,
                    "error": "top-up discounts could not be loaded",
                }));
            }
        }
    };
    success(offer_payload(true, restricted, plans, discounts))
}

async fn browser_user(
    state: &AssistantReadState,
    headers: &HeaderMap,
) -> Result<DashboardUserView, Response> {
    let principal = authenticated_user(state, headers).await?;
    state
        .auth
        .current_session(SecretString::from(principal.credential))
        .await
        .map_err(|_| assistant_session_required())?;
    Ok(principal.user)
}

async fn authenticated_user(
    state: &AssistantReadState,
    headers: &HeaderMap,
) -> Result<AssistantPrincipal, Response> {
    let credential =
        dashboard_credential(headers).ok_or_else(|| dashboard_auth_error(headers, None))?;
    let user = state
        .auth
        .self_user_view_for_optional(SecretString::from(credential.clone()))
        .await
        .map_err(|error| dashboard_auth_error(headers, Some(error.kind)))?;
    enforce_user_auth_view(&user).map_err(|error| user_auth_error(headers, error))?;
    Ok(AssistantPrincipal { user, credential })
}

async fn authenticated_admin(
    state: &AssistantReadState,
    headers: &HeaderMap,
) -> Result<AssistantPrincipal, Response> {
    let principal = authenticated_user(state, headers).await?;
    if principal.user.role < ADMIN_ROLE {
        return Err(user_auth_error(
            headers,
            UserAuthPolicyError::InsufficientPrivilege,
        ));
    }
    Ok(principal)
}

async fn payment_restricted(pg: &PgPool, user_id: i64) -> Result<Option<bool>, sqlx::Error> {
    let row = sqlx::query(
        "SELECT COALESCE(email, '') AS email, \
         COALESCE(to_jsonb(users)->>'payment_restriction_flags', '0') AS restriction_flags \
         FROM users WHERE id = $1 AND deleted_at IS NULL",
    )
    .bind(user_id)
    .fetch_optional(pg)
    .await?;
    row.map(|row| {
        let email: String = row.try_get("email")?;
        let flags = row
            .try_get::<String, _>("restriction_flags")?
            .parse::<i64>()
            .unwrap_or_default();
        Ok(flags != 0 || is_linux_do_email(&email))
    })
    .transpose()
}

async fn amount_discounts(pg: &PgPool) -> Result<Map<String, Value>, sqlx::Error> {
    let rows = sqlx::query(
        "SELECT key, value FROM options \
         WHERE key IN ('payment_setting.amount_discount', 'payment_setting')",
    )
    .fetch_all(pg)
    .await?;
    let values = rows
        .into_iter()
        .map(|row| {
            Ok((
                row.try_get::<String, _>("key")?,
                row.try_get::<String, _>("value")?,
            ))
        })
        .collect::<Result<HashMap<_, _>, sqlx::Error>>()?;
    Ok(parse_amount_discounts(&values))
}

fn parse_amount_discounts(values: &HashMap<String, String>) -> Map<String, Value> {
    let direct = values
        .get("payment_setting.amount_discount")
        .and_then(|raw| serde_json::from_str::<Map<String, Value>>(raw).ok());
    let legacy = values
        .get("payment_setting")
        .and_then(|raw| serde_json::from_str::<Value>(raw).ok())
        .and_then(|value| {
            value
                .get("amount_discount")
                .and_then(Value::as_object)
                .cloned()
        });
    direct
        .or(legacy)
        .unwrap_or_default()
        .into_iter()
        .filter(|(amount, multiplier)| {
            amount.parse::<i64>().is_ok() && multiplier.as_f64().is_some()
        })
        .collect()
}

fn offer_payload(
    compliance: bool,
    restricted: bool,
    plans: Value,
    discounts: Map<String, Value>,
) -> Value {
    let mut result = Map::from_iter([
        ("ok".to_owned(), Value::Bool(true)),
        ("developer_access_granted".to_owned(), Value::Bool(true)),
        ("read_only".to_owned(), Value::Bool(false)),
        (
            "checkout_available".to_owned(),
            Value::Bool(compliance && !restricted),
        ),
        ("payment_hidden".to_owned(), Value::Bool(restricted)),
        ("plans".to_owned(), plans),
        ("topup_discounts".to_owned(), Value::Object(discounts)),
        (
            "payment_compliance_confirmed".to_owned(),
            Value::Bool(compliance),
        ),
    ]);
    if restricted {
        result.insert(
            "message".to_owned(),
            Value::String(
                "Payment options are hidden for this account; do not direct the user to checkout."
                    .to_owned(),
            ),
        );
    }
    if !compliance {
        result.insert(
            "message".to_owned(),
            Value::String(
                "Current plan offers are unavailable until payment compliance is confirmed."
                    .to_owned(),
            ),
        );
    }
    Value::Object(result)
}

fn access_denied_offer_payload() -> Value {
    json!({
        "ok": false,
        "developer_access_granted": false,
        "read_only": false,
        "checkout_available": false,
        "payment_hidden": true,
        "plans": [],
        "topup_discounts": {},
        "payment_compliance_confirmed": false,
        "error": "L1 access is required to view plans and top-up discounts",
        "next_step": "Ask the user to submit an administrator L1 access request from the onboarding assistant."
    })
}

fn dashboard_credential(headers: &HeaderMap) -> Option<String> {
    let value = headers.get(header::AUTHORIZATION)?.to_str().ok()?.trim();
    let mut fields = value.split_whitespace();
    let first = fields.next()?;
    let second = fields.next();
    if fields.next().is_some() {
        return None;
    }
    match second {
        Some(token) if first.eq_ignore_ascii_case("bearer") && !token.is_empty() => {
            Some(token.to_owned())
        }
        None if !first.is_empty() => Some(first.to_owned()),
        _ => None,
    }
}

fn dashboard_auth_error(headers: &HeaderMap, kind: Option<AuthErrorKind>) -> Response {
    let (code, message) = match kind {
        Some(AuthErrorKind::TokenExpired) => (
            "AUTH_TOKEN_EXPIRED",
            "Unauthorized, not logged in and no access token provided",
        ),
        Some(AuthErrorKind::SessionRevoked) => (
            "AUTH_SESSION_REVOKED",
            "Unauthorized, not logged in and no access token provided",
        ),
        Some(AuthErrorKind::Internal) => (
            "AUTH_INTERNAL_ERROR",
            "Database error, please contact the administrator",
        ),
        Some(AuthErrorKind::UserDisabled) => ("AUTH_USER_DISABLED", "User has been banned"),
        _ => ("AUTH_UNAUTHORIZED", "Unauthorized, invalid access token"),
    };
    let status = if matches!(kind, Some(AuthErrorKind::Internal)) {
        StatusCode::INTERNAL_SERVER_ERROR
    } else {
        StatusCode::UNAUTHORIZED
    };
    let message = if headers
        .get(header::ACCEPT_LANGUAGE)
        .and_then(|value| value.to_str().ok())
        .is_some_and(|value| value.to_ascii_lowercase().starts_with("zh"))
    {
        match code {
            "AUTH_INTERNAL_ERROR" => "数据库出错，请联系管理员",
            "AUTH_TOKEN_EXPIRED" | "AUTH_SESSION_REVOKED" => {
                "无权进行此操作，未登录且未提供 access token"
            }
            _ => "无权进行此操作，access token 无效",
        }
    } else {
        message
    };
    (
        status,
        Json(json!({
            "success": false,
            "code": code,
            "message": message,
        })),
    )
        .into_response()
}

fn user_auth_error(headers: &HeaderMap, error: UserAuthPolicyError) -> Response {
    let code = match error {
        UserAuthPolicyError::UserDisabled => "AUTH_USER_DISABLED",
        UserAuthPolicyError::InsufficientPrivilege => "AUTH_INSUFFICIENT_PRIVILEGE",
        UserAuthPolicyError::InvalidUserInfo => "AUTH_USER_INVALID",
    };
    let status = StatusCode::from_u16(user_auth_status(error)).unwrap_or(StatusCode::UNAUTHORIZED);
    (
        status,
        Json(json!({
            "success": false,
            "code": code,
            "message": user_auth_message(
                error,
                headers.get(header::ACCEPT_LANGUAGE).and_then(|value| value.to_str().ok()),
            ),
        })),
    )
        .into_response()
}

fn assistant_session_required() -> Response {
    with_auth_version(
        (
            StatusCode::FORBIDDEN,
            Json(json!({
                "success": false,
                "code": "ASSISTANT_SESSION_REQUIRED",
                "message": "assistant tools require a browser login session",
            })),
        )
            .into_response(),
    )
}

fn success(data: Value) -> Response {
    with_auth_version(
        Json(Envelope {
            success: true,
            message: "",
            data,
        })
        .into_response(),
    )
}

fn api_error(message: String) -> Response {
    with_auth_version(
        Json(json!({
            "success": false,
            "message": message,
        }))
        .into_response(),
    )
}

fn assistant_error(status: StatusCode, code: &'static str, message: &'static str) -> Response {
    with_auth_version(
        (
            status,
            Json(json!({
                "success": false,
                "code": code,
                "message": message,
            })),
        )
            .into_response(),
    )
}

fn with_auth_version(mut response: Response) -> Response {
    response.headers_mut().insert(
        "auth-version",
        axum::http::HeaderValue::from_static(AUTH_VERSION),
    );
    response
}

fn with_no_store(mut response: Response) -> Response {
    response.headers_mut().insert(
        header::CACHE_CONTROL,
        axum::http::HeaderValue::from_static(
            "no-store, no-cache, must-revalidate, private, max-age=0",
        ),
    );
    response.headers_mut().insert(
        header::PRAGMA,
        axum::http::HeaderValue::from_static("no-cache"),
    );
    response.headers_mut().insert(
        header::EXPIRES,
        axum::http::HeaderValue::from_static("0"),
    );
    response
}

fn is_linux_do_email(email: &str) -> bool {
    email
        .trim()
        .rsplit_once('@')
        .is_some_and(|(local, domain)| !local.is_empty() && domain.eq_ignore_ascii_case("linux.do"))
}

#[cfg(test)]
mod tests {
    use super::*;
    use axum::{
        body::{Body, to_bytes},
        http::Request,
    };
    use secrecy::{ExposeSecret, SecretString};
    use std::sync::Mutex;
    use tower::ServiceExt;

    use crate::auth::{
        AuthBundle, AuthError, CriticalRateLimitOutcome, DashboardSessionContext, DashboardUser,
        LoginOutcome, LoginRequest, LogoutRequest, LogoutResult, RequestMetadata,
        TwoFactorLoginRequest,
    };

    #[derive(Clone, Debug, PartialEq, Eq)]
    struct FixtureResolveCall {
        admin_user_id: i64,
        admin_username: String,
        lead_id: i64,
        note: String,
    }

    #[derive(Clone)]
    struct FixtureStore {
        settings: AssistantSettingsView,
        latest: Option<AssistantLead>,
        handoffs: Vec<AssistantLeadView>,
        expected_handoff_status: &'static str,
        summary: Vec<AssistantIntentSummary>,
        resolve_result: Option<Result<AssistantLead, ResolveHandoffError>>,
        resolve_calls: Arc<Mutex<Vec<FixtureResolveCall>>>,
        audits: Arc<Mutex<Vec<AssistantAdminAudit>>>,
    }

    impl Default for FixtureStore {
        fn default() -> Self {
            Self {
                settings: AssistantSettingsView::default(),
                latest: None,
                handoffs: Vec::new(),
                expected_handoff_status: ASSISTANT_HANDOFF_PENDING,
                summary: Vec::new(),
                resolve_result: None,
                resolve_calls: Arc::new(Mutex::new(Vec::new())),
                audits: Arc::new(Mutex::new(Vec::new())),
            }
        }
    }

    #[async_trait]
    impl AssistantReadStore for FixtureStore {
        async fn settings(&self) -> Result<AssistantSettingsView, String> {
            Ok(self.settings.clone())
        }

        async fn latest_handoff(&self, _: i64) -> Result<Option<AssistantLead>, String> {
            Ok(self.latest.clone())
        }

        async fn list_handoffs(
            &self,
            status: &str,
            limit: i64,
        ) -> Result<Vec<AssistantLeadView>, String> {
            if status != self.expected_handoff_status || limit != 100 {
                return Err("unexpected handoff query".to_owned());
            }
            Ok(self.handoffs.clone())
        }

        async fn intent_summary(&self, since: i64) -> Result<Vec<AssistantIntentSummary>, String> {
            if since <= 0 {
                return Err("invalid intent cutoff".to_owned());
            }
            Ok(self.summary.clone())
        }

        async fn resolve_handoff(
            &self,
            admin_user_id: i64,
            admin_username: &str,
            lead_id: i64,
            note: &str,
        ) -> Result<AssistantLead, ResolveHandoffError> {
            self.resolve_calls
                .lock()
                .expect("resolve call lock")
                .push(FixtureResolveCall {
                    admin_user_id,
                    admin_username: admin_username.to_owned(),
                    lead_id,
                    note: note.to_owned(),
                });
            self.resolve_result.clone().unwrap_or_else(|| {
                Err(ResolveHandoffError::Unavailable(
                    "unexpected resolve call".to_owned(),
                ))
            })
        }

        async fn record_admin_audit(&self, audit: AssistantAdminAudit) {
            self.audits.lock().expect("audit lock").push(audit);
        }
    }

    #[derive(Clone, Copy, Default)]
    enum FixtureRateLimit {
        #[default]
        Allowed,
        Rejected(u64),
        Failed,
    }

    struct FixtureAuth {
        rate_limit: FixtureRateLimit,
    }

    impl Default for FixtureAuth {
        fn default() -> Self {
            Self {
                rate_limit: FixtureRateLimit::Allowed,
            }
        }
    }

    #[async_trait]
    impl DashboardAuth for FixtureAuth {
        async fn check_critical_rate_limit(
            &self,
            _: &str,
        ) -> Result<CriticalRateLimitOutcome, AuthError> {
            match self.rate_limit {
                FixtureRateLimit::Allowed => Ok(CriticalRateLimitOutcome::Allowed),
                FixtureRateLimit::Rejected(retry_after_seconds) => {
                    Ok(CriticalRateLimitOutcome::Rejected {
                        retry_after_seconds,
                    })
                }
                FixtureRateLimit::Failed => Err(AuthError::new(AuthErrorKind::Internal)),
            }
        }

        async fn login(
            &self,
            _: LoginRequest,
            _: RequestMetadata,
        ) -> Result<LoginOutcome, AuthError> {
            panic!("unused")
        }

        async fn login_2fa(
            &self,
            _: TwoFactorLoginRequest,
            _: RequestMetadata,
        ) -> Result<AuthBundle, AuthError> {
            panic!("unused")
        }

        async fn refresh(
            &self,
            _: SecretString,
            _: Option<String>,
            _: RequestMetadata,
        ) -> Result<AuthBundle, AuthError> {
            panic!("unused")
        }

        async fn self_user(&self, token: SecretString) -> Result<DashboardUser, AuthError> {
            let role = match token.expose_secret() {
                "user-token" | "browser-session" => 1,
                "admin-token" | "admin-session" => ADMIN_ROLE,
                _ => return Err(AuthError::new(AuthErrorKind::Unauthorized)),
            };
            Ok(fixture_user(role))
        }

        async fn current_session(
            &self,
            token: SecretString,
        ) -> Result<DashboardSessionContext, AuthError> {
            if !matches!(token.expose_secret(), "browser-session" | "admin-session") {
                return Err(AuthError::new(AuthErrorKind::Unauthorized));
            }
            let role = if token.expose_secret() == "admin-session" {
                ADMIN_ROLE
            } else {
                1
            };
            Ok(DashboardSessionContext {
                user: fixture_user(role),
                session_id: "assistant-session".to_owned(),
                client_ip: "127.0.0.1".to_owned(),
                user_agent: "assistant-test".to_owned(),
            })
        }

        async fn logout(&self, _: LogoutRequest) -> Result<LogoutResult, AuthError> {
            panic!("unused")
        }

        async fn generate_personal_access_token(
            &self,
            _: SecretString,
        ) -> Result<String, AuthError> {
            panic!("unused")
        }
    }

    fn fixture_user(role: i64) -> DashboardUser {
        DashboardUser {
            id: if role >= ADMIN_ROLE { 10 } else { 7 },
            username: if role >= ADMIN_ROLE {
                "assistant-admin".to_owned()
            } else {
                "assistant-user".to_owned()
            },
            display_name: String::new(),
            role,
            status: 1,
            email: String::new(),
            github_id: String::new(),
            discord_id: String::new(),
            oidc_id: String::new(),
            wechat_id: String::new(),
            telegram_id: String::new(),
            group: "default".to_owned(),
            quota: 0,
            used_quota: 0,
            request_count: 0,
            aff_code: String::new(),
            aff_count: 0,
            aff_quota: 0,
            aff_history_quota: 0,
            inviter_id: 0,
            linux_do_id: String::new(),
            setting: "{}".to_owned(),
            stripe_customer: String::new(),
            sidebar_modules: json!({}),
            permissions: json!({}),
        }
    }

    fn fixture_lead() -> AssistantLead {
        AssistantLead {
            id: 3,
            user_id: 7,
            source: ASSISTANT_HANDOFF_SOURCE.to_owned(),
            intent: "human_support".to_owned(),
            message: "Need help".to_owned(),
            status: ASSISTANT_HANDOFF_PENDING.to_owned(),
            admin_user_id: 0,
            admin_note: String::new(),
            created_at: 1_700_000_000,
            resolved_at: 0,
        }
    }

    fn fixture_router(store: FixtureStore) -> Router {
        fixture_router_with_auth(store, FixtureAuth::default())
    }

    fn fixture_router_with_auth(store: FixtureStore, auth: FixtureAuth) -> Router {
        let pg = sqlx::postgres::PgPoolOptions::new()
            .connect_lazy("postgres://postgres@127.0.0.1:1/assistant")
            .expect("valid lazy PostgreSQL URL");
        assistant_read_router(
            AssistantReadState::new(pg, Arc::new(auth)).with_store(Arc::new(store)),
        )
    }

    async fn response_json(response: Response) -> Value {
        let bytes = to_bytes(response.into_body(), usize::MAX)
            .await
            .expect("response body");
        serde_json::from_slice(&bytes).expect("JSON response")
    }

    #[tokio::test]
    async fn assistant_status_should_match_go_settings_for_personal_token() {
        let store = FixtureStore {
            settings: AssistantSettingsView {
                enabled: false,
                model: "assistant-model".to_owned(),
                agent_loop_enabled: false,
                max_steps: 4,
                timeout_seconds: 30,
                cache_enabled: false,
                cache_ttl_minutes: 15,
            },
            ..FixtureStore::default()
        };
        let response = fixture_router(store)
            .oneshot(
                Request::get("/api/assistant/status")
                    .header(header::AUTHORIZATION, "Bearer user-token")
                    .body(Body::empty())
                    .expect("request"),
            )
            .await
            .expect("response");
        let status = response.status();
        let auth_version = response.headers().get("auth-version").cloned();
        let body = response_json(response).await;

        assert_eq!(
            (status, auth_version.as_ref(), body["data"].clone()),
            (
                StatusCode::OK,
                Some(&axum::http::HeaderValue::from_static(AUTH_VERSION)),
                json!({
                    "enabled": false,
                    "model": "assistant-model",
                    "funding": {"mode": "super_administrator"},
                    "developer_access_granted": false,
                    "agent": {
                        "enabled": false,
                        "max_steps": 4,
                        "timeout_seconds": 30,
                        "cache_enabled": false,
                        "cache_ttl_minutes": 15,
                    },
                }),
            )
        );
    }

    #[tokio::test]
    async fn self_handoff_should_return_latest_user_lead_for_personal_token() {
        let lead = fixture_lead();
        let response = fixture_router(FixtureStore {
            latest: Some(lead.clone()),
            ..FixtureStore::default()
        })
        .oneshot(
            Request::get("/api/assistant/handoffs/self")
                .header(header::AUTHORIZATION, "user-token")
                .body(Body::empty())
                .expect("request"),
        )
        .await
        .expect("response");
        let cache_control = response.headers().get(header::CACHE_CONTROL).cloned();
        let pragma = response.headers().get(header::PRAGMA).cloned();
        let expires = response.headers().get(header::EXPIRES).cloned();
        let body = response_json(response).await;

        assert_eq!(body["data"], json!(lead));
        assert_eq!(
            cache_control,
            Some(axum::http::HeaderValue::from_static(
                "no-store, no-cache, must-revalidate, private, max-age=0"
            ))
        );
        assert_eq!(
            pragma,
            Some(axum::http::HeaderValue::from_static("no-cache"))
        );
        assert_eq!(
            expires,
            Some(axum::http::HeaderValue::from_static("0"))
        );
    }

    #[tokio::test]
    async fn admin_handoffs_should_forward_resolved_filter_and_flatten_user_view() {
        let mut lead = fixture_lead();
        lead.status = ASSISTANT_HANDOFF_RESOLVED.to_owned();
        let view = AssistantLeadView {
            lead,
            username: "assistant-user".to_owned(),
            email: "assistant@example.com".to_owned(),
        };
        let response = fixture_router(FixtureStore {
            handoffs: vec![view.clone()],
            expected_handoff_status: ASSISTANT_HANDOFF_RESOLVED,
            ..FixtureStore::default()
        })
        .oneshot(
            Request::get("/api/assistant/admin/handoffs?status=resolved")
                .header(header::AUTHORIZATION, "Bearer admin-token")
                .body(Body::empty())
                .expect("request"),
        )
        .await
        .expect("response");
        let body = response_json(response).await;

        assert_eq!(body["data"], json!([view]));
    }

    #[tokio::test]
    async fn admin_intents_should_reject_out_of_range_days_after_admin_auth() {
        let response = fixture_router(FixtureStore::default())
            .oneshot(
                Request::get("/api/assistant/admin/intents?days=366")
                    .header(header::AUTHORIZATION, "Bearer admin-token")
                    .body(Body::empty())
                    .expect("request"),
            )
            .await
            .expect("response");
        let status = response.status();
        let body = response_json(response).await;

        assert_eq!(
            (status, body),
            (
                StatusCode::BAD_REQUEST,
                json!({
                    "success": false,
                    "code": "ASSISTANT_INTENT_DAYS_INVALID",
                    "message": "days must be between 1 and 365",
                }),
            )
        );
    }

    #[tokio::test]
    async fn admin_intents_should_return_go_ordered_summary_shape() {
        let summary = vec![
            AssistantIntentSummary {
                intent: "plan_purchase".to_owned(),
                count: 4,
            },
            AssistantIntentSummary {
                intent: "api_key".to_owned(),
                count: 2,
            },
        ];
        let response = fixture_router(FixtureStore {
            summary: summary.clone(),
            ..FixtureStore::default()
        })
        .oneshot(
            Request::get("/api/assistant/admin/intents?days=7")
                .header(header::AUTHORIZATION, "Bearer admin-token")
                .body(Body::empty())
                .expect("request"),
        )
        .await
        .expect("response");
        let body = response_json(response).await;

        assert_eq!(body["data"], json!(summary));
    }

    #[tokio::test]
    async fn admin_handoffs_should_reject_common_user_without_auth_version() {
        let response = fixture_router(FixtureStore::default())
            .oneshot(
                Request::get("/api/assistant/admin/handoffs")
                    .header(header::AUTHORIZATION, "Bearer user-token")
                    .body(Body::empty())
                    .expect("request"),
            )
            .await
            .expect("response");
        let status = response.status();
        let has_auth_version = response.headers().contains_key("auth-version");
        let body = response_json(response).await;

        assert_eq!(
            (status, has_auth_version, body["code"].clone()),
            (
                StatusCode::FORBIDDEN,
                false,
                json!("AUTH_INSUFFICIENT_PRIVILEGE"),
            )
        );
    }

    #[tokio::test]
    async fn admin_resolve_handoff_should_match_go_transaction_and_audit_contract() {
        let mut resolved = fixture_lead();
        resolved.status = ASSISTANT_HANDOFF_RESOLVED.to_owned();
        resolved.admin_user_id = 10;
        resolved.admin_note = "contacted user".to_owned();
        resolved.resolved_at = 1_700_000_100;
        let store = FixtureStore {
            resolve_result: Some(Ok(resolved.clone())),
            ..FixtureStore::default()
        };
        let resolve_calls = Arc::clone(&store.resolve_calls);
        let audits = Arc::clone(&store.audits);
        let response = fixture_router(store)
            .oneshot(
                Request::post("/api/assistant/admin/handoffs/3/resolve")
                    .header(header::AUTHORIZATION, "Bearer admin-session")
                    .extension(ClientIpKey("203.0.113.9".to_owned()))
                    .body(Body::from(r#"{"note":"  contacted user  "}"#))
                    .expect("request"),
            )
            .await
            .expect("response");
        let status = response.status();
        let auth_version = response.headers().get("auth-version").cloned();
        let body = response_json(response).await;

        assert_eq!(status, StatusCode::OK);
        assert_eq!(
            auth_version,
            Some(axum::http::HeaderValue::from_static(AUTH_VERSION))
        );
        assert_eq!(body["data"], json!(resolved));
        assert_eq!(
            *resolve_calls.lock().expect("resolve call lock"),
            vec![FixtureResolveCall {
                admin_user_id: 10,
                admin_username: "assistant-admin".to_owned(),
                lead_id: 3,
                note: "contacted user".to_owned(),
            }]
        );
        assert_eq!(
            *audits.lock().expect("audit lock"),
            vec![AssistantAdminAudit {
                actor_id: 10,
                actor_username: "assistant-admin".to_owned(),
                actor_role: ADMIN_ROLE,
                auth_method: "session",
                client_ip: "203.0.113.9".to_owned(),
                lead_id: "3".to_owned(),
                status: StatusCode::OK,
                success: true,
            }]
        );
    }

    #[tokio::test]
    async fn admin_resolve_handoff_should_accept_null_body_like_go_json_binding() {
        let mut resolved = fixture_lead();
        resolved.status = ASSISTANT_HANDOFF_RESOLVED.to_owned();
        let store = FixtureStore {
            resolve_result: Some(Ok(resolved)),
            ..FixtureStore::default()
        };
        let resolve_calls = Arc::clone(&store.resolve_calls);
        let response = fixture_router(store)
            .oneshot(
                Request::post("/api/assistant/admin/handoffs/3/resolve")
                    .header(header::AUTHORIZATION, "Bearer admin-token")
                    .body(Body::from("null"))
                    .expect("request"),
            )
            .await
            .expect("response");

        assert_eq!(response.status(), StatusCode::OK);
        assert_eq!(resolve_calls.lock().expect("resolve call lock")[0].note, "");
    }

    #[tokio::test]
    async fn admin_resolve_handoff_should_report_go_conflict_and_audit_failure() {
        let store = FixtureStore {
            resolve_result: Some(Err(ResolveHandoffError::AlreadyResolved)),
            ..FixtureStore::default()
        };
        let audits = Arc::clone(&store.audits);
        let response = fixture_router(store)
            .oneshot(
                Request::post("/api/assistant/admin/handoffs/3/resolve")
                    .header(header::AUTHORIZATION, "Bearer admin-token")
                    .body(Body::empty())
                    .expect("request"),
            )
            .await
            .expect("response");
        let status = response.status();
        let body = response_json(response).await;

        assert_eq!(status, StatusCode::CONFLICT);
        assert_eq!(body["code"], "ASSISTANT_HANDOFF_ALREADY_RESOLVED");
        let audit = audits.lock().expect("audit lock")[0].clone();
        assert_eq!(
            (audit.auth_method, audit.status, audit.success),
            ("access_token", StatusCode::CONFLICT, false)
        );
    }

    #[tokio::test]
    async fn admin_resolve_handoff_should_rate_limit_before_id_and_body_validation() {
        for (rate_limit, expected_status, expected_retry_after) in [
            (
                FixtureRateLimit::Rejected(37),
                StatusCode::TOO_MANY_REQUESTS,
                Some("37"),
            ),
            (
                FixtureRateLimit::Failed,
                StatusCode::INTERNAL_SERVER_ERROR,
                None,
            ),
        ] {
            let store = FixtureStore::default();
            let resolve_calls = Arc::clone(&store.resolve_calls);
            let audits = Arc::clone(&store.audits);
            let response = fixture_router_with_auth(store, FixtureAuth { rate_limit })
                .oneshot(
                    Request::post("/api/assistant/admin/handoffs/not-an-id/resolve")
                        .header(header::AUTHORIZATION, "Bearer admin-token")
                        .extension(ClientIpKey("198.51.100.8".to_owned()))
                        .body(Body::from("not-json"))
                        .expect("request"),
                )
                .await
                .expect("response");

            assert_eq!(response.status(), expected_status);
            assert_eq!(
                response
                    .headers()
                    .get(header::RETRY_AFTER)
                    .and_then(|value| value.to_str().ok()),
                expected_retry_after
            );
            assert_eq!(
                response.headers().get("auth-version"),
                Some(&axum::http::HeaderValue::from_static(AUTH_VERSION))
            );
            let bytes = to_bytes(response.into_body(), usize::MAX)
                .await
                .expect("response body");
            assert!(bytes.is_empty());
            assert!(resolve_calls.lock().expect("resolve call lock").is_empty());
            let audit = audits.lock().expect("audit lock")[0].clone();
            assert_eq!((audit.status, audit.success), (expected_status, false));
        }
    }

    #[test]
    fn assistant_settings_should_keep_go_defaults_for_invalid_options() {
        let settings = AssistantSettingsView::from_options(&HashMap::from([
            ("AssistantEnabled".to_owned(), "TRUE".to_owned()),
            ("AssistantModel".to_owned(), "  ".to_owned()),
            ("AssistantMaxSteps".to_owned(), "13".to_owned()),
            ("AssistantTimeoutSeconds".to_owned(), "4".to_owned()),
        ]));

        assert_eq!(
            settings,
            AssistantSettingsView {
                enabled: false,
                ..AssistantSettingsView::default()
            }
        );
    }

    #[test]
    fn access_denied_offer_payload_should_hide_plans_and_discounts() {
        let result = access_denied_offer_payload();

        assert_eq!(result["ok"], false);
        assert_eq!(result["developer_access_granted"], false);
        assert_eq!(result["read_only"], false);
        assert_eq!(result["checkout_available"], false);
        assert_eq!(result["payment_hidden"], true);
        assert_eq!(result["plans"], json!([]));
        assert_eq!(result["topup_discounts"], json!({}));
        assert!(
            result["error"]
                .as_str()
                .is_some_and(|error| error.contains("L1 access"))
        );
    }

    #[test]
    fn offer_payload_should_hide_payment_for_restricted_accounts() {
        let result = offer_payload(true, true, json!([{"plan": {"id": 1}}]), Map::new());

        assert_eq!(result["checkout_available"], false);
        assert_eq!(result["payment_hidden"], true);
        assert_eq!(result["topup_discounts"], json!({}));
    }

    #[test]
    fn parse_amount_discounts_should_fall_back_to_registered_payment_object() {
        let values = HashMap::from([(
            "payment_setting".to_owned(),
            r#"{"amount_discount":{"100":0.8,"invalid":"bad"}}"#.to_owned(),
        )]);

        assert_eq!(
            Value::Object(parse_amount_discounts(&values)),
            json!({"100": 0.8})
        );
    }

    #[test]
    fn linux_do_email_should_be_payment_restricted_case_insensitively() {
        assert!(is_linux_do_email(" Person@Linux.Do "));
    }
}
