//! Frozen account-security and session route candidates.
//!
//! The module deliberately remains unmounted.  Its only security authority is
//! the listener-supplied [`SecurityAuthorizer`], while mail, credential, and
//! WebAuthn work stays behind [`SecurityProvider`].  In particular, the
//! in-memory provider is a test fake and refuses security-sensitive operations
//! by default rather than manufacturing a successful proof or credential.
//! Zero routes in this module are approved for production ownership.

use std::{
    sync::{Arc, Mutex},
    time::{SystemTime, UNIX_EPOCH},
};

use async_trait::async_trait;
use axum::{
    Json, Router,
    body::to_bytes,
    extract::{Request, State},
    http::{HeaderMap, HeaderValue, StatusCode, Uri, header},
    response::{IntoResponse, Response},
    routing::{delete, get, post},
};
use bcrypt::{DEFAULT_COST, hash};
use chrono::{DateTime, SecondsFormat, Utc};
use rand::{RngCore, rng};
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use sqlx::{PgPool, Row};

use crate::auth::{AuthErrorKind, DashboardAuth, dashboard_token_candidate};
use secrecy::SecretString;

const ADMIN_ROLE: i64 = 10;
const AUTH_VERSION: &str = "864b7076dbcd0a3c01b5520316720ebf";
const MAX_BODY_BYTES: usize = 1024 * 1024;

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
enum LegacyLocale {
    En,
    ZhCn,
    ZhTw,
}

impl LegacyLocale {
    fn from_headers(headers: &HeaderMap) -> Self {
        let language = headers
            .get(header::ACCEPT_LANGUAGE)
            .and_then(|value| value.to_str().ok())
            .and_then(|value| value.split(',').next())
            .map(|value| {
                value
                    .split(';')
                    .next()
                    .unwrap_or_default()
                    .trim()
                    .to_ascii_lowercase()
            })
            .unwrap_or_default();
        if language.starts_with("zh-tw") {
            Self::ZhTw
        } else if language.starts_with("zh") {
            Self::ZhCn
        } else {
            Self::En
        }
    }

    const fn invalid_access_token(self) -> &'static str {
        match self {
            Self::En => "Unauthorized, invalid access token",
            Self::ZhCn => "无权进行此操作，access token 无效",
            Self::ZhTw => "無權進行此操作，access token 無效",
        }
    }

    const fn not_logged_in(self) -> &'static str {
        match self {
            Self::En => "Unauthorized, not logged in and no access token provided",
            Self::ZhCn => "无权进行此操作，未登录且未提供 access token",
            Self::ZhTw => "無權進行此操作，未登入且未提供 access token",
        }
    }

    const fn user_banned(self) -> &'static str {
        match self {
            Self::En => "User has been banned",
            Self::ZhCn => "用户已被封禁",
            Self::ZhTw => "使用者已被封禁",
        }
    }

    const fn invalid_user_info(self) -> &'static str {
        match self {
            Self::En => "Unauthorized, invalid user info",
            Self::ZhCn => "无权进行此操作，用户信息无效",
            Self::ZhTw => "無權進行此操作，使用者資訊無效",
        }
    }

    const fn insufficient_privilege(self) -> &'static str {
        match self {
            Self::En => "Unauthorized, insufficient privileges",
            Self::ZhCn => "无权进行此操作，权限不足",
            Self::ZhTw => "無權進行此操作，權限不足",
        }
    }

    const fn database_error(self) -> &'static str {
        match self {
            Self::En => "Database error, please contact the administrator",
            Self::ZhCn => "数据库出错，请联系管理员",
            Self::ZhTw => "資料庫出錯，請聯繫管理員",
        }
    }

    const fn security_unavailable(self) -> &'static str {
        match self {
            Self::En => "Security service is temporarily unavailable",
            Self::ZhCn => "安全服务暂不可用",
            Self::ZhTw => "安全服務暫不可用",
        }
    }
}

/// Server-derived dashboard identity used by this route family.
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct SecurityActor {
    /// Durable user id, never a client-controlled header value.
    pub user_id: i64,
    /// Legacy role used to enforce administrator-only routes.
    pub role: i64,
    /// Current durable session id when the operation is session scoped.
    pub session_id: Option<String>,
}

/// Identity boundary owned by the eventual listener integration.
#[async_trait]
pub trait SecurityAuthorizer: Send + Sync {
    /// Resolves an active regular dashboard identity from server-validated credentials.
    async fn user(&self, headers: &HeaderMap) -> Result<SecurityActor, SecurityError>;

    /// Resolves an administrator identity from server-validated credentials.
    async fn admin(&self, headers: &HeaderMap) -> Result<SecurityActor, SecurityError>;
}

/// Production authorization adapter backed by the shared dashboard-auth service.
///
/// It accepts only a syntactically valid bearer credential and derives the
/// actor exclusively from the server-side token/session lookup.
#[derive(Clone)]
pub struct DashboardSecurityAuthorizer {
    auth: Arc<dyn DashboardAuth>,
}

impl DashboardSecurityAuthorizer {
    /// Creates an authorizer over the listener's configured dashboard auth service.
    #[must_use]
    pub fn new(auth: Arc<dyn DashboardAuth>) -> Self {
        Self { auth }
    }

