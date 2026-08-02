//! Legacy-compatible authenticated profile routes.
//!
//! This module owns only self-service affiliation, preference, and profile
//! paths. Administrator CRUD, search, and management paths are exclusively
//! owned by [`crate::migration_routes::identity_admin`].

use async_trait::async_trait;
use axum::{
    Json, Router,
    body::to_bytes,
    extract::{Request, State},
    http::{HeaderMap, HeaderValue, StatusCode, header},
    response::{IntoResponse, Response},
    routing::{get, put},
};
use secrecy::SecretString;
use serde::{Deserialize, Serialize};
use serde_json::{Map, Value};
use sqlx::PgPool;
use std::sync::Arc;

use crate::auth::{AuthErrorKind, DashboardAuth};

const ROLE_ROOT: i64 = 100;

/// Authenticated identity supplied by the listener after token validation.
#[derive(Clone, Copy, Debug)]
pub struct ProfileIdentity {
    /// The authenticated user id.
    pub user_id: i64,
    /// The authenticated role, never read from request JSON.
    pub role: i64,
}

/// Failure class from the server-side dashboard-identity verifier.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum ProfileAuthError {
    /// The request did not carry a valid, live dashboard identity.
    Unauthorized,
    /// The verifier's durable session or user lookup failed.
    Internal,
}

/// Resolves a profile actor from credentials verified by the server.
///
/// Implementations must never read an identity from client-controlled headers.
#[async_trait]
pub trait ProfileIdentityResolver: Send + Sync {
    /// Validates the request credentials and returns the authenticated actor.
    async fn principal(&self, headers: &HeaderMap) -> Result<ProfileIdentity, ProfileAuthError>;
}

struct RejectingProfileIdentityResolver;

#[async_trait]
impl ProfileIdentityResolver for RejectingProfileIdentityResolver {
    async fn principal(&self, _: &HeaderMap) -> Result<ProfileIdentity, ProfileAuthError> {
        Err(ProfileAuthError::Unauthorized)
    }
}

/// Production adapter that delegates credential and session validation to the
/// shared dashboard-auth service.
#[derive(Clone)]
pub struct DashboardProfileIdentityResolver {
    auth: Arc<dyn DashboardAuth>,
}

impl DashboardProfileIdentityResolver {
    /// Creates an adapter over the listener's configured dashboard auth service.
    pub fn new(auth: Arc<dyn DashboardAuth>) -> Self {
        Self { auth }
    }
}

#[async_trait]
impl ProfileIdentityResolver for DashboardProfileIdentityResolver {
    async fn principal(&self, headers: &HeaderMap) -> Result<ProfileIdentity, ProfileAuthError> {
        let Some(token) = bearer(headers) else {
            return Err(ProfileAuthError::Unauthorized);
        };
        match self.auth.self_user(SecretString::from(token)).await {
            Ok(user) if user.id > 0 && user.status == 1 => Ok(ProfileIdentity {
                user_id: user.id,
                role: user.role,
            }),
            Ok(_) => Err(ProfileAuthError::Unauthorized),
            Err(error)
                if matches!(
                    error.kind,
                    AuthErrorKind::TokenExpired
                        | AuthErrorKind::SessionRevoked
                        | AuthErrorKind::Unauthorized
                ) =>
            {
                Err(ProfileAuthError::Unauthorized)
            }
            Err(_) => Err(ProfileAuthError::Internal),
        }
    }
}

/// PostgreSQL and Valkey dependencies used by the profile slice.
#[derive(Clone)]
pub struct ProfileState {
    pg: PgPool,
    valkey: redis::Client,
    identity: Arc<dyn ProfileIdentityResolver>,
}

impl ProfileState {
    /// Builds the state from the listener's shared PostgreSQL and Valkey clients.
    pub fn new(pg: PgPool, valkey: redis::Client) -> Self {
        Self {
            pg,
            valkey,
            identity: Arc::new(RejectingProfileIdentityResolver),
        }
    }

