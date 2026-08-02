//! Legacy-compatible dashboard authentication vertical slice.

mod http;
mod postgres;
mod token;

use async_trait::async_trait;
use secrecy::SecretString;
use serde::{Deserialize, Serialize};
use serde_json::Value;
use thiserror::Error;

pub use http::{AuthHttpState, auth_router};
pub use postgres::{AuthConfig, PgValkeyDashboardAuth};
pub(crate) use token::dashboard_token_candidate;

pub const REFRESH_COOKIE_NAME: &str = "new_api_refresh";
pub const ACCESS_TOKEN_TTL_SECONDS: i64 = 15 * 60;
pub const LOGIN_SESSION_TTL_SECONDS: i64 = 30 * 24 * 60 * 60;
pub const REFRESH_REPLAY_WINDOW_SECONDS: i64 = 30;
pub const TWO_FACTOR_FLOW_TTL_SECONDS: i64 = 5 * 60;
pub const TWO_FACTOR_MAX_FAIL_ATTEMPTS: i64 = 5;
pub const TWO_FACTOR_LOCKOUT_SECONDS: i64 = 5 * 60;

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum CriticalRateLimitOutcome {
    Allowed,
    Rejected { retry_after_seconds: u64 },
}

#[derive(Clone, Debug, Deserialize)]
pub struct LoginRequest {
    pub username: String,
    pub password: SecretString,
}

#[derive(Clone, Debug, Deserialize)]
pub struct TwoFactorLoginRequest {
    pub code: SecretString,
    pub flow_token: SecretString,
}

#[derive(Clone, Debug, Serialize)]
pub struct TwoFactorChallenge {
    pub require_2fa: bool,
    pub flow_token: String,
    pub expires_at: i64,
}

#[derive(Debug)]
pub enum LoginOutcome {
    Authenticated(Box<AuthBundle>),
    TwoFactorRequired(TwoFactorChallenge),
}

#[derive(Clone, Debug, Serialize)]
pub struct LoginSessionView {
    pub sid: String,
    pub current: bool,
    pub login_method: String,
    pub ip: String,
    pub user_agent: String,
    pub created_at: i64,
    pub last_active_at: i64,
    pub expires_at: i64,
}

#[derive(Clone, Debug, Serialize)]
pub struct DashboardUser {
    pub id: i64,
    pub username: String,
    pub display_name: String,
    pub role: i64,
    pub status: i64,
    pub email: String,
    pub github_id: String,
    pub discord_id: String,
    pub oidc_id: String,
    pub wechat_id: String,
    pub telegram_id: String,
    pub group: String,
    pub quota: i64,
    pub used_quota: i64,
    pub request_count: i64,
    pub aff_code: String,
    pub aff_count: i64,
    pub aff_quota: i64,
    pub aff_history_quota: i64,
    pub inviter_id: i64,
    pub linux_do_id: String,
    pub setting: String,
    pub stripe_customer: String,
    pub sidebar_modules: Value,
    pub permissions: Value,
}

/// The three server-derived failures emitted by Go's `middleware.UserAuth`.
///
/// Keep this check centralized: migration slices must not turn a disabled,
/// guest, or malformed dashboard principal into a generic invalid-token
/// response.  The order is observable legacy behaviour.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum UserAuthPolicyError {
    UserDisabled,
    InsufficientPrivilege,
    InvalidUserInfo,
}

/// Applies the legacy `UserAuth` policy after a dashboard credential has been
/// resolved by [`DashboardAuth`].  The caller is responsible for translating
/// the error into its route's legacy response envelope.
pub fn enforce_user_auth(user: &DashboardUser) -> Result<(), UserAuthPolicyError> {
    if user.status != 1 {
        return Err(UserAuthPolicyError::UserDisabled);
    }
    if user.role < 1 {
        return Err(UserAuthPolicyError::InsufficientPrivilege);
    }
    if user.id <= 0 || user.username.trim().is_empty() || !matches!(user.role, 0 | 1 | 10 | 100) {
        return Err(UserAuthPolicyError::InvalidUserInfo);
    }
    Ok(())
}

#[must_use]
pub fn user_auth_status(error: UserAuthPolicyError) -> u16 {
    match error {
        UserAuthPolicyError::InsufficientPrivilege => 403,
        UserAuthPolicyError::UserDisabled | UserAuthPolicyError::InvalidUserInfo => 401,
    }
}

/// Legacy localized text for a post-session `UserAuth` policy rejection.
/// Accept-Language only distinguishes English, Simplified Chinese, and
/// Traditional Chinese, exactly as the migrated dashboard routes do.
#[must_use]
pub fn user_auth_message(
    error: UserAuthPolicyError,
    accept_language: Option<&str>,
) -> &'static str {
    let language = accept_language
        .and_then(|value| value.split(',').next())
        .and_then(|value| value.split(';').next())
        .unwrap_or_default()
        .trim()
        .to_ascii_lowercase();
    let traditional = language.starts_with("zh-tw");
    let chinese = language.starts_with("zh");
    match (error, traditional, chinese) {
        (UserAuthPolicyError::UserDisabled, true, _) => "使用者已被封禁",
        (UserAuthPolicyError::UserDisabled, false, true) => "用户已被封禁",
        (UserAuthPolicyError::UserDisabled, false, false) => "User has been banned",
        (UserAuthPolicyError::InsufficientPrivilege, true, _) => "無權進行此操作，權限不足",
        (UserAuthPolicyError::InsufficientPrivilege, false, true) => "无权进行此操作，权限不足",
        (UserAuthPolicyError::InsufficientPrivilege, false, false) => {
            "Unauthorized, insufficient privileges"
        }
        (UserAuthPolicyError::InvalidUserInfo, true, _) => "無權進行此操作，使用者資訊無效",
        (UserAuthPolicyError::InvalidUserInfo, false, true) => "无权进行此操作，用户信息无效",
        (UserAuthPolicyError::InvalidUserInfo, false, false) => "Unauthorized, invalid user info",
    }
}