    async fn actor(&self, headers: &HeaderMap) -> Result<SecurityActor, SecurityError> {
        let token = credential(headers).ok_or(SecurityError::Unauthorized)?;
        let session_candidate = dashboard_token_candidate(&token);
        let user = self
            .auth
            .self_user(SecretString::from(token))
            .await
            .map_err(|error| match error.kind {
                AuthErrorKind::TokenExpired => SecurityError::TokenExpired,
                AuthErrorKind::SessionRevoked => SecurityError::SessionRevoked,
                AuthErrorKind::Unauthorized | AuthErrorKind::InvalidCredentials => {
                    SecurityError::Unauthorized
                }
                AuthErrorKind::UserDisabled => SecurityError::UserDisabled,
                _ => SecurityError::InternalAuth,
            })?;
        if user.id <= 0 || user.username.trim().is_empty() || !matches!(user.role, 0 | 1 | 10 | 100)
        {
            return Err(SecurityError::InvalidUserInfo);
        }
        if user.status != 1 {
            return Err(SecurityError::UserDisabled);
        }
        if session_candidate {
            // `DashboardAuth::self_user` validates the session but does not
            // return its SID. Refuse to erase that distinction: a custom edge
            // authorizer must supply the server-validated SID before any
            // browser-session route can run.
            return Err(SecurityError::AuthenticatedSessionUnavailable);
        }
        Ok(SecurityActor {
            user_id: user.id,
            role: user.role,
            session_id: None,
        })
    }
}

#[async_trait]
impl SecurityAuthorizer for DashboardSecurityAuthorizer {
    async fn user(&self, headers: &HeaderMap) -> Result<SecurityActor, SecurityError> {
        self.actor(headers).await
    }

    async fn admin(&self, headers: &HeaderMap) -> Result<SecurityActor, SecurityError> {
        self.actor(headers).await
    }
}

struct RejectingSecurityAuthorizer;

#[async_trait]
impl SecurityAuthorizer for RejectingSecurityAuthorizer {
    async fn user(&self, _: &HeaderMap) -> Result<SecurityActor, SecurityError> {
        Err(SecurityError::Unauthorized)
    }

    async fn admin(&self, _: &HeaderMap) -> Result<SecurityActor, SecurityError> {
        Err(SecurityError::Unauthorized)
    }
}

/// Normalized operation selected only after its required authorization succeeds.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum SecurityOperation {
    AdminClearBinding,
    AdminResetPasskey,
    AuthzCatalog,
    SendPasswordReset,
    PasskeyStatus,
    ListSessions,
    SendEmailVerification,
    VerifyTwoFactorLogin,
    PasskeyLoginBegin,
    PasskeyLoginFinish,
    PasskeyRegisterBegin,
    PasskeyRegisterFinish,
    PasskeyVerifyBegin,
    PasskeyVerifyFinish,
    Register,
    ResetPassword,
    RevokeOtherSessions,
    UniversalVerify,
    DeletePasskey,
    DeleteSession,
}

/// Input delivered to the durable/mail/WebAuthn boundary after validation.
#[derive(Clone, Debug, PartialEq)]
pub struct SecurityCall {
    /// Selected route operation.
    pub operation: SecurityOperation,
    /// Authenticated actor for user/admin routes; anonymous routes have no actor.
    pub actor: Option<SecurityActor>,
    /// Legacy path, query, or JSON data.
    pub input: Value,
}

/// Errors exposed through the frozen legacy JSON envelope.
#[derive(Clone, Debug, Eq, PartialEq)]
pub enum SecurityError {
    /// No valid listener-authenticated identity exists.
    Unauthorized,
    /// A recognized dashboard access token has expired.
    TokenExpired,
    /// A recognized dashboard session is no longer valid.
    SessionRevoked,
    /// The authenticated dashboard user is disabled.
    UserDisabled,
    /// The resolved dashboard user has an invalid username or role.
    InvalidUserInfo,
    /// Authentication storage or validation failed internally.
    InternalAuth,
    /// Authentication succeeded, but the shared interface omitted the session id.
    AuthenticatedSessionUnavailable,
    /// The authenticated principal lacks the requested administrator role.
    Forbidden,
    /// The operation requires a listener-verified browser-session identity.
    SessionRequired,
    /// The legacy request shape is invalid.
    Invalid(&'static str),
    /// An external or durable dependency could not safely complete the operation.
    Unavailable,
    /// A known legacy business-rule rejection.
    Rejected(String),
    /// Public registration is disabled by the operator.
    RegistrationDisabled,
    /// Password registration is disabled by the operator.
    PasswordRegistrationDisabled,
    /// Registration cannot proceed until both legal documents are published.
    RegistrationLegalUnavailable,
    /// Registration requires explicit acceptance of both legal documents.
    LegalConsentRequired,
    /// Registration input does not satisfy the legacy validation contract.
    InvalidRegistration,
    /// The requested username or email already belongs to an account.
    RegistrationConflict,
}

impl SecurityError {
    fn response(self, locale: LegacyLocale) -> Response {
        match self {
            Self::Unauthorized => failure(
                StatusCode::UNAUTHORIZED,
                locale.invalid_access_token(),
                Some("AUTH_UNAUTHORIZED"),
            ),
            Self::TokenExpired => failure(
                StatusCode::UNAUTHORIZED,
                locale.not_logged_in(),
                Some("AUTH_TOKEN_EXPIRED"),
            ),
            Self::SessionRevoked => failure(
                StatusCode::UNAUTHORIZED,
                locale.not_logged_in(),
                Some("AUTH_SESSION_REVOKED"),
            ),
            Self::UserDisabled => failure(
                StatusCode::UNAUTHORIZED,
                locale.user_banned(),
                Some("AUTH_USER_DISABLED"),
            ),
            Self::InvalidUserInfo => failure(
                StatusCode::UNAUTHORIZED,
                locale.invalid_user_info(),
                Some("AUTH_USER_INVALID"),
            ),
            Self::InternalAuth => failure(
                StatusCode::INTERNAL_SERVER_ERROR,
                locale.database_error(),
                Some("AUTH_INTERNAL_ERROR"),
            ),
            Self::AuthenticatedSessionUnavailable => failure(
                StatusCode::SERVICE_UNAVAILABLE,
                locale.security_unavailable(),
                None,
            ),
            Self::Forbidden => failure(
                StatusCode::FORBIDDEN,
                locale.insufficient_privilege(),
                Some("AUTH_INSUFFICIENT_PRIVILEGE"),
            ),
            Self::SessionRequired => failure(
                StatusCode::FORBIDDEN,
                "a dashboard login session is required",
                Some("AUTH_SESSION_REQUIRED"),
            ),
            Self::Invalid(message) => failure(StatusCode::OK, message, None),
            Self::Unavailable => failure(
                StatusCode::SERVICE_UNAVAILABLE,
                locale.security_unavailable(),
                None,
            ),
            Self::Rejected(message) => failure(StatusCode::OK, &message, None),
            Self::RegistrationDisabled => {
                failure(StatusCode::OK, "注册功能已关闭", Some("REGISTER_DISABLED"))
            }
            Self::PasswordRegistrationDisabled => failure(
                StatusCode::OK,
                "管理员关闭了密码注册",
                Some("PASSWORD_REGISTER_DISABLED"),
            ),
            Self::RegistrationLegalUnavailable => failure(
                StatusCode::SERVICE_UNAVAILABLE,
                "注册暂不可用：用户协议和隐私政策尚未发布",
                Some("REGISTRATION_LEGAL_UNAVAILABLE"),
            ),
            Self::LegalConsentRequired => failure(
                StatusCode::UNPROCESSABLE_ENTITY,
                "注册前必须同意用户协议和隐私政策",
                Some("LEGAL_CONSENT_REQUIRED"),
            ),
            Self::InvalidRegistration => {
                failure(StatusCode::OK, "无效的注册参数", Some("INVALID_PARAMS"))
            }
            Self::RegistrationConflict => {
                failure(StatusCode::OK, "用户名或邮箱已存在", Some("USER_EXISTS"))
            }
        }
    }
}

/// Boundary for password-reset mail, session storage, and WebAuthn operations.
///
/// Production adapters must perform their protocol-specific verification here;
/// a handler never converts a browser assertion into a success response itself.
#[async_trait]
pub trait SecurityProvider: Send + Sync {
    /// Executes a normalized operation after route-level authorization and validation.
    async fn execute(&self, call: SecurityCall) -> Result<Value, SecurityError>;
}

/// Deterministic in-memory fake for route tests.
///
/// Its default result is [`SecurityError::Unavailable`], which ensures that a
/// test harness cannot accidentally claim a mail or WebAuthn security success.
pub struct MemorySecurityProvider {
    result: Mutex<Result<Value, SecurityError>>,
    calls: Mutex<Vec<SecurityCall>>,
}

impl Default for MemorySecurityProvider {
    fn default() -> Self {
        Self::new(Err(SecurityError::Unavailable))
    }
}

impl MemorySecurityProvider {
    /// Creates a fake with an explicit result suitable for one isolated test.
    #[must_use]
    pub fn new(result: Result<Value, SecurityError>) -> Self {
        Self {
            result: Mutex::new(result),
            calls: Mutex::new(Vec::new()),
        }
    }

