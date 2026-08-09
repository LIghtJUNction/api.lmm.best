//! Legacy-compatible identity catalogue routes.
//!
//! This slice owns the small authenticated catalogue used by the console:
//! usable groups, the models visible through those groups, and regeneration of
//! the dashboard personal access token.  It intentionally delegates token
//! issuance to the shared [`DashboardAuth`] implementation so session and
//! token semantics stay identical to the login subsystem.

use std::{collections::BTreeMap, sync::Arc};

use axum::{
    Json, Router,
    extract::{Query, State},
    http::{HeaderMap, StatusCode, header},
    response::{IntoResponse, Response},
    routing::get,
};
use secrecy::SecretString;
use serde::{Deserialize, Serialize};
use serde_json::{Map, Number, Value};
use sqlx::PgPool;

use crate::auth::{AuthErrorKind, DashboardAuth, DashboardUser};

const DEFAULT_USABLE_GROUPS: &[(&str, &str)] = &[("default", "默认分组"), ("vip", "vip分组")];
const DEFAULT_GROUP_RATIOS: &[(&str, f64)] = &[("default", 1.0), ("vip", 1.0), ("svip", 1.0)];

/// Listener dependencies for the identity-catalogue route family.
#[derive(Clone)]
pub struct IdentityCatalogState {
    pg: PgPool,
    auth: Arc<dyn DashboardAuth>,
}

impl IdentityCatalogState {
    /// Uses the same PostgreSQL pool and dashboard-auth service as the rest of
    /// the listener.  The `DashboardAuth` service remains the sole authority
    /// for session validation, status, roles, and token generation.
    #[must_use]
    pub fn new(pg: PgPool, auth: Arc<dyn DashboardAuth>) -> Self {
        Self { pg, auth }
    }
}

/// Routes retained from `controller/group.go` and `controller/user.go`.
pub fn router(state: IdentityCatalogState) -> Router {
    public_routes()
        .merge(protected_read_routes())
        .route("/api/user/token", get(generate_access_token))
        .with_state(state)
}

/// Mounts only the anonymous catalogue endpoint on the normal listener.
///
/// The protected group/model reads and personal-token write remain in the
/// isolated candidate surface until their own listener differential is
/// complete.  Keeping this slice explicit prevents a public read migration
/// from accidentally exposing the token-generation route.
pub fn public_router(state: IdentityCatalogState) -> Router {
    public_routes().with_state(state)
}

/// Mounts the authenticated group/model reads without exposing token
/// generation.  The normal listener owns this read slice only after the
/// shared dashboard-auth service accepts the request.
pub fn protected_read_router(state: IdentityCatalogState) -> Router {
    protected_read_routes().with_state(state)
}

fn public_routes() -> Router<IdentityCatalogState> {
    // This legacy endpoint is deliberately public. In Gin it reads the absent
    // identity as user 0 and returns the default usable groups.
    Router::new().route("/api/user/groups", get(get_public_groups))
}

fn protected_read_routes() -> Router<IdentityCatalogState> {
    Router::new()
        .route("/api/user/self/groups", get(get_self_groups))
        .route("/api/user/models", get(get_user_models))
}

async fn get_public_groups(
    State(state): State<IdentityCatalogState>,
) -> Result<Json<LegacySuccess<BTreeMap<String, GroupView>>>, CatalogError> {
    Ok(success(Some(groups_for(&state.pg, "").await?)))
}

async fn get_self_groups(
    State(state): State<IdentityCatalogState>,
    headers: HeaderMap,
) -> Result<Json<LegacySuccess<BTreeMap<String, GroupView>>>, CatalogError> {
    let user = authenticated(&state, &headers).await?;
    Ok(success(Some(groups_for(&state.pg, &user.group).await?)))
}

#[derive(Deserialize)]
struct ModelsQuery {
    #[serde(default)]
    group: String,
}