#[derive(Clone, Debug, Serialize)]
pub struct AuthResponseData {
    pub access_token: String,
    pub token_type: &'static str,
    pub access_expires_at: i64,
    pub session: LoginSessionView,
    pub user: DashboardUser,
}

#[derive(Debug)]
pub struct AuthBundle {
    pub data: AuthResponseData,
    pub refresh_token: SecretString,
}

#[derive(Clone, Debug)]
pub struct RequestMetadata {
    pub ip: String,
    pub user_agent: String,
}

/// Server-authenticated session context for a sensitive account change.
///
/// This is deliberately separate from request JSON: an edge authentication
/// middleware must derive the SID from a validated access token and derive the
/// metadata from the trusted connection context before invoking a sensitive
/// route.  Callers must never construct it from client supplied body fields.
#[derive(Clone, Debug)]
pub struct SecuritySessionRotationRequest {
    pub user_id: i64,
    pub session_id: String,
    pub auth_version: i64,
    pub metadata: RequestMetadata,
}

#[derive(Clone, Debug)]
pub struct LogoutRequest {
    pub access_token: Option<SecretString>,
    pub refresh_token: Option<SecretString>,
    pub expected_sid: Option<String>,
}

#[derive(Clone, Debug, Serialize, PartialEq, Eq)]
pub struct LogoutResult {
    #[serde(skip_serializing_if = "Option::is_none")]
    pub revoked_sid: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub cookie_cleared: Option<bool>,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum AuthErrorKind {
    InvalidCredentials,
    InvalidRequest,
    TwoFactorRequired,
    TwoFactorFlowExpired,
    InvalidTwoFactorCode,
    TwoFactorLocked,
    TwoFactorUnavailable,
    PasswordLoginDisabled,
    OriginForbidden,
    SessionLimit,
    SessionIssuanceLimit,
    SessionMismatch,
    RefreshRace,
    TokenExpired,
    SessionRevoked,
    /// An opaque dashboard personal-access-token owner is disabled.
    /// Session-backed credentials instead use [`Self::SessionRevoked`], which
    /// matches Go's session validation contract.
    UserDisabled,
    Unauthorized,
    Internal,
}

#[derive(Debug, Error)]
#[error("dashboard authentication failed: {kind:?}")]
pub struct AuthError {
    pub kind: AuthErrorKind,
    /// A legacy controller error that must be rendered verbatim by the one
    /// compatibility route that historically exposed database write errors.
    ///
    /// This is deliberately opt-in: ordinary authentication failures retain
    /// their stable, localized public envelopes.
    legacy_response_message: Option<String>,
}

impl AuthError {
    pub const fn new(kind: AuthErrorKind) -> Self {
        Self {
            kind,
            legacy_response_message: None,
        }
    }

    /// Preserves the historical `/api/user/token` controller error body for a
    /// failed personal-access-token write.  Do not use this for general auth
    /// failures: Go only exposes this detail from that legacy controller.
    #[must_use]
    pub fn with_legacy_response_message(kind: AuthErrorKind, message: String) -> Self {
        Self {
            kind,
            legacy_response_message: Some(message),
        }
    }

    #[must_use]
    pub fn legacy_response_message(&self) -> Option<&str> {
        self.legacy_response_message.as_deref()
    }
}

#[async_trait]
pub trait DashboardAuth: Send + Sync {
    async fn check_critical_rate_limit(
        &self,
        client_ip: &str,
    ) -> Result<CriticalRateLimitOutcome, AuthError>;

    async fn login(
        &self,
        request: LoginRequest,
        metadata: RequestMetadata,
    ) -> Result<LoginOutcome, AuthError>;

    async fn login_2fa(
        &self,
        request: TwoFactorLoginRequest,
        metadata: RequestMetadata,
    ) -> Result<AuthBundle, AuthError>;

    async fn refresh(
        &self,
        refresh_token: SecretString,
        expected_sid: Option<String>,
        metadata: RequestMetadata,
    ) -> Result<AuthBundle, AuthError>;

    async fn self_user(&self, access_token: SecretString) -> Result<DashboardUser, AuthError>;

    /// Resolves a dashboard credential before the route-specific `UserAuth`
    /// policy is applied.  Optional Go `TryUserAuth` consumers need the
    /// server-derived user context even when that policy would reject it;
    /// required routes continue to call [`enforce_user_auth`] themselves.
    async fn self_user_for_optional(
        &self,
        access_token: SecretString,
    ) -> Result<DashboardUser, AuthError> {
        self.self_user(access_token).await
    }

    async fn logout(&self, request: LogoutRequest) -> Result<LogoutResult, AuthError>;

    async fn generate_personal_access_token(
        &self,
        access_token: SecretString,
    ) -> Result<String, AuthError>;
}

/// Auditable source-to-module mapping for the four-route migration slice.
pub const LEGACY_AUTH_SOURCE_MAP: &[(&str, &str)] = &[
    ("controller/user.go", "auth/http.rs + auth/postgres.rs"),
    (
        "controller/auth_session.go",
        "auth/http.rs + auth/postgres.rs",
    ),
    ("middleware/auth.go", "auth/http.rs + auth/token.rs"),
    ("service/auth_token.go", "auth/token.rs"),
    ("service/auth_session.go", "auth/postgres.rs"),
    ("model/user.go", "auth/postgres.rs"),
    ("model/user_auth_cache.go", "auth/postgres.rs"),
    ("model/user_session.go", "auth/postgres.rs"),
    ("router/api-router.go", "auth/http.rs"),
];