    /// Returns calls recorded by the fake, or an error if a test poisoned its lock.
    pub fn calls(&self) -> Result<Vec<SecurityCall>, SecurityError> {
        self.calls
            .lock()
            .map(|calls| calls.clone())
            .map_err(|_| SecurityError::Unavailable)
    }
}

#[async_trait]
impl SecurityProvider for MemorySecurityProvider {
    async fn execute(&self, call: SecurityCall) -> Result<Value, SecurityError> {
        self.calls
            .lock()
            .map_err(|_| SecurityError::Unavailable)?
            .push(call);
        self.result
            .lock()
            .map_err(|_| SecurityError::Unavailable)?
            .clone()
    }
}

/// PostgreSQL/Valkey implementation for the durable security operations.
///
/// WebAuthn ceremony validation and outbound mail deliberately remain outside
/// this adapter: accepting a browser assertion or claiming a message was sent
/// without a configured standards-compliant boundary would be a security bug.
/// Those operations therefore fail closed with [`SecurityError::Unavailable`].
#[derive(Clone)]
pub struct PgValkeySecurityProvider {
    pool: PgPool,
    _valkey: redis::Client,
}

impl PgValkeySecurityProvider {
    #[must_use]
    pub fn new(pool: PgPool, valkey: redis::Client) -> Self {
        Self {
            pool,
            _valkey: valkey,
        }
    }

    fn actor(call: &SecurityCall) -> Result<&SecurityActor, SecurityError> {
        call.actor.as_ref().ok_or(SecurityError::Unauthorized)
    }

    fn admin_actor(call: &SecurityCall) -> Result<&SecurityActor, SecurityError> {
        let actor = Self::actor(call)?;
        (actor.role >= ADMIN_ROLE)
            .then_some(actor)
            .ok_or(SecurityError::Forbidden)
    }

    async fn passkey_status(&self, actor: &SecurityActor) -> Result<Value, SecurityError> {
        let row = sqlx::query(
            "SELECT to_char( \
                 last_used_at AT TIME ZONE 'UTC', \
                 'YYYY-MM-DD\"T\"HH24:MI:SS.US\"Z\"' \
             ) AS last_used_at FROM passkey_credentials \
             WHERE user_id = $1 AND deleted_at IS NULL LIMIT 1",
        )
        .bind(actor.user_id)
        .fetch_optional(&self.pool)
        .await
        .map_err(|_| SecurityError::Unavailable)?;
        let Some(row) = row else {
            return Ok(json!({"enabled": false}));
        };
        let last_used_at = row
            .try_get::<Option<String>, _>("last_used_at")
            .map_err(|_| SecurityError::Unavailable)?
            .map(|value| {
                DateTime::parse_from_rfc3339(&value)
                    .map(|timestamp| {
                        timestamp
                            .with_timezone(&Utc)
                            .to_rfc3339_opts(SecondsFormat::AutoSi, true)
                    })
                    .map_err(|_| SecurityError::Unavailable)
            })
            .transpose()?;
        Ok(json!({
            "enabled": true,
            "last_used_at": last_used_at,
        }))
    }