async fn get_user_models(
    State(state): State<IdentityCatalogState>,
    headers: HeaderMap,
    Query(query): Query<ModelsQuery>,
) -> Result<Json<LegacySuccess<Vec<String>>>, CatalogError> {
    let user = authenticated(&state, &headers).await?;
    let config = group_config(&state.pg).await?;
    let usable = usable_groups(&config, &user.group);
    let groups = match query.group.as_str() {
        "" => usable.keys().cloned().collect::<Vec<_>>(),
        "auto" if usable.contains_key("auto") => auto_groups(&config, &usable),
        requested if usable.contains_key(requested) => vec![requested.to_owned()],
        _ => Vec::new(),
    };
    if groups.is_empty() {
        return Ok(success(Some(Vec::new())));
    }
    // Legacy calls GetGroupEnabledModels for every allowed group and removes
    // duplicates while retaining the first occurrence. In particular, an
    // `auto` request must keep the configured AutoGroups traversal order.
    let mut seen = std::collections::BTreeSet::new();
    let mut models = Vec::new();
    for group in groups {
        let group_models = sqlx::query_scalar::<_, String>(
            r#"SELECT DISTINCT model FROM abilities
               WHERE "group" = $1 AND enabled = TRUE"#,
        )
        .bind(group)
        .fetch_all(&state.pg)
        .await
        .map_err(|_| CatalogError::internal())?;
        for model in group_models {
            if seen.insert(model.clone()) {
                models.push(model);
            }
        }
    }
    Ok(success(Some(models)))
}

async fn generate_access_token(
    State(state): State<IdentityCatalogState>,
    headers: HeaderMap,
) -> Result<Json<LegacySuccess<String>>, CatalogError> {
    let access_token =
        credential(&headers).ok_or_else(|| CatalogError::unauthorized(locale(&headers)))?;
    // The Go route is inside `UserAuth`, so enforce its role/status policy
    // before delegating the durable update to the auth service.
    authenticated(&state, &headers).await?;
    // `generate_personal_access_token` verifies the same bearer session and
    // generates the 29..=32-character legacy base64 token atomically.  Do not
    // reimplement this here: it also owns duplicate detection and user-cache
    // invalidation.
    let token = state
        .auth
        .generate_personal_access_token(SecretString::from(access_token))
        .await
        .map_err(|error| CatalogError::from_auth(error, locale(&headers)))?;
    Ok(success(Some(token)))
}

async fn authenticated(
    state: &IdentityCatalogState,
    headers: &HeaderMap,
) -> Result<DashboardUser, CatalogError> {
    let token = credential(headers).ok_or_else(|| CatalogError::unauthorized(locale(headers)))?;
    let user = state
        .auth
        .self_user(SecretString::from(token))
        .await
        .map_err(|error| CatalogError::from_auth(error, locale(headers)))?;
    // This is deliberately server-derived, not a client-supplied role or
    // status. Keep `middleware.UserAuth`'s validation order exactly.
    if user.status != 1 {
        return Err(CatalogError::user_disabled(locale(headers)));
    }
    if user.role < 1 {
        return Err(CatalogError::insufficient_privilege(locale(headers)));
    }
    if user.id <= 0 || user.username.trim().is_empty() || !matches!(user.role, 0 | 1 | 10 | 100) {
        return Err(CatalogError::invalid_user(locale(headers)));
    }
    Ok(user)
}

#[derive(Clone, Debug, Serialize)]
struct GroupView {
    ratio: Value,
    desc: String,
}

#[derive(Default)]
struct GroupConfig {
    usable: BTreeMap<String, String>,
    ratios: BTreeMap<String, f64>,
    group_ratios: BTreeMap<String, BTreeMap<String, f64>>,
    special: BTreeMap<String, BTreeMap<String, String>>,
    auto: Vec<String>,
}

async fn group_config(pg: &PgPool) -> Result<GroupConfig, CatalogError> {
    let rows =
        sqlx::query_as::<_, (String, String)>("SELECT key, value FROM options WHERE key = ANY($1)")
            .bind(vec![
                "UserUsableGroups",
                "GroupRatio",
                "GroupGroupRatio",
                "group_ratio_setting.group_special_usable_group",
                "group_ratio_setting",
                "AutoGroups",
            ])
            .fetch_all(pg)
            .await
            .map_err(|_| CatalogError::internal())?;
    let values = rows.into_iter().collect::<BTreeMap<_, _>>();
    let usable = string_map(values.get("UserUsableGroups")).unwrap_or_else(|| {
        DEFAULT_USABLE_GROUPS
            .iter()
            .map(|(k, v)| ((*k).to_owned(), (*v).to_owned()))
            .collect()
    });
    let ratios = number_map(values.get("GroupRatio")).unwrap_or_else(|| {
        DEFAULT_GROUP_RATIOS
            .iter()
            .map(|(k, v)| ((*k).to_owned(), *v))
            .collect()
    });
    let group_ratios = nested_number_map(values.get("GroupGroupRatio")).unwrap_or_default();
    let special = nested_string_map(values.get("group_ratio_setting.group_special_usable_group"))
        .or_else(|| special_from_legacy_setting(values.get("group_ratio_setting")))
        .unwrap_or_default();
    Ok(GroupConfig {
        usable,
        ratios,
        group_ratios,
        special,
        auto: string_list(values.get("AutoGroups")),
    })
}