    /// Installs the listener-owned server-side identity verifier.
    #[must_use]
    pub fn with_identity_resolver(mut self, identity: Arc<dyn ProfileIdentityResolver>) -> Self {
        self.identity = identity;
        self
    }

    /// Installs the production adapter backed by the shared dashboard auth service.
    #[must_use]
    pub fn with_dashboard_auth(self, auth: Arc<dyn DashboardAuth>) -> Self {
        self.with_identity_resolver(Arc::new(DashboardProfileIdentityResolver::new(auth)))
    }
}

/// Self-service affiliation, preference, and profile routes.
pub fn router(state: ProfileState) -> Router {
    Router::new()
        .route("/api/user/aff", get(get_aff_code))
        .route("/api/user/setting", put(update_setting))
        .route("/api/user/self", put(update_self).delete(delete_self))
        .with_state(state)
}

async fn update_self(
    State(state): State<ProfileState>,
    request: Request,
) -> Result<Response, ProfileError> {
    let request_locale = locale(request.headers());
    let identity = authenticated(&state, request.headers()).await?;
    let mut request = request_object(request).await?;
    if request.contains_key("sidebar_modules") || request.contains_key("language") {
        return update_self_setting(&state, identity.user_id, &mut request, request_locale).await;
    }
    let username = request
        .get("username")
        .and_then(Value::as_str)
        .unwrap_or_default();
    let display_name = request
        .get("display_name")
        .and_then(Value::as_str)
        .unwrap_or("");
    if username.len() > 20 || display_name.len() > 20 {
        return Err(ProfileError::bad_request("invalid input"));
    }
    // Password rotation must be performed by the session-owning auth module.
    if request
        .get("password")
        .and_then(Value::as_str)
        .is_some_and(|password| !password.is_empty())
    {
        return Err(ProfileError::bad_request(
            "password rotation requires the authenticated session",
        ));
    }
    sqlx::query("UPDATE users SET username = COALESCE(NULLIF($1, ''), username), display_name = COALESCE(NULLIF($2, ''), display_name) WHERE id = $3 AND deleted_at IS NULL")
        .bind(username)
        .bind(display_name)
        .bind(identity.user_id)
        .execute(&state.pg)
        .await
        .map_err(|_| ProfileError::internal())?;
    clear_user_cache(&state, identity.user_id).await;
    Ok(update_success(request_locale))
}

async fn request_object(request: Request) -> Result<Map<String, Value>, ProfileError> {
    let bytes = to_bytes(request.into_body(), 1024 * 1024)
        .await
        .map_err(|_| ProfileError::bad_request("invalid parameters"))?;
    serde_json::from_slice(&bytes).map_err(|_| ProfileError::bad_request("invalid parameters"))
}

async fn update_self_setting(
    state: &ProfileState,
    user_id: i64,
    request: &mut Map<String, Value>,
    request_locale: LegacyLocale,
) -> Result<Response, ProfileError> {
    let existing_setting = sqlx::query_scalar::<_, Option<String>>(
        "SELECT setting FROM users WHERE id = $1 AND deleted_at IS NULL",
    )
    .bind(user_id)
    .fetch_optional(&state.pg)
    .await
    .map_err(|_| ProfileError::internal())?
    .flatten()
    .and_then(|raw| serde_json::from_str(&raw).ok());
    let mut setting: Map<String, Value> = existing_setting.unwrap_or_default();
    // The legacy handler gives sidebar preference precedence when both exist.
    let key = if request.contains_key("sidebar_modules") {
        "sidebar_modules"
    } else {
        "language"
    };
    if let Some(value) = request.remove(key).filter(Value::is_string) {
        setting.insert(key.to_owned(), value);
    }
    sqlx::query("UPDATE users SET setting = $1 WHERE id = $2 AND deleted_at IS NULL")
        .bind(serde_json::to_string(&setting).map_err(|_| ProfileError::internal())?)
        .bind(user_id)
        .execute(&state.pg)
        .await
        .map_err(|_| ProfileError::internal())?;
    clear_user_cache(state, user_id).await;
    Ok(update_success(request_locale))
}