    async fn list_sessions(&self, actor: &SecurityActor) -> Result<Value, SecurityError> {
        let now = unix_seconds()?;
        let rows = sqlx::query(
            "SELECT sid, login_method, ip, user_agent, created_at, last_active_at, expires_at \
             FROM user_sessions WHERE user_id = $1 AND status = 'active' AND revoked_at = 0 \
             AND expires_at > $2 ORDER BY created_at DESC LIMIT 100",
        )
        .bind(actor.user_id)
        .bind(now)
        .fetch_all(&self.pool)
        .await
        .map_err(|_| SecurityError::Unavailable)?;
        let sessions = rows
            .into_iter()
            .map(|row| {
                let sid = row
                    .try_get::<String, _>("sid")
                    .map_err(|_| SecurityError::Unavailable)?;
                let current = actor.session_id.as_deref() == Some(sid.as_str());
                Ok(json!({
                    "sid": sid,
                    "current": current,
                    "login_method": row.try_get::<String, _>("login_method").map_err(|_| SecurityError::Unavailable)?,
                    "ip": row.try_get::<Option<String>, _>("ip").map_err(|_| SecurityError::Unavailable)?,
                    "user_agent": row.try_get::<Option<String>, _>("user_agent").map_err(|_| SecurityError::Unavailable)?,
                    "created_at": row.try_get::<i64, _>("created_at").map_err(|_| SecurityError::Unavailable)?,
                    "last_active_at": row.try_get::<i64, _>("last_active_at").map_err(|_| SecurityError::Unavailable)?,
                    "expires_at": row.try_get::<i64, _>("expires_at").map_err(|_| SecurityError::Unavailable)?,
                }))
            })
            .collect::<Result<Vec<_>, SecurityError>>()?;
        Ok(Value::Array(sessions))
    }

    async fn option(&self, key: &str) -> Result<Option<String>, SecurityError> {
        sqlx::query_scalar::<_, Option<String>>("SELECT value FROM options WHERE key = $1")
            .bind(key)
            .fetch_optional(&self.pool)
            .await
            .map(|value| value.flatten())
            .map_err(|_| SecurityError::Unavailable)
    }

    async fn option_bool(&self, key: &str, default: bool) -> Result<bool, SecurityError> {
        Ok(self
            .option(key)
            .await?
            .as_deref()
            .map(|value| value.trim().eq_ignore_ascii_case("true"))
            .unwrap_or(default))
    }

