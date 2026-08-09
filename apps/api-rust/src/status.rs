//! PostgreSQL-authoritative implementation of the legacy `GET /api/status` contract.

use crate::auth::DashboardAuth;
use async_trait::async_trait;
use axum::{
    Json,
    http::StatusCode,
    response::{IntoResponse, Response},
};
use secrecy::SecretString;
use serde::{Serialize, Serializer};
use serde_json::Value;
use sqlx::{PgPool, Row};
use std::{collections::BTreeMap, sync::Arc};

const DEFAULT_DOCS_LINK: &str = "https://docs.newapi.pro/en/docs";
const DEFAULT_CHATS: &str = r#"[
  {"Cherry Studio":"cherrystudio://providers/api-keys?v=1&data={cherryConfig}"},
  {"AionUI":"aionui://provider/add?v=1&data={aionuiConfig}"},
  {"流畅阅读":"fluentread"},
  {"CC Switch":"ccswitch"},
  {"DeepChat":"deepchat://provider/install?v=1&data={deepchatConfig}"},
  {"Lobe Chat 官方示例":"https://chat-preview.lobehub.com/?settings={\"keyVaults\":{\"openai\":{\"apiKey\":\"{key}\",\"baseURL\":\"{address}/v1\"}}}"},
  {"AI as Workspace":"https://aiaw.app/set-provider?provider={\"type\":\"openai\",\"settings\":{\"apiKey\":\"{key}\",\"baseURL\":\"{address}/v1\",\"compatibility\":\"strict\"}}"},
  {"AMA 问天":"ama://set-api-key?server={address}&key={key}"},
  {"OpenCat":"opencat://team/join?domain={address}&token={key}"}
]"#;

/// The immutable public Turnstile state published by `GET /api/status`.
/// The verification secret intentionally never enters this type.
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct TurnstilePublicConfig {
    pub enabled: bool,
    pub site_key: String,
}

impl TurnstilePublicConfig {
    #[must_use]
    pub fn disabled() -> Self {
        Self {
            enabled: false,
            site_key: String::new(),
        }
    }
}

/// The immutable public Turnstile state published by `GET /api/status`.
/// The verification secret intentionally never enters this type.
#[derive(Clone, Debug, PartialEq)]
pub struct StatusSnapshot {
    pub options: BTreeMap<String, String>,
    pub custom_oauth_providers: Vec<CustomOAuthInfo>,
    pub setup: bool,
}

#[derive(Clone, Debug, PartialEq, Serialize)]
pub struct CustomOAuthInfo {
    pub id: i64,
    pub name: String,
    pub slug: String,
    pub icon: String,
    pub client_id: String,
    pub authorization_endpoint: String,
    pub scopes: String,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct StatusRepositoryError;

impl std::fmt::Display for StatusRepositoryError {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        formatter.write_str("status repository unavailable")
    }
}

impl std::error::Error for StatusRepositoryError {}

#[async_trait]
pub trait StatusRepository: Send + Sync {
    async fn snapshot(&self) -> Result<StatusSnapshot, StatusRepositoryError>;
}

pub struct PgStatusRepository {
    pg: PgPool,
    local_acceptance: bool,
}

impl PgStatusRepository {
    #[must_use]
    pub fn new(pg: PgPool) -> Self {
        Self {
            pg,
            local_acceptance: false,
        }
    }

    /// Enables the explicitly loopback-scoped local acceptance policy.
    ///
    /// The normal listener passes the validated configuration value. Frozen
    /// test instances keep the default disabled value.
    #[must_use]
    pub fn with_local_acceptance(mut self, enabled: bool) -> Self {
        self.local_acceptance = enabled;
        self
    }
}