async fn delete_self(
    State(state): State<ProfileState>,
    headers: HeaderMap,
) -> Result<Json<Success<()>>, ProfileError> {
    let identity = authenticated(&state, &headers).await?;
    let mut transaction = state
        .pg
        .begin()
        .await
        .map_err(|_| ProfileError::internal())?;
    let role = sqlx::query_scalar::<_, i64>(
        "SELECT role FROM users WHERE id = $1 AND deleted_at IS NULL FOR UPDATE",
    )
    .bind(identity.user_id)
    .fetch_optional(&mut *transaction)
    .await
    .map_err(|_| ProfileError::internal())?
    .ok_or_else(ProfileError::not_found)?;
    if role == ROLE_ROOT {
        return Err(ProfileError::forbidden("root user cannot be deleted"));
    }
    let version = sqlx::query_scalar::<_, i64>("UPDATE users SET deleted_at = NOW(), auth_version = auth_version + 1 WHERE id = $1 AND deleted_at IS NULL RETURNING auth_version")
        .bind(identity.user_id)
        .fetch_optional(&mut *transaction)
        .await
        .map_err(|_| ProfileError::internal())?
        .ok_or_else(ProfileError::not_found)?;
    sqlx::query("UPDATE user_sessions SET status = 'revoked', revoked_at = EXTRACT(EPOCH FROM NOW())::BIGINT, revoked_reason = 'self_delete' WHERE user_id = $1 AND status = 'active'")
        .bind(identity.user_id)
        .execute(&mut *transaction)
        .await
        .map_err(|_| ProfileError::internal())?;
    transaction
        .commit()
        .await
        .map_err(|_| ProfileError::internal())?;
    publish_auth_floor(&state, identity.user_id, version).await;
    Ok(success(None))
}

#[derive(Serialize)]
struct Success<T: Serialize> {
    success: bool,
    message: &'static str,
    #[serde(skip_serializing_if = "Option::is_none")]
    data: Option<T>,
}

fn success<T: Serialize>(data: Option<T>) -> Json<Success<T>> {
    Json(Success {
        success: true,
        message: "",
        data,
    })
}

#[derive(Debug)]
struct ProfileError {
    status: StatusCode,
    code: Option<&'static str>,
    message: &'static str,
}

impl ProfileError {
    const fn bad_request(message: &'static str) -> Self {
        Self {
            status: StatusCode::BAD_REQUEST,
            code: None,
            message,
        }
    }

    const fn forbidden(message: &'static str) -> Self {
        Self {
            status: StatusCode::FORBIDDEN,
            code: None,
            message,
        }
    }

    const fn not_found() -> Self {
        Self {
            status: StatusCode::NOT_FOUND,
            code: None,
            message: "user not found",
        }
    }

    fn unauthorized(request_locale: LegacyLocale) -> Self {
        Self {
            status: StatusCode::UNAUTHORIZED,
            code: Some("AUTH_UNAUTHORIZED"),
            message: request_locale.invalid_access_token(),
        }
    }

    const fn internal() -> Self {
        Self {
            status: StatusCode::INTERNAL_SERVER_ERROR,
            code: None,
            message: "identity profile operation failed",
        }
    }
}

impl IntoResponse for ProfileError {
    fn into_response(self) -> Response {
        let mut body = serde_json::Map::from_iter([
            ("success".to_owned(), Value::Bool(false)),
            ("message".to_owned(), Value::String(self.message.to_owned())),
        ]);
        if let Some(code) = self.code {
            body.insert("code".to_owned(), Value::String(code.to_owned()));
        }
        (self.status, Json(Value::Object(body))).into_response()
    }
}