async fn groups_for(
    pg: &PgPool,
    user_group: &str,
) -> Result<BTreeMap<String, GroupView>, CatalogError> {
    let config = group_config(pg).await?;
    let usable = usable_groups(&config, user_group);
    let mut result = BTreeMap::new();
    for (group, ratio) in &config.ratios {
        if let Some(desc) = usable.get(group) {
            result.insert(
                group.clone(),
                GroupView {
                    ratio: legacy_ratio_value(
                        config
                            .group_ratios
                            .get(user_group)
                            .and_then(|overrides| overrides.get(group))
                            .copied()
                            .unwrap_or(*ratio),
                    ),
                    desc: desc.clone(),
                },
            );
        }
    }
    if usable.contains_key("auto") {
        result.insert(
            "auto".to_owned(),
            GroupView {
                ratio: Value::String("自动".to_owned()),
                // Legacy reads the configured description, not a special
                // override, for the synthetic auto entry.
                desc: config
                    .usable
                    .get("auto")
                    .cloned()
                    .unwrap_or_else(|| "auto".to_owned()),
            },
        );
    }
    Ok(result)
}

/// Go's `encoding/json` emits an integral `float64` as an integer literal
/// (`1`), while `serde_json` otherwise preserves the Rust-side `1.0` spelling.
/// Keep the wire representation identical without rounding non-integral
/// pricing ratios such as `0.97`.
fn legacy_ratio_value(ratio: f64) -> Value {
    if ratio.is_finite()
        && ratio.fract() == 0.0
        && ratio >= i64::MIN as f64
        && ratio <= i64::MAX as f64
    {
        return Value::Number(Number::from(ratio as i64));
    }
    Number::from_f64(ratio)
        .map(Value::Number)
        .unwrap_or(Value::Null)
}

fn usable_groups(config: &GroupConfig, user_group: &str) -> BTreeMap<String, String> {
    let mut usable = config.usable.clone();
    if let Some(overrides) = config.special.get(user_group) {
        for (group, description) in overrides {
            if let Some(group) = group.strip_prefix("-:") {
                usable.remove(group);
            } else if let Some(group) = group.strip_prefix("+:") {
                usable.insert(group.to_owned(), description.clone());
            } else {
                usable.insert(group.clone(), description.clone());
            }
        }
    }
    if !user_group.is_empty() {
        usable
            .entry(user_group.to_owned())
            .or_insert_with(|| "用户分组".to_owned());
    }
    usable
}

fn auto_groups(config: &GroupConfig, usable: &BTreeMap<String, String>) -> Vec<String> {
    config
        .auto
        .iter()
        .filter(|group| usable.contains_key(*group))
        .cloned()
        .collect()
}

fn string_map(raw: Option<&String>) -> Option<BTreeMap<String, String>> {
    serde_json::from_str(raw?).ok()
}

fn number_map(raw: Option<&String>) -> Option<BTreeMap<String, f64>> {
    serde_json::from_str(raw?).ok()
}

fn nested_string_map(raw: Option<&String>) -> Option<BTreeMap<String, BTreeMap<String, String>>> {
    serde_json::from_str(raw?).ok()
}

fn nested_number_map(raw: Option<&String>) -> Option<BTreeMap<String, BTreeMap<String, f64>>> {
    serde_json::from_str(raw?).ok()
}

fn string_list(raw: Option<&String>) -> Vec<String> {
    raw.and_then(|raw| serde_json::from_str(raw).ok())
        .unwrap_or_default()
}

fn special_from_legacy_setting(
    raw: Option<&String>,
) -> Option<BTreeMap<String, BTreeMap<String, String>>> {
    let value = serde_json::from_str::<Value>(raw?).ok()?;
    value
        .get("group_special_usable_group")
        .and_then(|value| serde_json::from_value(value.clone()).ok())
}

#[derive(Serialize)]
struct LegacySuccess<T: Serialize> {
    success: bool,
    message: &'static str,
    data: Option<T>,
}