    async fn register(&self, input: Value) -> Result<Value, SecurityError> {
        if !self.option_bool("RegisterEnabled", true).await? {
            return Err(SecurityError::RegistrationDisabled);
        }
        if !self.option_bool("PasswordRegisterEnabled", true).await? {
            return Err(SecurityError::PasswordRegistrationDisabled);
        }

        let request: RegistrationInput =
            serde_json::from_value(input).map_err(|_| SecurityError::InvalidRegistration)?;
        let username = request.username.trim().to_owned();
        let password = request.password;
        let email = request
            .email
            .unwrap_or_default()
            .trim()
            .to_ascii_lowercase();
        if username.is_empty()
            || username.chars().count() > 20
            || username.chars().any(char::is_control)
            || password.len() < 8
            || password.len() > 20
            || (!email.is_empty() && email.chars().count() > 50)
        {
            return Err(SecurityError::InvalidRegistration);
        }

        let agreement = self.option("legal.user_agreement").await?;
        let privacy = self.option("legal.privacy_policy").await?;
        if agreement
            .as_deref()
            .is_none_or(|value| value.trim().is_empty())
            || privacy
                .as_deref()
                .is_none_or(|value| value.trim().is_empty())
        {
            return Err(SecurityError::RegistrationLegalUnavailable);
        }
        if !request.accepted_legal {
            return Err(SecurityError::LegalConsentRequired);
        }
        if self.option_bool("EmailVerificationEnabled", false).await? {
            // Verification-code delivery/confirmation is not part of this mounted
            // slice yet.  Refuse the write when the legacy flag is enabled rather
            // than creating an account that bypasses the configured gate.
            return Err(SecurityError::Unavailable);
        }

        let password_hash = tokio::task::spawn_blocking(move || hash(password, DEFAULT_COST))
            .await
            .map_err(|_| SecurityError::Unavailable)?
            .map_err(|_| SecurityError::Unavailable)?;
        let now = unix_seconds()?;
        let mut transaction = self
            .pool
            .begin()
            .await
            .map_err(|_| SecurityError::Unavailable)?;
        let existing = sqlx::query_scalar::<_, bool>(
            "SELECT EXISTS(SELECT 1 FROM users WHERE deleted_at IS NULL AND (username = $1 OR ($2 <> '' AND lower(COALESCE(email, '')) = $2)))",
        )
        .bind(&username)
        .bind(&email)
        .fetch_one(&mut *transaction)
        .await
        .map_err(|_| SecurityError::Unavailable)?;
        if existing {
            return Err(SecurityError::RegistrationConflict);
        }

        let inviter_id = if request.aff_code.trim().is_empty() {
            0_i64
        } else {
            sqlx::query_scalar::<_, Option<i64>>(
                "SELECT id FROM users WHERE deleted_at IS NULL AND aff_code = $1 LIMIT 1",
            )
            .bind(request.aff_code.trim())
            .fetch_optional(&mut *transaction)
            .await
            .map_err(|_| SecurityError::Unavailable)?
            .flatten()
            .unwrap_or(0)
        };

        let aff_code = new_aff_code();
        let inserted = sqlx::query(
            "INSERT INTO users (username, password, display_name, role, status, email, \"group\", aff_code, inviter_id, quota, used_quota, request_count, created_at, auth_version) VALUES ($1, $2, $1, 1, 1, $3, 'default', $4, $5, 0, 0, 0, $6, 1)",
        )
        .bind(&username)
        .bind(&password_hash)
        .bind(&email)
        .bind(&aff_code)
        .bind(inviter_id)
        .bind(now)
        .execute(&mut *transaction)
        .await;
        match inserted {
            Ok(_) => transaction
                .commit()
                .await
                .map_err(|_| SecurityError::Unavailable)?,
            Err(error)
                if error
                    .as_database_error()
                    .is_some_and(|db| db.code().as_deref() == Some("23505")) =>
            {
                return Err(SecurityError::RegistrationConflict);
            }
            Err(_) => return Err(SecurityError::Unavailable),
        }
        Ok(Value::Null)
    }
}

#[derive(Debug, Deserialize)]
struct RegistrationInput {
    username: String,
    password: String,
    #[serde(default)]
    email: Option<String>,
    #[serde(default)]
    aff_code: String,
    #[serde(default)]
    accepted_legal: bool,
}

fn new_aff_code() -> String {
    let mut bytes = [0_u8; 8];
    rng().fill_bytes(&mut bytes);
    const ALPHABET: &[u8] = b"23456789ABCDEFGHJKLMNPQRSTUVWXYZ";
    bytes
        .into_iter()
        .map(|byte| ALPHABET[(byte as usize) % ALPHABET.len()] as char)
        .collect()
}

#[async_trait]
impl SecurityProvider for PgValkeySecurityProvider {
    async fn execute(&self, call: SecurityCall) -> Result<Value, SecurityError> {
        match call.operation {
            SecurityOperation::PasskeyStatus => self.passkey_status(Self::actor(&call)?).await,
            SecurityOperation::ListSessions => self.list_sessions(Self::actor(&call)?).await,
            SecurityOperation::DeleteSession => {
                // Go publishes a session-specific deny fence and clears the
                // matching refresh cookie. The candidate has neither boundary.
                Err(SecurityError::Unavailable)
            }
            SecurityOperation::RevokeOtherSessions => {
                // Go publishes per-session deny fences before this mutation.
                // This candidate has no shared session-cache boundary, so a
                // database-only update would leave a revoked session usable.
                Err(SecurityError::Unavailable)
            }
            // Deleting a passkey must consume a scoped 2FA/passkey proof.
            // The listener does not yet supply such a verified proof.
            SecurityOperation::DeletePasskey => Err(SecurityError::Unavailable),
            SecurityOperation::AdminResetPasskey => {
                Self::admin_actor(&call)?;
                // Go writes an explicit admin audit and publishes a deny
                // fence for every session before committing revocation. The
                // candidate has neither boundary, so no partial reset is safe.
                Err(SecurityError::Unavailable)
            }
            SecurityOperation::AdminClearBinding => {
                Self::admin_actor(&call)?;
                Err(SecurityError::Unavailable)
            }
            SecurityOperation::AuthzCatalog => {
                Self::admin_actor(&call)?;
                // The legacy payload is the static authorization registry,
                // not a database table. Do not invent a partial catalog.
                Err(SecurityError::Unavailable)
            }
            // No handler may synthesize success for an external mail/WebAuthn
            // protocol or for a password flow whose proof boundary is absent.
            SecurityOperation::SendPasswordReset
            | SecurityOperation::SendEmailVerification
            | SecurityOperation::VerifyTwoFactorLogin
            | SecurityOperation::PasskeyLoginBegin
            | SecurityOperation::PasskeyLoginFinish
            | SecurityOperation::PasskeyRegisterBegin
            | SecurityOperation::PasskeyRegisterFinish
            | SecurityOperation::PasskeyVerifyBegin
            | SecurityOperation::PasskeyVerifyFinish
            | SecurityOperation::ResetPassword
            | SecurityOperation::UniversalVerify => Err(SecurityError::Unavailable),
            SecurityOperation::Register => self.register(call.input).await,
        }
    }
}

fn unix_seconds() -> Result<i64, SecurityError> {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|duration| duration.as_secs() as i64)
        .map_err(|_| SecurityError::Unavailable)
}

#[cfg(test)]
mod provider_tests {
    use super::*;

    fn provider() -> PgValkeySecurityProvider {
        let pool = sqlx::postgres::PgPoolOptions::new()
            .connect_lazy("postgres://unused:unused@127.0.0.1/unused")
            .expect("valid lazy PostgreSQL URL");
        let valkey = redis::Client::open("redis://127.0.0.1/").expect("valid Valkey URL");
        PgValkeySecurityProvider::new(pool, valkey)
    }

    #[tokio::test]
    async fn unconfigured_mail_boundary_fails_closed_without_database_or_valkey_io() {
        let outcome = provider()
            .execute(SecurityCall {
                operation: SecurityOperation::SendEmailVerification,
                actor: None,
                input: json!({"email": "ada@example.test"}),
            })
            .await;
        assert_eq!(outcome, Err(SecurityError::Unavailable));
    }

    #[tokio::test]
    async fn production_provider_checks_admin_role_before_catalog_storage_access() {
        let outcome = provider()
            .execute(SecurityCall {
                operation: SecurityOperation::AuthzCatalog,
                actor: Some(SecurityActor {
                    user_id: 7,
                    role: 1,
                    session_id: Some("server-session".to_owned()),
                }),
                input: json!({}),
            })
            .await;
        assert_eq!(outcome, Err(SecurityError::Forbidden));
    }
}

/// Dependencies for the unmounted identity-security candidate router.
#[derive(Clone)]
pub struct IdentitySecurityState {
    provider: Arc<dyn SecurityProvider>,
    authorizer: Arc<dyn SecurityAuthorizer>,
}