async fn get_aff_code(
    State(state): State<ProfileState>,
    headers: HeaderMap,
) -> Result<Json<Success<String>>, ProfileError> {
    let identity = authenticated(&state, &headers).await?;
    let existing =
        sqlx::query_scalar::<_, Option<String>>("SELECT aff_code FROM users WHERE id = $1")
            .bind(identity.user_id)
            .fetch_optional(&state.pg)
            .await
            .map_err(|_| ProfileError::internal())?
            .flatten()
            .filter(|code| !code.is_empty());
    if let Some(code) = existing {
        return Ok(success(Some(code)));
    }
    let generated = format!("{:08x}", rand::random::<u32>());
    let assigned = sqlx::query_scalar::<_, String>("UPDATE users SET aff_code = $1 WHERE id = $2 AND (aff_code IS NULL OR aff_code = '') RETURNING aff_code")
        .bind(&generated)
        .bind(identity.user_id)
        .fetch_optional(&state.pg)
        .await
        .map_err(|_| ProfileError::internal())?;
    let code = match assigned {
        Some(code) => code,
        None => sqlx::query_scalar::<_, Option<String>>("SELECT aff_code FROM users WHERE id = $1")
            .bind(identity.user_id)
            .fetch_optional(&state.pg)
            .await
            .map_err(|_| ProfileError::internal())?
            .flatten()
            .filter(|code| !code.is_empty())
            .ok_or_else(ProfileError::not_found)?,
    };
    clear_user_cache(&state, identity.user_id).await;
    Ok(success(Some(code)))
}

async fn update_setting(
    State(state): State<ProfileState>,
    request: Request,
) -> Result<Response, ProfileError> {
    let request_locale = locale(request.headers());
    let identity = authenticated(&state, request.headers()).await?;
    let request: UserSettingRequest =
        serde_json::from_value(Value::Object(request_object(request).await?))
            .map_err(|_| ProfileError::bad_request("invalid parameters"))?;
    validate_user_setting(&request)?;
    update_notification_setting(&state, identity, request).await?;
    Ok(update_success(request_locale))
}

#[derive(Deserialize)]
struct UserSettingRequest {
    notify_type: String,
    quota_warning_threshold: f64,
    #[serde(default)]
    webhook_url: String,
    #[serde(default)]
    webhook_secret: String,
    #[serde(default)]
    notification_email: String,
    #[serde(default)]
    bark_url: String,
    #[serde(default)]
    gotify_url: String,
    #[serde(default)]
    gotify_token: String,
    #[serde(default)]
    gotify_priority: i64,
    upstream_model_update_notify_enabled: Option<bool>,
    #[serde(default)]
    accept_unset_model_ratio_model: bool,
    #[serde(default)]
    record_ip_log: bool,
}

fn validate_user_setting(request: &UserSettingRequest) -> Result<(), ProfileError> {
    if !matches!(
        request.notify_type.as_str(),
        "email" | "webhook" | "bark" | "gotify"
    ) {
        return Err(ProfileError::bad_request("invalid notification type"));
    }
    if !request.quota_warning_threshold.is_finite() || request.quota_warning_threshold <= 0.0 {
        return Err(ProfileError::bad_request(
            "quota warning threshold must be greater than zero",
        ));
    }
    match request.notify_type.as_str() {
        "email"
            if !request.notification_email.is_empty()
                && !request.notification_email.contains('@') =>
        {
            Err(ProfileError::bad_request("invalid notification email"))
        }
        "webhook" => validate_http_url(&request.webhook_url, "webhook URL"),
        "bark" => validate_http_url(&request.bark_url, "Bark URL"),
        "gotify" => {
            validate_http_url(&request.gotify_url, "Gotify URL")?;
            if request.gotify_token.is_empty() {
                return Err(ProfileError::bad_request("Gotify token is required"));
            }
            Ok(())
        }
        _ => Ok(()),
    }
}