fn success<T: Serialize>(data: Option<T>) -> Json<LegacySuccess<T>> {
    Json(LegacySuccess {
        success: true,
        message: "",
        data,
    })
}

#[derive(Debug)]
struct CatalogError {
    status: StatusCode,
    code: Option<&'static str>,
    message: String,
}

impl CatalogError {
    fn unauthorized(locale: Locale) -> Self {
        Self {
            status: StatusCode::UNAUTHORIZED,
            code: Some("AUTH_UNAUTHORIZED"),
            message: locale.invalid_access_token().to_owned(),
        }
    }

    fn user_disabled(locale: Locale) -> Self {
        Self {
            status: StatusCode::UNAUTHORIZED,
            code: Some("AUTH_USER_DISABLED"),
            message: locale.user_banned().to_owned(),
        }
    }

    fn insufficient_privilege(locale: Locale) -> Self {
        Self {
            status: StatusCode::FORBIDDEN,
            code: Some("AUTH_INSUFFICIENT_PRIVILEGE"),
            message: locale.insufficient_privilege().to_owned(),
        }
    }

    fn invalid_user(locale: Locale) -> Self {
        Self {
            status: StatusCode::UNAUTHORIZED,
            code: Some("AUTH_USER_INVALID"),
            message: locale.invalid_user_info().to_owned(),
        }
    }

    fn internal() -> Self {
        Self {
            status: StatusCode::INTERNAL_SERVER_ERROR,
            code: None,
            message: "identity catalogue operation failed".to_owned(),
        }
    }

    fn internal_auth(locale: Locale) -> Self {
        Self {
            status: StatusCode::INTERNAL_SERVER_ERROR,
            code: Some("AUTH_INTERNAL_ERROR"),
            message: locale.database_error().to_owned(),
        }
    }

    fn legacy_token_write_error(message: String) -> Self {
        Self {
            // `controller.GenerateAccessToken` calls `common.ApiError`, whose
            // JSON helper retains Gin's default 200 status while exposing the
            // failed UPDATE error.  This exceptional legacy contract belongs
            // only to the personal-token write path, never generic auth.
            status: StatusCode::OK,
            code: None,
            message,
        }
    }

    fn not_logged_in(locale: Locale, code: &'static str) -> Self {
        Self {
            status: StatusCode::UNAUTHORIZED,
            code: Some(code),
            message: locale.not_logged_in().to_owned(),
        }
    }

    fn from_auth(error: crate::auth::AuthError, locale: Locale) -> Self {
        if error.kind == AuthErrorKind::Internal
            && let Some(message) = error.legacy_response_message()
        {
            return Self::legacy_token_write_error(message.to_owned());
        }
        match error.kind {
            AuthErrorKind::TokenExpired => Self::not_logged_in(locale, "AUTH_TOKEN_EXPIRED"),
            AuthErrorKind::SessionRevoked => Self::not_logged_in(locale, "AUTH_SESSION_REVOKED"),
            AuthErrorKind::Unauthorized => Self::unauthorized(locale),
            _ => Self::internal_auth(locale),
        }
    }
}

impl IntoResponse for CatalogError {
    fn into_response(self) -> Response {
        let mut body = Map::from_iter([
            ("success".to_owned(), Value::Bool(false)),
            ("message".to_owned(), Value::String(self.message)),
        ]);
        if let Some(code) = self.code {
            body.insert("code".to_owned(), Value::String(code.to_owned()));
        }
        (self.status, Json(Value::Object(body))).into_response()
    }
}