#[async_trait]
impl StatusRepository for PgStatusRepository {
    async fn snapshot(&self) -> Result<StatusSnapshot, StatusRepositoryError> {
        let options = async {
            let rows = sqlx::query("SELECT key, value FROM options")
                .fetch_all(&self.pg)
                .await?;
            rows.into_iter()
                .map(|row| {
                    let key: String = row.try_get("key")?;
                    let value: Option<String> = row.try_get("value")?;
                    Ok((key, value.unwrap_or_default()))
                })
                .collect::<Result<BTreeMap<_, _>, sqlx::Error>>()
        };
        let providers = async {
            let rows = sqlx::query(
                "SELECT id, name, slug, icon, client_id, authorization_endpoint, scopes \
                 FROM custom_oauth_providers WHERE enabled = TRUE ORDER BY id ASC",
            )
            .fetch_all(&self.pg)
            .await?;
            rows.into_iter()
                .map(|row| {
                    Ok(CustomOAuthInfo {
                        id: row.try_get("id")?,
                        name: row.try_get("name")?,
                        slug: row.try_get("slug")?,
                        icon: row
                            .try_get::<Option<String>, _>("icon")?
                            .unwrap_or_default(),
                        client_id: row
                            .try_get::<Option<String>, _>("client_id")?
                            .unwrap_or_default(),
                        authorization_endpoint: row
                            .try_get::<Option<String>, _>("authorization_endpoint")?
                            .unwrap_or_default(),
                        scopes: row
                            .try_get::<Option<String>, _>("scopes")?
                            .unwrap_or_default(),
                    })
                })
                .collect::<Result<Vec<_>, sqlx::Error>>()
        };
        let setup = sqlx::query_scalar::<_, bool>("SELECT EXISTS(SELECT 1 FROM setups)");
        let (options, custom_oauth_providers, setup) =
            tokio::try_join!(options, providers, setup.fetch_one(&self.pg)).map_err(|error| {
                tracing::error!(error = ?error, "status snapshot query failed");
                StatusRepositoryError
            })?;
        Ok(StatusSnapshot {
            options,
            custom_oauth_providers,
            setup,
        })
    }
}

#[derive(Clone)]
pub struct StatusHttpState {
    repository: Arc<dyn StatusRepository>,
    dashboard_auth: Option<Arc<dyn DashboardAuth>>,
    turnstile_enabled: bool,
    turnstile_site_key: String,
    version: Arc<str>,
    start_time: i64,
}

impl StatusHttpState {
    #[must_use]
    pub fn new(
        repository: Arc<dyn StatusRepository>,
        version: impl Into<Arc<str>>,
        start_time: i64,
    ) -> Self {
        Self {
            repository,
            dashboard_auth: None,
            turnstile_enabled: false,
            turnstile_site_key: String::new(),
            version: version.into(),
            start_time,
        }
    }

    #[must_use]
    pub fn with_dashboard_auth(mut self, dashboard_auth: Arc<dyn DashboardAuth>) -> Self {
        self.dashboard_auth = Some(dashboard_auth);
        self
    }

    #[must_use]
    pub fn with_turnstile_config(
        mut self,
        turnstile_enabled: bool,
        site_key: impl Into<String>,
    ) -> Self {
        self.turnstile_enabled = turnstile_enabled;
        self.turnstile_site_key = site_key.into();
        self
    }

    #[must_use]
    pub fn version(&self) -> &str {
        &self.version
    }

    pub async fn response(&self) -> Response {
        self.response_with_authorization(None).await
    }

    pub async fn response_for_headers(&self) -> Response {
        self.response().await
    }

    pub async fn response_with_authorization(&self, authorization: Option<&str>) -> Response {
        match self.repository.snapshot().await {
            Ok(snapshot) => {
                let mut data = StatusData::from_snapshot(snapshot, &self.version, self.start_time);
                let access = self.status_access(authorization).await;
                data.apply_access(access);
                if self.turnstile_enabled {
                    data.turnstile_check = true;
                }
                if !self.turnstile_site_key.is_empty() {
                    data.turnstile_site_key = self.turnstile_site_key.clone();
                }
                Json(StatusEnvelope {
                    success: true,
                    ready: true,
                    message: "",
                    data,
                })
                .into_response()
            }
            Err(_) => (
                StatusCode::SERVICE_UNAVAILABLE,
                Json(StatusNotReadyEnvelope {
                    success: false,
                    ready: false,
                    message: "service caches are not ready",
                }),
            )
                .into_response(),
        }
    }

    async fn status_access(&self, authorization: Option<&str>) -> StatusAccess {
        let (Some(auth), Some(authorization)) = (&self.dashboard_auth, authorization) else {
            return StatusAccess::default();
        };
        match auth
            .self_user_view_for_optional(SecretString::from(authorization.to_owned()))
            .await
        {
            Ok(view) => StatusAccess {
                docs_access: view.trust_level_info.level >= 1,
                console_activation_granted: view.developer_access_granted,
            },
            Err(_) => StatusAccess::default(),
        }
    }
}

#[derive(Clone, Copy, Debug, Default, Eq, PartialEq)]
struct StatusAccess {
    docs_access: bool,
    console_activation_granted: bool,
}