fn validate_http_url(value: &str, label: &'static str) -> Result<(), ProfileError> {
    let Some(authority_and_path) = value
        .strip_prefix("https://")
        .or_else(|| value.strip_prefix("http://"))
    else {
        return Err(ProfileError::bad_request(label));
    };
    let host = authority_and_path.split('/').next().unwrap_or_default();
    if !host.is_empty() && !value.chars().any(char::is_whitespace) {
        Ok(())
    } else {
        Err(ProfileError::bad_request(label))
    }
}

async fn update_notification_setting(
    state: &ProfileState,
    identity: ProfileIdentity,
    request: UserSettingRequest,
) -> Result<(), ProfileError> {
    let raw = sqlx::query_scalar::<_, Option<String>>(
        "SELECT setting FROM users WHERE id = $1 AND deleted_at IS NULL FOR UPDATE",
    )
    .bind(identity.user_id)
    .fetch_optional(&state.pg)
    .await
    .map_err(|_| ProfileError::internal())?
    .flatten()
    .unwrap_or_default();
    let mut setting = serde_json::from_str::<Map<String, Value>>(&raw).unwrap_or_default();
    setting.insert(
        "notify_type".to_owned(),
        Value::String(request.notify_type.clone()),
    );
    setting.insert(
        "quota_warning_threshold".to_owned(),
        Value::from(request.quota_warning_threshold),
    );
    setting.insert(
        "accept_unset_model_ratio_model".to_owned(),
        Value::Bool(request.accept_unset_model_ratio_model),
    );
    setting.insert(
        "record_ip_log".to_owned(),
        Value::Bool(request.record_ip_log),
    );
    if identity.role >= 10 {
        if let Some(enabled) = request.upstream_model_update_notify_enabled {
            setting.insert(
                "upstream_model_update_notify_enabled".to_owned(),
                Value::Bool(enabled),
            );
        }
    }
    match request.notify_type.as_str() {
        "email" => insert_if_nonempty(
            &mut setting,
            "notification_email",
            request.notification_email,
        ),
        "webhook" => {
            insert_if_nonempty(&mut setting, "webhook_url", request.webhook_url);
            insert_if_nonempty(&mut setting, "webhook_secret", request.webhook_secret);
        }
        "bark" => insert_if_nonempty(&mut setting, "bark_url", request.bark_url),
        "gotify" => {
            insert_if_nonempty(&mut setting, "gotify_url", request.gotify_url);
            insert_if_nonempty(&mut setting, "gotify_token", request.gotify_token);
            setting.insert(
                "gotify_priority".to_owned(),
                Value::from(request.gotify_priority.clamp(0, 10)),
            );
        }
        _ => return Err(ProfileError::bad_request("invalid notification type")),
    }
    let updated = sqlx::query("UPDATE users SET setting = $1 WHERE id = $2 AND deleted_at IS NULL")
        .bind(serde_json::to_string(&setting).map_err(|_| ProfileError::internal())?)
        .bind(identity.user_id)
        .execute(&state.pg)
        .await
        .map_err(|_| ProfileError::internal())?;
    if updated.rows_affected() != 1 {
        return Err(ProfileError::not_found());
    }
    clear_user_cache(state, identity.user_id).await;
    Ok(())
}

fn insert_if_nonempty(setting: &mut Map<String, Value>, key: &str, value: String) {
    if !value.is_empty() {
        setting.insert(key.to_owned(), Value::String(value));
    }
}

async fn publish_auth_floor(state: &ProfileState, user_id: i64, version: i64) {
    let Ok(mut connection) = state.valkey.get_multiplexed_async_connection().await else {
        tracing::warn!(
            user_id,
            "identity profile Valkey unavailable after durable deletion"
        );
        return;
    };
    if redis::pipe()
        .atomic()
        .cmd("SET")
        .arg(format!("auth:user:version:{user_id}"))
        .arg(version)
        .cmd("DEL")
        .arg(format!("auth:user:fence:{user_id}"))
        .cmd("DEL")
        .arg(format!("user:{user_id}"))
        .query_async::<()>(&mut connection)
        .await
        .is_err()
    {
        tracing::warn!(
            user_id,
            "identity profile Valkey invalidation failed after durable deletion"
        );
    }
}