impl IdentitySecurityState {
    /// Creates a candidate router state with an explicit security provider and authorizer.
    #[must_use]
    pub fn new(
        provider: Arc<dyn SecurityProvider>,
        authorizer: Arc<dyn SecurityAuthorizer>,
    ) -> Self {
        Self {
            provider,
            authorizer,
        }
    }

    /// Creates a state which rejects every authenticated request until listener wiring exists.
    #[must_use]
    pub fn with_rejecting_authorizer(provider: Arc<dyn SecurityProvider>) -> Self {
        Self::new(provider, Arc::new(RejectingSecurityAuthorizer))
    }

    /// Installs the production authorizer backed by the shared dashboard auth service.
    #[must_use]
    pub fn with_dashboard_auth(mut self, auth: Arc<dyn DashboardAuth>) -> Self {
        self.authorizer = Arc::new(DashboardSecurityAuthorizer::new(auth));
        self
    }
}

/// All twenty frozen account-security route candidates, intentionally unmounted.
pub fn router(state: IdentitySecurityState) -> Router {
    Router::new()
        .route(
            "/api/user/{id}/bindings/{binding_type}",
            delete(admin_clear_binding),
        )
        .route("/api/user/{id}/reset_passkey", delete(admin_reset_passkey))
        .route(
            "/api/user/passkey",
            get(passkey_status).delete(delete_passkey),
        )
        .route("/api/user/sessions/{sid}", delete(delete_session))
        .route("/api/authz/catalog", get(authz_catalog))
        .route("/api/reset_password", get(send_password_reset))
        .route("/api/user/sessions", get(list_sessions))
        .route("/api/verification", get(send_email_verification))
        .route("/api/user/login/2fa", post(verify_two_factor_login))
        .route("/api/user/passkey/login/begin", post(passkey_login_begin))
        .route("/api/user/passkey/login/finish", post(passkey_login_finish))
        .route(
            "/api/user/passkey/register/begin",
            post(passkey_register_begin),
        )
        .route(
            "/api/user/passkey/register/finish",
            post(passkey_register_finish),
        )
        .route("/api/user/passkey/verify/begin", post(passkey_verify_begin))
        .route(
            "/api/user/passkey/verify/finish",
            post(passkey_verify_finish),
        )
        .merge(registration_route())
        .route("/api/user/reset", post(reset_password))
        .route(
            "/api/user/sessions/revoke-others",
            post(revoke_other_sessions),
        )
        .route("/api/verify", post(universal_verify))
        .with_state(state)
}

/// The password-registration route is the one anonymous identity surface that
/// has a complete PostgreSQL implementation. Keep it separate from the
/// remaining account-security candidates so the normal listener cannot
/// accidentally claim ownership of passkey, mail, or session-mutation routes.
pub fn registration_router(state: IdentitySecurityState) -> Router {
    registration_route().with_state(state)
}

fn registration_route() -> Router<IdentitySecurityState> {
    Router::new().route("/api/user/register", post(register))
}

#[derive(Serialize)]
struct Envelope<T: Serialize> {
    success: bool,
    message: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    data: Option<T>,
    #[serde(skip_serializing_if = "Option::is_none")]
    code: Option<&'static str>,
}

fn failure(status: StatusCode, message: &str, code: Option<&'static str>) -> Response {
    (
        status,
        Json(Envelope::<()> {
            success: false,
            message: message.to_owned(),
            data: None,
            code,
        }),
    )
        .into_response()
}

fn success(data: Value) -> Response {
    Json(Envelope {
        success: true,
        message: String::new(),
        data: Some(data),
        code: None,
    })
    .into_response()
}

fn operation_success(operation: SecurityOperation, data: Value) -> Response {
    if operation == SecurityOperation::Register {
        return Json(json!({"success": true, "message": ""})).into_response();
    }
    if operation == SecurityOperation::AdminResetPasskey {
        return Json(json!({
            "success": true,
            "message": "Passkey 已重置",
        }))
        .into_response();
    }
    success(data)
}

fn with_auth_version(mut response: Response) -> Response {
    response
        .headers_mut()
        .insert("auth-version", HeaderValue::from_static(AUTH_VERSION));
    response
}

fn with_no_store(mut response: Response) -> Response {
    response.headers_mut().insert(
        header::CACHE_CONTROL,
        HeaderValue::from_static("no-store, no-cache, must-revalidate, private, max-age=0"),
    );
    response
        .headers_mut()
        .insert(header::PRAGMA, HeaderValue::from_static("no-cache"));
    response
        .headers_mut()
        .insert(header::EXPIRES, HeaderValue::from_static("0"));
    response
}

async fn authenticated_user(
    state: &IdentitySecurityState,
    headers: &HeaderMap,
) -> Result<SecurityActor, Response> {
    let locale = LegacyLocale::from_headers(headers);
    let actor = match state.authorizer.user(headers).await {
        Ok(actor) => actor,
        Err(error) => {
            let credential_was_validated =
                matches!(error, SecurityError::AuthenticatedSessionUnavailable);
            let response = error.response(locale);
            return Err(if credential_was_validated {
                with_auth_version(response)
            } else {
                response
            });
        }
    };
    if actor.user_id <= 0 {
        return Err(SecurityError::Unauthorized.response(locale));
    }
    if actor.role < 1 {
        return Err(SecurityError::Forbidden.response(locale));
    }
    Ok(actor)
}

async fn authenticated_browser_session(
    state: &IdentitySecurityState,
    headers: &HeaderMap,
) -> Result<SecurityActor, Response> {
    let actor = authenticated_user(state, headers).await?;
    match actor.session_id.as_deref() {
        Some(session_id) if !session_id.trim().is_empty() => Ok(actor),
        _ => Err(with_auth_version(
            SecurityError::SessionRequired.response(LegacyLocale::from_headers(headers)),
        )),
    }
}