#[derive(Serialize)]
struct StatusEnvelope {
    success: bool,
    ready: bool,
    message: &'static str,
    data: StatusData,
}

#[derive(Serialize)]
struct StatusNotReadyEnvelope {
    success: bool,
    ready: bool,
    message: &'static str,
}

#[derive(Debug, PartialEq, Serialize)]
struct StatusData {
    version: String,
    start_time: i64,
    email_verification: bool,
    github_oauth: bool,
    github_client_id: String,
    discord_oauth: bool,
    discord_client_id: String,
    linuxdo_oauth: bool,
    linuxdo_client_id: String,
    linuxdo_minimum_trust_level: i64,
    telegram_oauth: bool,
    telegram_bot_name: String,
    theme: &'static str,
    system_name: String,
    logo: String,
    footer_html: String,
    wechat_qrcode: String,
    wechat_login: bool,
    server_address: String,
    turnstile_check: bool,
    turnstile_site_key: String,
    docs_link: String,
    docs_access: bool,
    #[serde(serialize_with = "serialize_legacy_number")]
    quota_per_unit: f64,
    display_in_currency: bool,
    quota_display_type: String,
    custom_currency_symbol: String,
    #[serde(serialize_with = "serialize_legacy_number")]
    custom_currency_exchange_rate: f64,
    enable_batch_update: bool,
    enable_drawing: bool,
    enable_task: bool,
    enable_data_export: bool,
    data_export_default_time: String,
    default_collapse_sidebar: bool,
    mj_notify_enabled: bool,
    chats: Value,
    demo_site_enabled: bool,
    self_use_mode_enabled: bool,
    register_enabled: bool,
    password_login_enabled: bool,
    password_register_enabled: bool,
    default_use_auto_group: bool,
    #[serde(serialize_with = "serialize_legacy_number")]
    usd_exchange_rate: f64,
    #[serde(serialize_with = "serialize_legacy_number")]
    price: f64,
    #[serde(serialize_with = "serialize_legacy_number")]
    stripe_unit_price: f64,
    api_info_enabled: bool,
    uptime_kuma_enabled: bool,
    announcements_enabled: bool,
    faq_enabled: bool,
    #[serde(rename = "HeaderNavModules")]
    header_nav_modules: String,
    #[serde(rename = "SidebarModulesAdmin")]
    sidebar_modules_admin: String,
    oidc_enabled: bool,
    oidc_client_id: String,
    oidc_authorization_endpoint: String,
    oidc_display_name: String,
    passkey_login: bool,
    passkey_display_name: String,
    passkey_rp_id: String,
    passkey_origins: String,
    passkey_allow_insecure: bool,
    passkey_user_verification: String,
    passkey_attachment: String,
    setup: bool,
    user_agreement_enabled: bool,
    privacy_policy_enabled: bool,
    checkin_enabled: bool,
    backend_capabilities: BackendCapabilities,
    #[serde(skip_serializing_if = "Option::is_none")]
    api_info: Option<Value>,
    #[serde(skip_serializing_if = "Option::is_none")]
    announcements: Option<Value>,
    #[serde(skip_serializing_if = "Option::is_none")]
    faq: Option<Value>,
    #[serde(skip_serializing_if = "Option::is_none")]
    custom_oauth_providers: Option<Vec<CustomOAuthInfo>>,
}

#[derive(Debug, Eq, PartialEq, Serialize)]
struct BackendCapabilities {
    bounty_notifications: bool,
    bounty_challenge_cancel: bool,
    bounty_public_read: bool,
    self_oauth_unbind: bool,
    responses_websocket: bool,
}

impl BackendCapabilities {
    fn current_go() -> Self {
        Self {
            bounty_notifications: true,
            bounty_challenge_cancel: true,
            bounty_public_read: true,
            self_oauth_unbind: true,
            responses_websocket: true,
        }
    }
}

fn serialize_legacy_number<S>(value: &f64, serializer: S) -> Result<S::Ok, S::Error>
where
    S: Serializer,
{
    if value.is_finite()
        && value.fract() == 0.0
        && *value >= i64::MIN as f64
        && *value <= i64::MAX as f64
    {
        serializer.serialize_i64(*value as i64)
    } else {
        serializer.serialize_f64(*value)
    }
}