async fn clear_user_cache(state: &ProfileState, user_id: i64) {
    let Ok(mut connection) = state.valkey.get_multiplexed_async_connection().await else {
        tracing::warn!(
            user_id,
            "identity profile Valkey unavailable after durable update"
        );
        return;
    };
    if redis::cmd("DEL")
        .arg(format!("user:{user_id}"))
        .query_async::<()>(&mut connection)
        .await
        .is_err()
    {
        tracing::warn!(
            user_id,
            "identity profile Valkey invalidation failed after durable update"
        );
    }
}

async fn authenticated(
    state: &ProfileState,
    headers: &HeaderMap,
) -> Result<ProfileIdentity, ProfileError> {
    state
        .identity
        .principal(headers)
        .await
        .map_err(|error| match error {
            ProfileAuthError::Unauthorized => ProfileError::unauthorized(locale(headers)),
            ProfileAuthError::Internal => ProfileError::internal(),
        })
}

fn bearer(headers: &HeaderMap) -> Option<String> {
    let raw = headers.get(header::AUTHORIZATION)?.to_str().ok()?.trim();
    let mut parts = raw.split_ascii_whitespace();
    let scheme = parts.next()?;
    let token = parts.next()?;
    (scheme.eq_ignore_ascii_case("bearer") && parts.next().is_none() && !token.is_empty())
        .then(|| token.to_owned())
}

#[derive(Clone, Copy)]
enum LegacyLocale {
    En,
    ZhCn,
    ZhTw,
}

impl LegacyLocale {
    fn invalid_access_token(self) -> &'static str {
        match self {
            Self::En => "Unauthorized, invalid access token",
            Self::ZhCn => "无权进行此操作，access token 无效",
            Self::ZhTw => "無權進行此操作，access token 無效",
        }
    }

    fn update_success(self) -> &'static str {
        match self {
            Self::En => "Update successful",
            Self::ZhCn | Self::ZhTw => "更新成功",
        }
    }
}

fn locale(headers: &HeaderMap) -> LegacyLocale {
    let language = headers
        .get(header::ACCEPT_LANGUAGE)
        .and_then(|value| value.to_str().ok())
        .and_then(|value| value.split(',').next())
        .map(|value| {
            value
                .split(';')
                .next()
                .unwrap_or("")
                .trim()
                .to_ascii_lowercase()
        })
        .unwrap_or_default();
    if language.starts_with("zh-tw") {
        LegacyLocale::ZhTw
    } else if language.starts_with("zh") {
        LegacyLocale::ZhCn
    } else {
        LegacyLocale::En
    }
}

fn update_success(request_locale: LegacyLocale) -> Response {
    let mut response = Json(serde_json::json!({
        "success": true,
        "message": request_locale.update_success(),
        "data": null,
    }))
    .into_response();
    response.headers_mut().insert(
        header::CACHE_CONTROL,
        HeaderValue::from_static("no-store, no-cache, must-revalidate, private, max-age=0"),
    );
    response
}

#[cfg(test)]
mod tests {
    use serde_json::{Map, Value};

    #[test]
    fn self_setting_keeps_sidebar_precedence_when_both_legacy_keys_arrive() {
        let request = Map::from_iter([
            ("language".to_owned(), Value::String("en".to_owned())),
            (
                "sidebar_modules".to_owned(),
                Value::String("{\"chat\":true}".to_owned()),
            ),
        ]);
        let key = if request.contains_key("sidebar_modules") {
            "sidebar_modules"
        } else {
            "language"
        };
        assert_eq!(key, "sidebar_modules");
    }
}