fn credential(headers: &HeaderMap) -> Option<String> {
    let raw = headers.get(header::AUTHORIZATION)?.to_str().ok()?.trim();
    let mut fields = raw.split_ascii_whitespace();
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

async fn authenticated_admin(
    state: &IdentitySecurityState,
    headers: &HeaderMap,
) -> Result<SecurityActor, Response> {
    let locale = LegacyLocale::from_headers(headers);
    let actor = match state.authorizer.admin(headers).await {
        Ok(actor) => actor,
        Err(error) => {
            let credential_was_validated =
                matches!(error, SecurityError::AuthenticatedSessionUnavailable);
            let response = error.response(locale);
            return Err(if credential_was_validated {
                with_auth_version(response)
            } else {
                response
            });
        }
    };
    if actor.user_id <= 0 {
        return Err(SecurityError::Unauthorized.response(locale));
    }
    if actor.role < ADMIN_ROLE {
        return Err(SecurityError::Forbidden.response(locale));
    }
    Ok(actor)
}

async fn json_after_auth(request: Request, locale: LegacyLocale) -> Result<Value, Response> {
    let body = to_bytes(request.into_body(), MAX_BODY_BYTES)
        .await
        .map_err(|_| SecurityError::Invalid("参数错误").response(locale))?;
    let value: Value = serde_json::from_slice(&body)
        .map_err(|_| SecurityError::Invalid("参数错误").response(locale))?;
    if value.is_object() {
        Ok(value)
    } else {
        Err(SecurityError::Invalid("参数错误").response(locale))
    }
}

fn query_after_auth(uri: &Uri, key: &str) -> Result<Value, SecurityError> {
    let value = uri
        .query()
        .and_then(|query| {
            query.split('&').find_map(|part| {
                part.split_once('=')
                    .filter(|(name, _)| *name == key)
                    .map(|(_, value)| value)
            })
        })
        .filter(|value| !value.is_empty() && value.len() <= 320);
    value
        .map(|value| json!({key: value}))
        .ok_or(SecurityError::Invalid("参数错误"))
}

fn single_path_after_auth(uri: &Uri, prefix: &str, name: &str) -> Result<Value, SecurityError> {
    let value = uri
        .path()
        .strip_prefix(prefix)
        .filter(|value| !value.is_empty() && !value.contains('/') && value.len() <= 128);
    value
        .map(|value| json!({name: value}))
        .ok_or(SecurityError::Invalid("参数错误"))
}

fn binding_path_after_auth(uri: &Uri) -> Result<Value, SecurityError> {
    let value = uri
        .path()
        .strip_prefix("/api/user/")
        .and_then(|tail| tail.split_once("/bindings/"));
    let Some((id, binding_type)) = value else {
        return Err(SecurityError::Invalid("参数错误"));
    };
    let id = id.parse::<i64>().ok().filter(|id| *id > 0);
    if binding_type.is_empty() || binding_type.contains('/') || binding_type.len() > 64 {
        return Err(SecurityError::Invalid("参数错误"));
    }
    id.map(|id| json!({"id": id, "binding_type": binding_type}))
        .ok_or(SecurityError::Invalid("参数错误"))
}

async fn execute(
    state: &IdentitySecurityState,
    operation: SecurityOperation,
    actor: Option<SecurityActor>,
    input: Value,
    locale: LegacyLocale,
) -> Response {
    let authenticated = actor.is_some();
    let response = match state
        .provider
        .execute(SecurityCall {
            operation,
            actor,
            input,
        })
        .await
    {
        Ok(data) => operation_success(operation, data),
        Err(error) => error.response(locale),
    };
    if authenticated {
        with_auth_version(response)
    } else {
        response
    }
}

async fn admin_clear_binding(
    State(state): State<IdentitySecurityState>,
    request: Request,
) -> Response {
    let locale = LegacyLocale::from_headers(request.headers());
    let actor = match authenticated_admin(&state, request.headers()).await {
        Ok(actor) => actor,
        Err(response) => return response,
    };
    let input = match binding_path_after_auth(request.uri()) {
        Ok(input) => input,
        Err(error) => return with_auth_version(error.response(locale)),
    };
    execute(
        &state,
        SecurityOperation::AdminClearBinding,
        Some(actor),
        input,
        locale,
    )
    .await
}

async fn admin_reset_passkey(
    State(state): State<IdentitySecurityState>,
    request: Request,
) -> Response {
    let locale = LegacyLocale::from_headers(request.headers());
    let actor = match authenticated_admin(&state, request.headers()).await {
        Ok(actor) => actor,
        Err(response) => return response,
    };
    let Some(id) = request
        .uri()
        .path()
        .strip_prefix("/api/user/")
        .and_then(|tail| tail.strip_suffix("/reset_passkey"))
        .filter(|id| !id.contains('/'))
        .and_then(|id| id.parse::<i64>().ok())
        .filter(|id| *id > 0)
    else {
        return with_auth_version(SecurityError::Invalid("无效的用户 ID").response(locale));
    };
    execute(
        &state,
        SecurityOperation::AdminResetPasskey,
        Some(actor),
        json!({"id": id}),
        locale,
    )
    .await
}

async fn authz_catalog(State(state): State<IdentitySecurityState>, request: Request) -> Response {
    let locale = LegacyLocale::from_headers(request.headers());
    let actor = match authenticated_admin(&state, request.headers()).await {
        Ok(actor) => actor,
        Err(response) => return response,
    };
    execute(
        &state,
        SecurityOperation::AuthzCatalog,
        Some(actor),
        json!({}),
        locale,
    )
    .await
}
async fn passkey_status(State(state): State<IdentitySecurityState>, request: Request) -> Response {
    let locale = LegacyLocale::from_headers(request.headers());
    let actor = match authenticated_user(&state, request.headers()).await {
        Ok(actor) => actor,
        Err(response) => return response,
    };
    execute(
        &state,
        SecurityOperation::PasskeyStatus,
        Some(actor),
        json!({}),
        locale,
    )
    .await
}
async fn list_sessions(State(state): State<IdentitySecurityState>, request: Request) -> Response {
    let locale = LegacyLocale::from_headers(request.headers());
    let actor = match authenticated_browser_session(&state, request.headers()).await {
        Ok(actor) => actor,
        Err(response) => return response,
    };
    with_no_store(
        execute(
            &state,
            SecurityOperation::ListSessions,
            Some(actor),
            json!({}),
            locale,
        )
        .await,
    )
}
async fn delete_passkey(State(state): State<IdentitySecurityState>, request: Request) -> Response {
    let locale = LegacyLocale::from_headers(request.headers());
    let actor = match authenticated_browser_session(&state, request.headers()).await {
        Ok(actor) => actor,
        Err(response) => return response,
    };
    with_no_store(
        execute(
            &state,
            SecurityOperation::DeletePasskey,
            Some(actor),
            json!({}),
            locale,
        )
        .await,
    )
}
async fn delete_session(State(state): State<IdentitySecurityState>, request: Request) -> Response {
    let locale = LegacyLocale::from_headers(request.headers());
    let actor = match authenticated_browser_session(&state, request.headers()).await {
        Ok(actor) => actor,
        Err(response) => return response,
    };
    let input = match single_path_after_auth(request.uri(), "/api/user/sessions/", "sid") {
        Ok(input) => input,
        Err(error) => return with_no_store(with_auth_version(error.response(locale))),
    };
    with_no_store(
        execute(
            &state,
            SecurityOperation::DeleteSession,
            Some(actor),
            input,
            locale,
        )
        .await,
    )
}
async fn send_password_reset(
    State(state): State<IdentitySecurityState>,
    request: Request,
) -> Response {
    let locale = LegacyLocale::from_headers(request.headers());
    let input = match query_after_auth(request.uri(), "email") {
        Ok(input) => input,
        Err(error) => return error.response(locale),
    };
    execute(
        &state,
        SecurityOperation::SendPasswordReset,
        None,
        input,
        locale,
    )
    .await
}
async fn send_email_verification(
    State(state): State<IdentitySecurityState>,
    request: Request,
) -> Response {
    let locale = LegacyLocale::from_headers(request.headers());
    let input = match query_after_auth(request.uri(), "email") {
        Ok(input) => input,
        Err(error) => return error.response(locale),
    };
    execute(
        &state,
        SecurityOperation::SendEmailVerification,
        None,
        input,
        locale,
    )
    .await
}

async fn anonymous_json(
    State(state): State<IdentitySecurityState>,
    request: Request,
    operation: SecurityOperation,
) -> Response {
    let locale = LegacyLocale::from_headers(request.headers());
    let input = match json_after_auth(request, locale).await {
        Ok(input) => input,
        Err(response) => return response,
    };
    execute(&state, operation, None, input, locale).await
}
async fn user_json(
    State(state): State<IdentitySecurityState>,
    request: Request,
    operation: SecurityOperation,
) -> Response {
    let locale = LegacyLocale::from_headers(request.headers());
    let actor = match authenticated_browser_session(&state, request.headers()).await {
        Ok(actor) => actor,
        Err(response) => return response,
    };
    let input = match json_after_auth(request, locale).await {
        Ok(input) => input,
        Err(response) => return with_no_store(with_auth_version(response)),
    };
    with_no_store(execute(&state, operation, Some(actor), input, locale).await)
}

async fn verify_two_factor_login(
    state: State<IdentitySecurityState>,
    request: Request,
) -> Response {
    with_no_store(anonymous_json(state, request, SecurityOperation::VerifyTwoFactorLogin).await)
}
async fn passkey_login_begin(state: State<IdentitySecurityState>, request: Request) -> Response {
    with_no_store(anonymous_json(state, request, SecurityOperation::PasskeyLoginBegin).await)
}
async fn passkey_login_finish(state: State<IdentitySecurityState>, request: Request) -> Response {
    with_no_store(anonymous_json(state, request, SecurityOperation::PasskeyLoginFinish).await)
}
async fn register(state: State<IdentitySecurityState>, request: Request) -> Response {
    anonymous_json(state, request, SecurityOperation::Register).await
}
async fn reset_password(state: State<IdentitySecurityState>, request: Request) -> Response {
    anonymous_json(state, request, SecurityOperation::ResetPassword).await
}
async fn passkey_register_begin(state: State<IdentitySecurityState>, request: Request) -> Response {
    user_json(state, request, SecurityOperation::PasskeyRegisterBegin).await
}
async fn passkey_register_finish(
    state: State<IdentitySecurityState>,
    request: Request,
) -> Response {
    user_json(state, request, SecurityOperation::PasskeyRegisterFinish).await
}
async fn passkey_verify_begin(state: State<IdentitySecurityState>, request: Request) -> Response {
    user_json(state, request, SecurityOperation::PasskeyVerifyBegin).await
}
async fn passkey_verify_finish(state: State<IdentitySecurityState>, request: Request) -> Response {
    user_json(state, request, SecurityOperation::PasskeyVerifyFinish).await
}
async fn revoke_other_sessions(state: State<IdentitySecurityState>, request: Request) -> Response {
    let locale = LegacyLocale::from_headers(request.headers());
    let actor = match authenticated_browser_session(&state, request.headers()).await {
        Ok(actor) => actor,
        Err(response) => return response,
    };
    with_no_store(
        execute(
            &state,
            SecurityOperation::RevokeOtherSessions,
            Some(actor),
            json!({}),
            locale,
        )
        .await,
    )
}
async fn universal_verify(state: State<IdentitySecurityState>, request: Request) -> Response {
    user_json(state, request, SecurityOperation::UniversalVerify).await
}