fn credential(headers: &HeaderMap) -> Option<String> {
    let raw = headers.get(header::AUTHORIZATION)?.to_str().ok()?.trim();
    let mut parts = raw.split_ascii_whitespace();
    let first = parts.next()?;
    let second = parts.next();
    if parts.next().is_some() {
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

#[derive(Clone, Copy)]
enum Locale {
    En,
    ZhCn,
    ZhTw,
}

impl Locale {
    fn invalid_access_token(self) -> &'static str {
        match self {
            Self::En => "Unauthorized, invalid access token",
            Self::ZhCn => "无权进行此操作，access token 无效",
            Self::ZhTw => "無權進行此操作，access token 無效",
        }
    }

    fn not_logged_in(self) -> &'static str {
        match self {
            Self::En => "Unauthorized, not logged in and no access token provided",
            Self::ZhCn => "无权进行此操作，未登录且未提供 access token",
            Self::ZhTw => "無權進行此操作，未登入且未提供 access token",
        }
    }

    fn database_error(self) -> &'static str {
        match self {
            Self::En => "Database error, please contact the administrator",
            Self::ZhCn => "数据库出错，请联系管理员",
            Self::ZhTw => "資料庫出錯，請聯繫管理員",
        }
    }

    fn user_banned(self) -> &'static str {
        match self {
            Self::En => "User has been banned",
            Self::ZhCn => "用户已被封禁",
            Self::ZhTw => "使用者已被封禁",
        }
    }

    fn insufficient_privilege(self) -> &'static str {
        match self {
            Self::En => "Unauthorized, insufficient privileges",
            Self::ZhCn => "无权进行此操作，权限不足",
            Self::ZhTw => "無權進行此操作，權限不足",
        }
    }

    fn invalid_user_info(self) -> &'static str {
        match self {
            Self::En => "Unauthorized, invalid user info",
            Self::ZhCn => "无权进行此操作，用户信息无效",
            Self::ZhTw => "無權進行此操作，使用者資訊無效",
        }
    }
}

fn locale(headers: &HeaderMap) -> Locale {
    let language = headers
        .get(header::ACCEPT_LANGUAGE)
        .and_then(|value| value.to_str().ok())
        .and_then(|value| value.split(',').next())
        .and_then(|value| value.split(';').next())
        .unwrap_or_default()
        .trim()
        .to_ascii_lowercase();
    if language.starts_with("zh-tw") {
        Locale::ZhTw
    } else if language.starts_with("zh") {
        Locale::ZhCn
    } else {
        Locale::En
    }
}

#[cfg(test)]
mod tests {
    use super::{
        IdentityCatalogState, legacy_ratio_value, protected_read_router, public_router, router,
    };
    use async_trait::async_trait;
    use axum::{
        body::to_bytes,
        http::{Request, StatusCode},
    };
    use secrecy::SecretString;
    use sqlx::postgres::PgPoolOptions;
    use tower::ServiceExt;

    use crate::auth::{
        AuthBundle, AuthError, AuthErrorKind, CriticalRateLimitOutcome, DashboardAuth,
        DashboardUser, LoginOutcome, LoginRequest, LogoutRequest, LogoutResult, RequestMetadata,
        TwoFactorLoginRequest,
    };

    struct RejectingAuth;

    struct IssuingAuth;

    #[async_trait]
    impl DashboardAuth for RejectingAuth {
        async fn check_critical_rate_limit(
            &self,
            _: &str,
        ) -> Result<CriticalRateLimitOutcome, AuthError> {
            Ok(CriticalRateLimitOutcome::Allowed)
        }

        async fn login(
            &self,
            _: LoginRequest,
            _: RequestMetadata,
        ) -> Result<LoginOutcome, AuthError> {
            Err(AuthError::new(AuthErrorKind::Unauthorized))
        }

        async fn login_2fa(
            &self,
            _: TwoFactorLoginRequest,
            _: RequestMetadata,
        ) -> Result<AuthBundle, AuthError> {
            Err(AuthError::new(AuthErrorKind::Unauthorized))
        }

        async fn refresh(
            &self,
            _: SecretString,
            _: Option<String>,
            _: RequestMetadata,
        ) -> Result<AuthBundle, AuthError> {
            Err(AuthError::new(AuthErrorKind::Unauthorized))
        }

        async fn self_user(&self, _: SecretString) -> Result<DashboardUser, AuthError> {
            Err(AuthError::new(AuthErrorKind::Unauthorized))
        }

        async fn logout(&self, _: LogoutRequest) -> Result<LogoutResult, AuthError> {
            Err(AuthError::new(AuthErrorKind::Unauthorized))
        }

        async fn generate_personal_access_token(
            &self,
            _: SecretString,
        ) -> Result<String, AuthError> {
            Err(AuthError::new(AuthErrorKind::Unauthorized))
        }
    }

    struct FailedTokenWriteAuth;

    #[async_trait]
    impl DashboardAuth for FailedTokenWriteAuth {
        async fn check_critical_rate_limit(
            &self,
            _: &str,
        ) -> Result<crate::auth::CriticalRateLimitOutcome, crate::auth::AuthError> {
            Ok(crate::auth::CriticalRateLimitOutcome::Allowed)
        }