impl StatusData {
    fn from_snapshot(snapshot: StatusSnapshot, version: &str, start_time: i64) -> Self {
        let options = Options(snapshot.options);
        // The public origin is an operator/database setting.  Never publish
        // a baked-in localhost URL from a deployed listener.
        let server_address = options.string("ServerAddress", "");
        let quota_display_type = options.string("general_setting.quota_display_type", "USD");
        let api_info_enabled = options.boolean("console_setting.api_info_enabled", true);
        let docs_link = options.string("general_setting.docs_link", DEFAULT_DOCS_LINK);
        let announcements_enabled = options.boolean("console_setting.announcements_enabled", true);
        let faq_enabled = options.boolean("console_setting.faq_enabled", true);
        let mut announcements = announcements_enabled
            .then(|| json_list(options.raw("console_setting.announcements"), true));
        if let Some(Value::Array(items)) = &mut announcements {
            items.sort_by(|left, right| {
                right
                    .get("publishDate")
                    .and_then(Value::as_str)
                    .cmp(&left.get("publishDate").and_then(Value::as_str))
            });
        }
        let passkey_rp_id = {
            let configured = options.string("passkey.rp_id", "");
            if configured.is_empty() {
                server_host(&server_address)
            } else {
                configured
            }
        };
        let passkey_origins = {
            let configured = options.string("passkey.origins", "");
            if configured.is_empty() || configured == "[]" {
                server_address.clone()
            } else {
                configured
            }
        };
        let oidc_display_name = options.string("oidc.display_name", "");
        Self {
            version: version.to_owned(),
            start_time,
            email_verification: options.boolean("EmailVerificationEnabled", false),
            github_oauth: options.boolean("GitHubOAuthEnabled", false),
            github_client_id: options.string("GitHubClientId", ""),
            discord_oauth: options.boolean("discord.enabled", false),
            discord_client_id: options.string("discord.client_id", ""),
            linuxdo_oauth: options.boolean("LinuxDOOAuthEnabled", false),
            linuxdo_client_id: options.string("LinuxDOClientId", ""),
            linuxdo_minimum_trust_level: options.integer("LinuxDOMinimumTrustLevel", 0),
            telegram_oauth: options.boolean("TelegramOAuthEnabled", false),
            telegram_bot_name: options.string("TelegramBotName", ""),
            theme: "default",
            system_name: options.string("SystemName", "LMM API"),
            logo: options.string("Logo", ""),
            footer_html: options.string("Footer", ""),
            wechat_qrcode: options.string("WeChatAccountQRCodeImageURL", ""),
            wechat_login: options.boolean("WeChatAuthEnabled", false),
            server_address,
            turnstile_check: options.boolean("TurnstileCheckEnabled", false),
            turnstile_site_key: options.string("TurnstileSiteKey", ""),
            docs_link,
            docs_access: false,
            quota_per_unit: options.number("QuotaPerUnit", 500_000.0),
            display_in_currency: quota_display_type != "TOKENS",
            quota_display_type,
            custom_currency_symbol: options.string("general_setting.custom_currency_symbol", "¤"),
            custom_currency_exchange_rate: options
                .number("general_setting.custom_currency_exchange_rate", 1.0),
            enable_batch_update: options.boolean("BatchUpdateEnabled", false),
            enable_drawing: options.boolean("DrawingEnabled", true),
            enable_task: options.boolean("TaskEnabled", true),
            enable_data_export: options.boolean("DataExportEnabled", true),
            data_export_default_time: options.string("DataExportDefaultTime", "hour"),
            default_collapse_sidebar: options.boolean("DefaultCollapseSidebar", false),
            mj_notify_enabled: options.boolean("MjNotifyEnabled", false),
            chats: options.json_or("Chats", DEFAULT_CHATS, Value::Array(Vec::new())),
            demo_site_enabled: options.boolean("DemoSiteEnabled", false),
            self_use_mode_enabled: options.boolean("SelfUseModeEnabled", false),
            register_enabled: options.boolean("RegisterEnabled", true),
            password_login_enabled: options.boolean("PasswordLoginEnabled", true),
            password_register_enabled: options.boolean("PasswordRegisterEnabled", true),
            default_use_auto_group: options.boolean("DefaultUseAutoGroup", false),
            usd_exchange_rate: options.number("USDExchangeRate", 7.3),
            price: options.number("Price", 7.3),
            stripe_unit_price: options.number("StripeUnitPrice", 8.0),
            api_info_enabled,
            uptime_kuma_enabled: options.boolean("console_setting.uptime_kuma_enabled", true),
            announcements_enabled,
            faq_enabled,
            header_nav_modules: options.string("HeaderNavModules", ""),
            sidebar_modules_admin: options.string("SidebarModulesAdmin", ""),
            oidc_enabled: options.boolean("oidc.enabled", false),
            oidc_client_id: options.string("oidc.client_id", ""),
            oidc_authorization_endpoint: options.string("oidc.authorization_endpoint", ""),
            oidc_display_name: if oidc_display_name.trim().is_empty() {
                "OIDC".to_owned()
            } else {
                oidc_display_name.trim().to_owned()
            },
            passkey_login: options.boolean("passkey.enabled", false),
            passkey_display_name: options.string("passkey.rp_display_name", "LMM API"),
            passkey_rp_id,
            passkey_origins,
            passkey_allow_insecure: options.boolean("passkey.allow_insecure_origin", false),
            passkey_user_verification: options.string("passkey.user_verification", "preferred"),
            passkey_attachment: options.string("passkey.attachment_preference", ""),
            setup: snapshot.setup,
            user_agreement_enabled: !options.string("legal.user_agreement", "").is_empty(),
            privacy_policy_enabled: !options.string("legal.privacy_policy", "").is_empty(),
            checkin_enabled: options.boolean("checkin_setting.enabled", false),
            backend_capabilities: BackendCapabilities::current_go(),
            api_info: api_info_enabled
                .then(|| json_list(options.raw("console_setting.api_info"), false)),
            announcements,
            faq: faq_enabled.then(|| json_list(options.raw("console_setting.faq"), false)),
            custom_oauth_providers: (!snapshot.custom_oauth_providers.is_empty())
                .then_some(snapshot.custom_oauth_providers),
        }
    }