        async fn login(
            &self,
            _: crate::auth::LoginRequest,
            _: crate::auth::RequestMetadata,
        ) -> Result<crate::auth::LoginOutcome, crate::auth::AuthError> {
            Err(crate::auth::AuthError::new(AuthErrorKind::Unauthorized))
        }

        async fn login_2fa(
            &self,
            _: TwoFactorLoginRequest,
            _: RequestMetadata,
        ) -> Result<AuthBundle, crate::auth::AuthError> {
            Err(crate::auth::AuthError::new(AuthErrorKind::Unauthorized))
        }

        async fn refresh(
            &self,
            _: SecretString,
            _: Option<String>,
            _: RequestMetadata,
        ) -> Result<AuthBundle, crate::auth::AuthError> {
            Err(crate::auth::AuthError::new(AuthErrorKind::Unauthorized))
        }

        async fn self_user(
            &self,
            _: SecretString,
        ) -> Result<DashboardUser, crate::auth::AuthError> {
            Ok(valid_user())
        }

        async fn logout(&self, _: LogoutRequest) -> Result<LogoutResult, crate::auth::AuthError> {
            Err(crate::auth::AuthError::new(AuthErrorKind::Unauthorized))
        }

        async fn generate_personal_access_token(
            &self,
            _: SecretString,
        ) -> Result<String, crate::auth::AuthError> {
            Err(crate::auth::AuthError::with_legacy_response_message(
                AuthErrorKind::Internal,
                "ERROR: transaction fixture injected write failure (SQLSTATE P0001)".to_owned(),
            ))
        }
    }

    #[tokio::test]
    async fn token_write_error_keeps_legacy_success_status_and_database_message() {
        let pool = PgPoolOptions::new()
            .acquire_timeout(std::time::Duration::from_millis(1))
            .connect_lazy("postgres://unused:unused@localhost/unused")
            .expect("valid lazy PostgreSQL URL");
        let app = router(IdentityCatalogState::new(
            pool,
            std::sync::Arc::new(FailedTokenWriteAuth),
        ));
        let response = app
            .oneshot(
                Request::builder()
                    .uri("/api/user/token")
                    .header("authorization", "Bearer dashboard-session")
                    .body(axum::body::Body::empty())
                    .unwrap(),
            )
            .await
            .unwrap();
        assert_eq!(response.status(), StatusCode::OK);
        let body = to_bytes(response.into_body(), 1024).await.unwrap();
        assert_eq!(
            serde_json::from_slice::<serde_json::Value>(&body).unwrap(),
            serde_json::json!({
                "success": false,
                "message": "ERROR: transaction fixture injected write failure (SQLSTATE P0001)"
            })
        );
    }

    #[tokio::test]
    async fn public_router_does_not_expose_protected_catalogue_or_token_routes() {
        let pool = PgPoolOptions::new()
            .acquire_timeout(std::time::Duration::from_millis(1))
            .connect_lazy("postgres://unused:unused@localhost/unused")
            .expect("valid lazy PostgreSQL URL");
        let app = public_router(IdentityCatalogState::new(
            pool,
            std::sync::Arc::new(RejectingAuth),
        ));
        for path in [
            "/api/user/self/groups",
            "/api/user/models",
            "/api/user/token",
        ] {
            let response = app
                .clone()
                .oneshot(
                    Request::builder()
                        .uri(path)
                        .body(axum::body::Body::empty())
                        .unwrap(),
                )
                .await
                .unwrap();
            assert_eq!(response.status(), StatusCode::NOT_FOUND, "{path}");
        }
    }

    #[tokio::test]
    async fn protected_read_router_rejects_before_database_access() {
        let pool = PgPoolOptions::new()
            .acquire_timeout(std::time::Duration::from_millis(1))
            .connect_lazy("postgres://unused:unused@localhost/unused")
            .expect("valid lazy PostgreSQL URL");
        let app = protected_read_router(IdentityCatalogState::new(
            pool,
            std::sync::Arc::new(RejectingAuth),
        ));
        for path in ["/api/user/self/groups", "/api/user/models"] {
            let response = app
                .clone()
                .oneshot(
                    Request::builder()
                        .uri(path)
                        .body(axum::body::Body::empty())
                        .unwrap(),
                )
                .await
                .unwrap();
            assert_eq!(response.status(), StatusCode::UNAUTHORIZED, "{path}");
        }
    }