    fn apply_access(&mut self, access: StatusAccess) {
        self.docs_access = access.docs_access;
        if !access.docs_access {
            self.docs_link.clear();
        }
        if !access.console_activation_granted {
            self.api_info_enabled = false;
            self.api_info = None;
        }
    }
}

struct Options(BTreeMap<String, String>);

impl Options {
    fn raw(&self, key: &str) -> Option<&str> {
        self.0.get(key).map(String::as_str)
    }

    fn string(&self, key: &str, default: &str) -> String {
        self.raw(key).unwrap_or(default).to_owned()
    }

    fn boolean(&self, key: &str, default: bool) -> bool {
        self.raw(key)
            .and_then(|value| value.parse().ok())
            .unwrap_or(default)
    }

    fn integer(&self, key: &str, default: i64) -> i64 {
        self.raw(key)
            .and_then(|value| value.parse().ok())
            .unwrap_or(default)
    }

    fn number(&self, key: &str, default: f64) -> f64 {
        self.raw(key)
            .and_then(|value| value.parse().ok())
            .unwrap_or(default)
    }

    fn json_or(&self, key: &str, default_json: &str, invalid: Value) -> Value {
        match self.raw(key) {
            Some(value) => serde_json::from_str(value).unwrap_or(invalid),
            None => serde_json::from_str(default_json).expect("built-in JSON must be valid"),
        }
    }
}

fn json_list(raw: Option<&str>, sort: bool) -> Value {
    let Some(raw) = raw.filter(|value| !value.is_empty()) else {
        return Value::Array(Vec::new());
    };
    let mut value = serde_json::from_str::<Value>(raw).unwrap_or(Value::Null);
    if !value.is_array() {
        value = Value::Null;
    }
    if sort && let Value::Array(items) = &mut value {
        items.sort_by(|left, right| {
            right
                .get("publishDate")
                .and_then(Value::as_str)
                .cmp(&left.get("publishDate").and_then(Value::as_str))
        });
    }
    value
}