    #[async_trait]
    impl DashboardAuth for IssuingAuth {
        async fn check_critical_rate_limit(
            &self,
            _: &str,
        ) -> Result<CriticalRateLimitOutcome, AuthError> {
            Ok(CriticalRateLimitOutcome::Allowed)
        }

        async fn login(
            &self,
            _: LoginRequest,
            _: RequestMetadata,
        ) -> Result<LoginOutcome, AuthError> {
            Err(AuthError::new(AuthErrorKind::Unauthorized))
        }

        async fn login_2fa(
            &self,
            _: TwoFactorLoginRequest,
            _: RequestMetadata,
        ) -> Result<AuthBundle, AuthError> {
            Err(AuthError::new(AuthErrorKind::Unauthorized))
        }

        async fn refresh(
            &self,
            _: SecretString,
            _: Option<String>,
            _: RequestMetadata,
        ) -> Result<AuthBundle, AuthError> {
            Err(AuthError::new(AuthErrorKind::Unauthorized))
        }

        async fn self_user(&self, _: SecretString) -> Result<DashboardUser, AuthError> {
            Ok(valid_user())
        }

        async fn logout(&self, _: LogoutRequest) -> Result<LogoutResult, AuthError> {
            Err(AuthError::new(AuthErrorKind::Unauthorized))
        }

        async fn generate_personal_access_token(
            &self,
            _: SecretString,
        ) -> Result<String, AuthError> {
            Ok("new-management-token".to_owned())
        }
    }

    #[tokio::test]
    async fn protected_catalogue_routes_keep_legacy_localized_unauthorized_envelope() {
        let pool = PgPoolOptions::new()
            .acquire_timeout(std::time::Duration::from_millis(1))
            .connect_lazy("postgres://unused:unused@localhost/unused")
            .expect("valid lazy PostgreSQL URL");
        let app = router(IdentityCatalogState::new(
            pool,
            std::sync::Arc::new(RejectingAuth),
        ));
        for path in [
            "/api/user/self/groups",
            "/api/user/models",
            "/api/user/token",
        ] {
            let response = app
                .clone()
                .oneshot(
                    Request::builder()
                        .uri(path)
                        .header("accept-language", "zh-CN")
                        .body(axum::body::Body::empty())
                        .unwrap(),
                )
                .await
                .unwrap();
            assert_eq!(response.status(), StatusCode::UNAUTHORIZED, "{path}");
            let body = to_bytes(response.into_body(), 1024).await.unwrap();
            assert_eq!(
                serde_json::from_slice::<serde_json::Value>(&body).unwrap(),
                serde_json::json!({"success":false,"message":"无权进行此操作，access token 无效","code":"AUTH_UNAUTHORIZED"})
            );
        }
    }

    #[tokio::test]
    async fn token_route_delegates_generation_to_dashboard_auth_and_preserves_envelope() {
        let pool = PgPoolOptions::new()
            .acquire_timeout(std::time::Duration::from_millis(1))
            .connect_lazy("postgres://unused:unused@localhost/unused")
            .expect("valid lazy PostgreSQL URL");
        let app = router(IdentityCatalogState::new(
            pool,
            std::sync::Arc::new(IssuingAuth),
        ));
        let response = app
            .oneshot(
                Request::builder()
                    .uri("/api/user/token")
                    .header("authorization", "Bearer dashboard-session")
                    .body(axum::body::Body::empty())
                    .unwrap(),
            )
            .await
            .unwrap();
        assert_eq!(response.status(), StatusCode::OK);
        let body = to_bytes(response.into_body(), 1024).await.unwrap();
        assert_eq!(
            serde_json::from_slice::<serde_json::Value>(&body).unwrap(),
            serde_json::json!({"success":true,"message":"","data":"new-management-token"})
        );
    }

    #[test]
    fn group_ratio_wire_numbers_match_go_encoding() {
        assert_eq!(legacy_ratio_value(1.0), serde_json::json!(1));
        assert_eq!(legacy_ratio_value(0.97), serde_json::json!(0.97));
        assert_eq!(legacy_ratio_value(-2.0), serde_json::json!(-2));
    }

    fn valid_user() -> DashboardUser {
        DashboardUser {
            id: 7,
            username: "member".to_owned(),
            display_name: String::new(),
            role: 1,
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
            setting: String::new(),
            stripe_customer: String::new(),
            sidebar_modules: serde_json::Value::Null,
            permissions: serde_json::Value::Null,
        }
    }
}