fn server_host(address: &str) -> String {
    address
        .trim()
        .split_once("://")
        .map_or(address.trim(), |(_, rest)| rest)
        .split('/')
        .next()
        .unwrap_or_default()
        .to_owned()
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::auth::{
        AuthBundle, AuthError, AuthErrorKind, CriticalRateLimitOutcome, DashboardSelfUserFacts,
        DashboardUser, DashboardUserView, LoginOutcome, LoginRequest, LogoutRequest, LogoutResult,
        RequestMetadata, TwoFactorLoginRequest,
    };
    use serde_json::json;

    const DEFAULT_VERSION: &str = "v0.0.0";

    fn default_snapshot() -> StatusSnapshot {
        StatusSnapshot {
            options: BTreeMap::new(),
            custom_oauth_providers: Vec::new(),
            setup: false,
        }
    }

    #[test]
    fn anonymous_status_body_matches_the_current_go_shape() {
        let mut data =
            StatusData::from_snapshot(default_snapshot(), DEFAULT_VERSION, 1_700_000_000);
        data.apply_access(StatusAccess::default());
        let actual = serde_json::to_value(StatusEnvelope {
            success: true,
            ready: true,
            message: "",
            data,
        })
        .expect("serialize status");
        assert_eq!(actual["success"], true);
        assert_eq!(actual["ready"], true);
        assert_eq!(actual["message"], "");
        assert_eq!(actual["data"]["version"], DEFAULT_VERSION);
        assert_eq!(actual["data"]["start_time"], 1_700_000_000_i64);
        assert_eq!(actual["data"]["system_name"], "LMM API");
        assert_eq!(actual["data"]["docs_access"], false);
        assert_eq!(actual["data"]["docs_link"], "");
        assert_eq!(actual["data"]["api_info_enabled"], false);
        assert!(actual["data"].get("api_info").is_none());
        assert_eq!(
            actual["data"]["backend_capabilities"],
            json!({
                "bounty_notifications": true,
                "bounty_challenge_cancel": true,
                "bounty_public_read": true,
                "self_oauth_unbind": true,
                "responses_websocket": true,
            })
        );
        assert!(actual["data"].get("turnstile_secret_key").is_none());
        assert!(actual["data"].get("client_secret").is_none());
    }

    #[tokio::test]
    async fn repository_failure_returns_service_unavailable_status() {
        struct FailingStatusRepository;

        #[async_trait]
        impl StatusRepository for FailingStatusRepository {
            async fn snapshot(&self) -> Result<StatusSnapshot, StatusRepositoryError> {
                Err(StatusRepositoryError)
            }
        }

        let response = StatusHttpState::new(
            Arc::new(FailingStatusRepository),
            DEFAULT_VERSION,
            1_700_000_000,
        )
        .response()
        .await;
        assert_eq!(response.status(), StatusCode::SERVICE_UNAVAILABLE);
        let body = axum::body::to_bytes(response.into_body(), usize::MAX)
            .await
            .expect("failure body is readable");
        let body: Value = serde_json::from_slice(&body).expect("failure response is JSON");
        assert_eq!(body["success"], false);
        assert_eq!(body["ready"], false);
        assert_eq!(body["message"], "service caches are not ready");
    }

    fn dashboard_user() -> DashboardUser {
        DashboardUser {
            id: 7,
            username: "alice".to_owned(),
            display_name: "Alice".to_owned(),
            role: 1,
            status: 1,
            email: "alice@example.test".to_owned(),
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
            sidebar_modules: Value::Null,
            permissions: Value::Null,
        }
    }

    struct StatusAuth {
        facts: Option<DashboardSelfUserFacts>,
    }

    #[async_trait]
    impl DashboardAuth for StatusAuth {
        async fn check_critical_rate_limit(
            &self,
            _client_ip: &str,
        ) -> Result<CriticalRateLimitOutcome, AuthError> {
            Ok(CriticalRateLimitOutcome::Allowed)
        }

        async fn login(
            &self,
            _request: LoginRequest,
            _metadata: RequestMetadata,
        ) -> Result<LoginOutcome, AuthError> {
            Err(AuthError::new(AuthErrorKind::Internal))
        }

        async fn login_2fa(
            &self,
            _request: TwoFactorLoginRequest,
            _metadata: RequestMetadata,
        ) -> Result<AuthBundle, AuthError> {
            Err(AuthError::new(AuthErrorKind::Internal))
        }

        async fn refresh(
            &self,
            _refresh_token: SecretString,
            _expected_sid: Option<String>,
            _metadata: RequestMetadata,
        ) -> Result<AuthBundle, AuthError> {
            Err(AuthError::new(AuthErrorKind::Internal))
        }

        async fn self_user(&self, _access_token: SecretString) -> Result<DashboardUser, AuthError> {
            Err(AuthError::new(AuthErrorKind::Internal))
        }

        async fn self_user_view_for_optional(
            &self,
            _access_token: SecretString,
        ) -> Result<DashboardUserView, AuthError> {
            self.facts
                .map(|facts| DashboardUserView::build(dashboard_user(), facts))
                .ok_or_else(|| AuthError::new(AuthErrorKind::Internal))
        }

        async fn logout(&self, _request: LogoutRequest) -> Result<LogoutResult, AuthError> {
            Ok(LogoutResult {
                revoked_sid: None,
                cookie_cleared: None,
            })
        }

        async fn generate_personal_access_token(
            &self,
            _access_token: SecretString,
        ) -> Result<String, AuthError> {
            Err(AuthError::new(AuthErrorKind::Internal))
        }
    }

    struct TestStatusRepository;

    #[async_trait]
    impl StatusRepository for TestStatusRepository {
        async fn snapshot(&self) -> Result<StatusSnapshot, StatusRepositoryError> {
            Ok(StatusSnapshot {
                options: BTreeMap::from([
                    (
                        "general_setting.docs_link".to_owned(),
                        "https://docs.example.test".to_owned(),
                    ),
                    (
                        "console_setting.api_info_enabled".to_owned(),
                        "true".to_owned(),
                    ),
                    (
                        "console_setting.api_info".to_owned(),
                        r#"[{"title":"API"}]"#.to_owned(),
                    ),
                ]),
                custom_oauth_providers: Vec::new(),
                setup: false,
            })
        }
    }

    fn state_with_auth(facts: Option<DashboardSelfUserFacts>) -> StatusHttpState {
        StatusHttpState::new(
            Arc::new(TestStatusRepository),
            DEFAULT_VERSION,
            1_700_000_000,
        )
        .with_dashboard_auth(Arc::new(StatusAuth { facts }))
    }

    async fn authorization_body(state: StatusHttpState, authorization: Option<&str>) -> Value {
        let response = state.response_with_authorization(authorization).await;
        assert_eq!(response.status(), StatusCode::OK);
        let body = axum::body::to_bytes(response.into_body(), usize::MAX)
            .await
            .expect("status body is readable");
        serde_json::from_slice(&body).expect("status response is JSON")
    }

    #[tokio::test]
    async fn trusted_dashboard_user_receives_docs_and_api_info() {
        let body = authorization_body(
            state_with_auth(Some(DashboardSelfUserFacts {
                paid_amount: 100.0,
                paid_activation_complete: true,
                ..DashboardSelfUserFacts::default()
            })),
            Some("valid-token"),
        )
        .await;
        assert_eq!(body["data"]["docs_access"], true);
        assert_eq!(body["data"]["docs_link"], "https://docs.example.test");
        assert_eq!(body["data"]["api_info_enabled"], true);
        assert_eq!(body["data"]["api_info"], json!([{"title": "API"}]));
    }

    #[tokio::test]
    async fn local_activation_without_trust_keeps_docs_closed() {
        let body = authorization_body(
            state_with_auth(Some(DashboardSelfUserFacts {
                local_acceptance: true,
                ..DashboardSelfUserFacts::default()
            })),
            Some("valid-token"),
        )
        .await;
        assert_eq!(body["data"]["docs_access"], false);
        assert_eq!(body["data"]["docs_link"], "");
        assert_eq!(body["data"]["api_info_enabled"], true);
        assert_eq!(body["data"]["api_info"], json!([{"title": "API"}]));
    }

    #[tokio::test]
    async fn invalid_dashboard_credential_degrades_to_anonymous_status() {
        let body = authorization_body(state_with_auth(None), Some("invalid-token")).await;
        assert_eq!(body["success"], true);
        assert_eq!(body["ready"], true);
        assert_eq!(body["data"]["docs_access"], false);
        assert_eq!(body["data"]["docs_link"], "");
        assert_eq!(body["data"]["api_info_enabled"], false);
        assert!(body["data"].get("api_info").is_none());
    }

    #[test]
    fn postgres_options_override_types_omissions_and_oauth_projection() {
        let options = BTreeMap::from([
            ("SystemName".to_owned(), "Operator API".to_owned()),
            ("GitHubOAuthEnabled".to_owned(), "true".to_owned()),
            ("QuotaPerUnit".to_owned(), "1234.5".to_owned()),
            (
                "general_setting.quota_display_type".to_owned(),
                "TOKENS".to_owned(),
            ),
            (
                "console_setting.api_info_enabled".to_owned(),
                "false".to_owned(),
            ),
            ("console_setting.faq_enabled".to_owned(), "false".to_owned()),
            ("passkey.origins".to_owned(), "[]".to_owned()),
            ("ServerAddress".to_owned(), "https://example.com".to_owned()),
            ("legal.privacy_policy".to_owned(), "terms".to_owned()),
        ]);
        let provider = CustomOAuthInfo {
            id: 4,
            name: "Work SSO".to_owned(),
            slug: "work".to_owned(),
            icon: "building".to_owned(),
            client_id: "public-id".to_owned(),
            authorization_endpoint: "https://id.example/authorize".to_owned(),
            scopes: "openid profile".to_owned(),
        };
        let value = serde_json::to_value(StatusData::from_snapshot(
            StatusSnapshot {
                options,
                custom_oauth_providers: vec![provider],
                setup: true,
            },
            "v1.2.3",
            42,
        ))
        .expect("serialize overridden status");
        assert_eq!(value["system_name"], "Operator API");
        assert_eq!(value["github_oauth"], true);
        assert_eq!(value["quota_per_unit"], 1234.5);
        assert_eq!(value["display_in_currency"], false);
        assert_eq!(value["passkey_origins"], "https://example.com");
        assert_eq!(value["passkey_rp_id"], "example.com");
        assert_eq!(value["privacy_policy_enabled"], true);
        assert_eq!(value["setup"], true);
        assert_eq!(
            value["backend_capabilities"],
            json!({
                "bounty_notifications": true,
                "bounty_challenge_cancel": true,
                "bounty_public_read": true,
                "self_oauth_unbind": true,
                "responses_websocket": true,
            })
        );
        assert!(value.get("api_info").is_none());
        assert!(value.get("faq").is_none());
        assert_eq!(value["custom_oauth_providers"][0]["slug"], "work");
        assert!(
            value["custom_oauth_providers"][0]
                .get("client_secret")
                .is_none()
        );
    }

    #[tokio::test]
    async fn postgres_repository_reads_authoritative_options_and_enabled_providers() {
        let Some(database_url) = std::env::var("LMM_TEST_DATABASE_URL").ok() else {
            eprintln!("skipping PostgreSQL status test: LMM_TEST_DATABASE_URL is unset");
            return;
        };
        let schema = format!("status_test_{}", uuid::Uuid::new_v4().simple());
        let pool = sqlx::postgres::PgPoolOptions::new()
            .max_connections(1)
            .after_connect({
                let schema = schema.clone();
                move |connection, _metadata| {
                    let statement = format!("SET search_path TO {schema}");
                    Box::pin(async move {
                        sqlx::query(&statement).execute(connection).await?;
                        Ok(())
                    })
                }
            })
            .connect(&database_url)
            .await
            .expect("connect PostgreSQL");
        sqlx::query(&format!("CREATE SCHEMA {schema}"))
            .execute(&pool)
            .await
            .expect("create isolated schema");
        sqlx::query("CREATE TABLE options (key TEXT PRIMARY KEY, value TEXT)")
            .execute(&pool)
            .await
            .expect("create options");
        sqlx::query(
            "CREATE TABLE custom_oauth_providers (id BIGINT PRIMARY KEY, name TEXT NOT NULL, slug TEXT NOT NULL, icon TEXT, enabled BOOLEAN, client_id TEXT, authorization_endpoint TEXT, scopes TEXT)",
        )
        .execute(&pool)
        .await
        .expect("create providers");
        sqlx::query("CREATE TABLE setups (id BIGINT PRIMARY KEY)")
            .execute(&pool)
            .await
            .expect("create setups");
        sqlx::query("INSERT INTO options (key, value) VALUES ('SystemName', 'PG authoritative')")
            .execute(&pool)
            .await
            .expect("seed option");
        sqlx::query("INSERT INTO custom_oauth_providers (id, name, slug, enabled, client_id, authorization_endpoint, scopes) VALUES (1, 'Enabled', 'enabled', TRUE, 'id', 'https://id/authorize', 'openid'), (2, 'Disabled', 'disabled', FALSE, 'id2', 'https://id/authorize', 'openid')")
            .execute(&pool)
            .await
            .expect("seed providers");
        let snapshot = PgStatusRepository::new(pool.clone())
            .snapshot()
            .await
            .expect("PostgreSQL snapshot");
        assert_eq!(snapshot.options["SystemName"], "PG authoritative");
        assert_eq!(snapshot.custom_oauth_providers.len(), 1);
        assert_eq!(snapshot.custom_oauth_providers[0].slug, "enabled");
        assert!(!snapshot.setup);
        pool.close().await;
        let cleanup = sqlx::PgPool::connect(&database_url)
            .await
            .expect("cleanup connection");
        sqlx::query(&format!("DROP SCHEMA {schema} CASCADE"))
            .execute(&cleanup)
            .await
            .expect("drop isolated schema");
        cleanup.close().await;
    }
}
