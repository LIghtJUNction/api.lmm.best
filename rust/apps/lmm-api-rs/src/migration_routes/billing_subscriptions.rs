//! Legacy-compatible subscription administration without payment-provider calls.
//!
//! This module is deliberately self-contained so it can be mounted during the
//! staged migration.  PostgreSQL is authoritative; Valkey only holds derived
//! plan views and is evicted after a successful commit.

use crate::auth::{AuthErrorKind, DashboardAuth, DashboardUser};
use axum::{
    Json, Router,
    extract::{Path, State},
    http::{HeaderMap, StatusCode, header},
    response::{IntoResponse, Response},
    routing::{delete, get, post, put},
};
use secrecy::SecretString;
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use sqlx::{PgPool, Postgres, Row, Transaction};
use std::{
    collections::{BTreeSet, HashMap},
    sync::Arc,
    time::{SystemTime, UNIX_EPOCH},
};

const PLAN_CACHE_PREFIX: &str = "new-api:subscription_plan:v1:";
const PLAN_INFO_CACHE_PREFIX: &str = "new-api:subscription_plan_info:v1:";
const ADMIN_ROLE: i64 = 10;
const USER_CACHE_PREFIX: &str = "user:";
const AUTH_VERSION: &str = "864b7076dbcd0a3c01b5520316720ebf";

#[derive(Clone)]
pub struct BillingSubscriptionsState {
    pg: PgPool,
    valkey: Option<redis::Client>,
    auth: Arc<dyn DashboardAuth>,
}

impl BillingSubscriptionsState {
    #[must_use]
    pub fn new(pg: PgPool, valkey: Option<redis::Client>, auth: Arc<dyn DashboardAuth>) -> Self {
        Self { pg, valkey, auth }
    }
}

/// Routes that do not initiate payments or accept provider callbacks.
pub fn router(state: BillingSubscriptionsState) -> Router {
    Router::new()
        .route("/api/subscription/plans", get(list_enabled_plans))
        .route("/api/subscription/self", get(subscription_self))
        .route("/api/subscription/self/preference", put(update_preference))
        .route(
            "/api/subscription/admin/plans",
            get(admin_list_plans).post(admin_create_plan),
        )
        .route(
            "/api/subscription/admin/plans/{id}",
            put(admin_update_plan).patch(admin_update_plan_status),
        )
        .route(
            "/api/subscription/admin/plans/{id}/subscriptions/reset",
            post(admin_reset_plan),
        )
        .route(
            "/api/subscription/admin/bind",
            post(admin_bind_subscription),
        )
        .route(
            "/api/subscription/admin/users/{id}/subscriptions",
            get(admin_list_user_subscriptions).post(admin_create_user_subscription),
        )
        .route(
            "/api/subscription/admin/users/{id}/subscriptions/reset",
            post(admin_reset_user_subscriptions),
        )
        .route(
            "/api/subscription/admin/user_subscriptions/{id}",
            delete(admin_delete_subscription),
        )
        .route(
            "/api/subscription/admin/user_subscriptions/{id}/invalidate",
            post(admin_invalidate_subscription),
        )
        .with_state(state)
}

#[derive(Serialize)]
struct Envelope<T: Serialize> {
    success: bool,
    message: &'static str,
    #[serde(skip_serializing_if = "Option::is_none")]
    data: Option<T>,
}

fn ok<T: Serialize>(data: T) -> Response {
    Json(Envelope {
        success: true,
        message: "",
        data: Some(data),
    })
    .into_response()
}
fn empty_ok() -> Response {
    Json(Envelope::<()> {
        success: true,
        message: "",
        data: None,
    })
    .into_response()
}
fn failure(status: StatusCode, message: &'static str) -> Response {
    // Gin's ApiError and ApiErrorMsg deliberately use HTTP 200 for business
    // failures. Authentication middleware is the only caller that supplies a
    // non-200 status to this module.
    let status = match status {
        StatusCode::UNAUTHORIZED | StatusCode::FORBIDDEN => status,
        _ => StatusCode::OK,
    };
    (
        status,
        Json(Envelope::<()> {
            success: false,
            message,
            data: None,
        }),
    )
        .into_response()
}

fn with_auth_version(mut response: Response) -> Response {
    response.headers_mut().insert(
        "auth-version",
        axum::http::HeaderValue::from_static(AUTH_VERSION),
    );
    response
}

fn auth_failure(status: StatusCode, code: &'static str, message: &'static str) -> Response {
    (
        status,
        Json(json!({"success": false, "code": code, "message": message})),
    )
        .into_response()
}

async fn identity(
    state: &BillingSubscriptionsState,
    headers: &HeaderMap,
) -> Result<DashboardUser, Response> {
    let Some(value) = headers
        .get(header::AUTHORIZATION)
        .and_then(|value| value.to_str().ok())
        .and_then(|value| value.strip_prefix("Bearer "))
        .filter(|value| !value.is_empty())
    else {
        return Err(failure(
            StatusCode::UNAUTHORIZED,
            "Unauthorized, invalid access token",
        ));
    };
    let user = state
        .auth
        .self_user(SecretString::from(value.to_owned()))
        .await
        .map_err(|error| match error.kind {
            AuthErrorKind::Unauthorized
            | AuthErrorKind::TokenExpired
            | AuthErrorKind::SessionRevoked => auth_failure(
                StatusCode::UNAUTHORIZED,
                "AUTH_UNAUTHORIZED",
                "Unauthorized, invalid access token",
            ),
            _ => auth_failure(
                StatusCode::INTERNAL_SERVER_ERROR,
                "AUTH_INTERNAL_ERROR",
                "Database error, please contact the administrator",
            ),
        })?;
    if user.status != 1 {
        return Err(auth_failure(
            StatusCode::UNAUTHORIZED,
            "AUTH_USER_DISABLED",
            "User has been banned",
        ));
    }
    if user.username.trim().is_empty() || !matches!(user.role, 0 | 1 | 10 | 100) {
        return Err(auth_failure(
            StatusCode::UNAUTHORIZED,
            "AUTH_USER_INVALID",
            "Unauthorized, invalid user info",
        ));
    }
    if user.role < 1 {
        return Err(auth_failure(
            StatusCode::FORBIDDEN,
            "AUTH_INSUFFICIENT_PRIVILEGE",
            "Unauthorized, insufficient privileges",
        ));
    }
    Ok(user)
}

async fn admin(
    state: &BillingSubscriptionsState,
    headers: &HeaderMap,
) -> Result<DashboardUser, Response> {
    let user = identity(state, headers).await?;
    if user.role < ADMIN_ROLE {
        return Err(auth_failure(
            StatusCode::FORBIDDEN,
            "AUTH_INSUFFICIENT_PRIVILEGE",
            "Unauthorized, insufficient privileges",
        ));
    }
    Ok(user)
}

async fn payment_compliance_confirmed(pg: &PgPool) -> Result<bool, sqlx::Error> {
    let rows = sqlx::query(
        "SELECT key, value FROM options WHERE key IN ('payment_setting.compliance_confirmed', 'payment_setting.compliance_terms_version')",
    )
    .fetch_all(pg)
    .await?;
    let values = rows
        .iter()
        .map(|row| {
            Ok((
                row.try_get::<String, _>("key")?,
                row.try_get::<String, _>("value")?,
            ))
        })
        .collect::<Result<HashMap<_, _>, sqlx::Error>>()?;
    Ok(values
        .get("payment_setting.compliance_confirmed")
        .is_some_and(|value| value.eq_ignore_ascii_case("true") || value == "1")
        && values
            .get("payment_setting.compliance_terms_version")
            .is_some_and(|value| value == "v1"))
}

fn compliance_message(headers: &HeaderMap) -> &'static str {
    let locale = headers
        .get(header::ACCEPT_LANGUAGE)
        .and_then(|value| value.to_str().ok())
        .unwrap_or_default()
        .to_ascii_lowercase();
    if locale.starts_with("zh-tw") {
        "支付、兌換碼、訂閱方案和邀請返利功能已停用。管理員需先確認合規聲明後方可啟用。"
    } else if locale.starts_with("zh") {
        "支付、兑换码、订阅计划和邀请返利功能已禁用。管理员需先确认合规声明后方可启用。"
    } else {
        "Payment, redemption, subscription, and invitation reward features are disabled. The administrator must confirm compliance terms before enabling them."
    }
}

async fn require_payment_compliance(
    state: &BillingSubscriptionsState,
    headers: &HeaderMap,
) -> Result<(), Response> {
    match payment_compliance_confirmed(&state.pg).await {
        Ok(true) => Ok(()),
        Ok(false) => Err(failure(StatusCode::OK, compliance_message(headers))),
        Err(_) => Err(failure(StatusCode::INTERNAL_SERVER_ERROR, "系统错误")),
    }
}

#[derive(Clone, Debug, Serialize)]
struct Plan {
    id: i64,
    title: String,
    subtitle: String,
    price_amount: f64,
    currency: String,
    duration_unit: String,
    duration_value: i64,
    custom_seconds: i64,
    enabled: bool,
    sort_order: i64,
    allow_balance_pay: bool,
    allow_wallet_overflow: bool,
    stripe_price_id: String,
    creem_product_id: String,
    waffo_pancake_product_id: String,
    max_purchase_per_user: i64,
    total_amount: i64,
    upgrade_group: String,
    downgrade_group: String,
    quota_reset_period: String,
    quota_reset_custom_seconds: i64,
    created_at: i64,
    updated_at: i64,
}

#[derive(Serialize)]
struct PlanView {
    plan: Plan,
}
#[derive(Deserialize)]
struct PlanRequest {
    plan: PlanInput,
}
#[derive(Deserialize)]
struct PlanInput {
    title: String,
    #[serde(default)]
    subtitle: String,
    price_amount: f64,
    #[serde(default)]
    currency: String,
    #[serde(default)]
    duration_unit: String,
    #[serde(default)]
    duration_value: i64,
    #[serde(default)]
    custom_seconds: i64,
    #[serde(default = "true_value")]
    enabled: bool,
    #[serde(default)]
    sort_order: i64,
    allow_balance_pay: Option<bool>,
    allow_wallet_overflow: Option<bool>,
    #[serde(default)]
    stripe_price_id: String,
    #[serde(default)]
    creem_product_id: String,
    #[serde(default)]
    waffo_pancake_product_id: String,
    #[serde(default)]
    max_purchase_per_user: i64,
    #[serde(default)]
    total_amount: i64,
    #[serde(default)]
    upgrade_group: String,
    #[serde(default)]
    downgrade_group: String,
    #[serde(default)]
    quota_reset_period: String,
    #[serde(default)]
    quota_reset_custom_seconds: i64,
}
fn true_value() -> bool {
    true
}

impl PlanInput {
    fn normalize(mut self) -> Result<Self, &'static str> {
        self.title = self.title.trim().to_owned();
        self.upgrade_group = self.upgrade_group.trim().to_owned();
        self.downgrade_group = self.downgrade_group.trim().to_owned();
        if self.title.is_empty() {
            return Err("套餐标题不能为空");
        }
        if !(0.0..=9999.0).contains(&self.price_amount) {
            return Err(if self.price_amount < 0.0 {
                "价格不能为负数"
            } else {
                "价格不能超过9999"
            });
        }
        if self.max_purchase_per_user < 0 {
            return Err("购买上限不能为负数");
        }
        if self.total_amount < 0 {
            return Err("总额度不能为负数");
        }
        self.currency = "USD".to_owned();
        if self.duration_unit.is_empty() {
            self.duration_unit = "month".to_owned();
        }
        if !matches!(
            self.duration_unit.as_str(),
            "year" | "month" | "day" | "hour" | "custom"
        ) {
            return Err("无效的订阅周期");
        }
        if self.duration_unit == "custom" {
            if self.custom_seconds <= 0 {
                return Err("自定义时长需大于0秒");
            }
        } else if self.duration_value <= 0 {
            self.duration_value = 1;
        }
        self.quota_reset_period = match self.quota_reset_period.trim() {
            "daily" => "daily",
            "weekly" => "weekly",
            "monthly" => "monthly",
            "custom" => "custom",
            _ => "never",
        }
        .to_owned();
        if self.quota_reset_period == "custom" && self.quota_reset_custom_seconds <= 0 {
            return Err("自定义重置周期需大于0秒");
        }
        Ok(self)
    }
}

async fn validate_plan_groups(pg: &PgPool, input: &PlanInput) -> Result<(), &'static str> {
    if input.upgrade_group.is_empty() && input.downgrade_group.is_empty() {
        return Ok(());
    }
    let groups: Option<String> =
        sqlx::query_scalar("SELECT value FROM options WHERE key='GroupRatio'")
            .fetch_optional(pg)
            .await
            .map_err(|_| "系统错误")?;
    let groups = groups
        .and_then(|value| serde_json::from_str::<HashMap<String, Value>>(&value).ok())
        .ok_or("升级分组不存在")?;
    if !input.upgrade_group.is_empty() && !groups.contains_key(&input.upgrade_group) {
        return Err("升级分组不存在");
    }
    if !input.downgrade_group.is_empty() && !groups.contains_key(&input.downgrade_group) {
        return Err("降级分组不存在");
    }
    Ok(())
}

async fn list_enabled_plans(
    State(state): State<BillingSubscriptionsState>,
    headers: HeaderMap,
) -> Response {
    if let Err(response) = identity(&state, &headers).await {
        return response;
    }
    match payment_compliance_confirmed(&state.pg).await {
        Ok(false) => return with_auth_version(ok(Vec::<PlanView>::new())),
        Err(_) => {
            return with_auth_version(failure(StatusCode::INTERNAL_SERVER_ERROR, "系统错误"));
        }
        Ok(true) => {}
    }
    with_auth_version(
        plans(&state.pg, true)
            .await
            .map(|plans| {
                ok(plans
                    .into_iter()
                    .map(|plan| PlanView { plan })
                    .collect::<Vec<_>>())
            })
            .unwrap_or_else(|_| failure(StatusCode::INTERNAL_SERVER_ERROR, "系统错误")),
    )
}
async fn admin_list_plans(
    State(state): State<BillingSubscriptionsState>,
    headers: HeaderMap,
) -> Response {
    if let Err(response) = admin(&state, &headers).await {
        return response;
    }
    with_auth_version(
        plans(&state.pg, false)
            .await
            .map(|plans| {
                ok(plans
                    .into_iter()
                    .map(|plan| PlanView { plan })
                    .collect::<Vec<_>>())
            })
            .unwrap_or_else(|_| failure(StatusCode::INTERNAL_SERVER_ERROR, "系统错误")),
    )
}

async fn plans(pg: &PgPool, enabled_only: bool) -> Result<Vec<Plan>, sqlx::Error> {
    let sql = if enabled_only {
        format!("{PLAN_SELECT} WHERE enabled = TRUE ORDER BY sort_order DESC, id DESC")
    } else {
        format!("{PLAN_SELECT} ORDER BY sort_order DESC, id DESC")
    };
    sqlx::query(&sql)
        .fetch_all(pg)
        .await?
        .iter()
        .map(plan_from_row)
        .collect()
}
const PLAN_SELECT: &str = "SELECT id, title, COALESCE(subtitle, '') subtitle, price_amount::FLOAT8 price_amount, COALESCE(currency, 'USD') currency, COALESCE(duration_unit, 'month') duration_unit, COALESCE(duration_value, 1) duration_value, COALESCE(custom_seconds, 0) custom_seconds, enabled, COALESCE(sort_order, 0) sort_order, COALESCE(allow_balance_pay, TRUE) allow_balance_pay, COALESCE(allow_wallet_overflow, TRUE) allow_wallet_overflow, COALESCE(stripe_price_id, '') stripe_price_id, COALESCE(creem_product_id, '') creem_product_id, COALESCE(waffo_pancake_product_id, '') waffo_pancake_product_id, COALESCE(max_purchase_per_user, 0) max_purchase_per_user, COALESCE(total_amount, 0) total_amount, COALESCE(upgrade_group, '') upgrade_group, COALESCE(downgrade_group, '') downgrade_group, COALESCE(quota_reset_period, 'never') quota_reset_period, COALESCE(quota_reset_custom_seconds, 0) quota_reset_custom_seconds, COALESCE(created_at, 0) created_at, COALESCE(updated_at, 0) updated_at FROM subscription_plans";
fn plan_from_row(row: &sqlx::postgres::PgRow) -> Result<Plan, sqlx::Error> {
    Ok(Plan {
        id: row.try_get("id")?,
        title: row.try_get("title")?,
        subtitle: row.try_get("subtitle")?,
        price_amount: row.try_get("price_amount")?,
        currency: row.try_get("currency")?,
        duration_unit: row.try_get("duration_unit")?,
        duration_value: row.try_get("duration_value")?,
        custom_seconds: row.try_get("custom_seconds")?,
        enabled: row.try_get("enabled")?,
        sort_order: row.try_get("sort_order")?,
        allow_balance_pay: row.try_get("allow_balance_pay")?,
        allow_wallet_overflow: row.try_get("allow_wallet_overflow")?,
        stripe_price_id: row.try_get("stripe_price_id")?,
        creem_product_id: row.try_get("creem_product_id")?,
        waffo_pancake_product_id: row.try_get("waffo_pancake_product_id")?,
        max_purchase_per_user: row.try_get("max_purchase_per_user")?,
        total_amount: row.try_get("total_amount")?,
        upgrade_group: row.try_get("upgrade_group")?,
        downgrade_group: row.try_get("downgrade_group")?,
        quota_reset_period: row.try_get("quota_reset_period")?,
        quota_reset_custom_seconds: row.try_get("quota_reset_custom_seconds")?,
        created_at: row.try_get("created_at")?,
        updated_at: row.try_get("updated_at")?,
    })
}

async fn admin_create_plan(
    State(state): State<BillingSubscriptionsState>,
    headers: HeaderMap,
    Json(input): Json<PlanRequest>,
) -> Response {
    if let Err(response) = admin(&state, &headers).await {
        return response;
    }
    if let Err(response) = require_payment_compliance(&state, &headers).await {
        return with_auth_version(response);
    }
    let input = match input.plan.normalize() {
        Ok(input) => input,
        Err(message) => return failure(StatusCode::BAD_REQUEST, message),
    };
    if let Err(message) = validate_plan_groups(&state.pg, &input).await {
        return with_auth_version(failure(StatusCode::BAD_REQUEST, message));
    }
    let now = now();
    let row = sqlx::query("INSERT INTO subscription_plans (title, subtitle, price_amount, currency, duration_unit, duration_value, custom_seconds, enabled, sort_order, allow_balance_pay, allow_wallet_overflow, stripe_price_id, creem_product_id, waffo_pancake_product_id, max_purchase_per_user, total_amount, upgrade_group, downgrade_group, quota_reset_period, quota_reset_custom_seconds, created_at, updated_at) VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11,$12,$13,$14,$15,$16,$17,$18,$19,$20,$21,$21) RETURNING id")
        .bind(&input.title).bind(&input.subtitle).bind(input.price_amount).bind(&input.currency).bind(&input.duration_unit).bind(input.duration_value).bind(input.custom_seconds).bind(input.enabled).bind(input.sort_order).bind(input.allow_balance_pay.unwrap_or(true)).bind(input.allow_wallet_overflow.unwrap_or(true)).bind(&input.stripe_price_id).bind(&input.creem_product_id).bind(&input.waffo_pancake_product_id).bind(input.max_purchase_per_user).bind(input.total_amount).bind(&input.upgrade_group).bind(&input.downgrade_group).bind(&input.quota_reset_period).bind(input.quota_reset_custom_seconds).bind(now).fetch_one(&state.pg).await;
    match row {
        Ok(row) => {
            let id: i64 = match row.try_get("id") {
                Ok(id) => id,
                Err(_) => return failure(StatusCode::INTERNAL_SERVER_ERROR, "系统错误"),
            };
            evict_plan(&state, id).await;
            with_auth_version(match plan(&state.pg, id).await {
                Ok(plan) => ok(plan),
                Err(_) => failure(StatusCode::INTERNAL_SERVER_ERROR, "系统错误"),
            })
        }
        Err(_) => failure(StatusCode::INTERNAL_SERVER_ERROR, "系统错误"),
    }
}

async fn admin_update_plan(
    State(state): State<BillingSubscriptionsState>,
    headers: HeaderMap,
    Path(id): Path<i64>,
    Json(input): Json<PlanRequest>,
) -> Response {
    if let Err(response) = admin(&state, &headers).await {
        return response;
    }
    if let Err(response) = require_payment_compliance(&state, &headers).await {
        return with_auth_version(response);
    }
    if id <= 0 {
        return failure(StatusCode::BAD_REQUEST, "无效的ID");
    }
    let input = match input.plan.normalize() {
        Ok(input) => input,
        Err(message) => return failure(StatusCode::BAD_REQUEST, message),
    };
    if let Err(message) = validate_plan_groups(&state.pg, &input).await {
        return with_auth_version(failure(StatusCode::BAD_REQUEST, message));
    }
    let updated = sqlx::query("UPDATE subscription_plans SET title=$2, subtitle=$3, price_amount=$4, currency=$5, duration_unit=$6, duration_value=$7, custom_seconds=$8, enabled=$9, sort_order=$10, allow_balance_pay=COALESCE($11, allow_balance_pay), allow_wallet_overflow=COALESCE($12, allow_wallet_overflow), stripe_price_id=$13, creem_product_id=$14, waffo_pancake_product_id=$15, max_purchase_per_user=$16, total_amount=$17, upgrade_group=$18, downgrade_group=$19, quota_reset_period=$20, quota_reset_custom_seconds=$21, updated_at=$22 WHERE id=$1")
        .bind(id).bind(&input.title).bind(&input.subtitle).bind(input.price_amount).bind(&input.currency).bind(&input.duration_unit).bind(input.duration_value).bind(input.custom_seconds).bind(input.enabled).bind(input.sort_order).bind(input.allow_balance_pay).bind(input.allow_wallet_overflow).bind(&input.stripe_price_id).bind(&input.creem_product_id).bind(&input.waffo_pancake_product_id).bind(input.max_purchase_per_user).bind(input.total_amount).bind(&input.upgrade_group).bind(&input.downgrade_group).bind(&input.quota_reset_period).bind(input.quota_reset_custom_seconds).bind(now()).execute(&state.pg).await;
    match updated {
        Ok(_) => {
            evict_plan(&state, id).await;
            with_auth_version(empty_ok())
        }
        Err(_) => failure(StatusCode::INTERNAL_SERVER_ERROR, "系统错误"),
    }
}

#[derive(Deserialize)]
struct StatusRequest {
    enabled: Option<bool>,
}
async fn admin_update_plan_status(
    State(state): State<BillingSubscriptionsState>,
    headers: HeaderMap,
    Path(id): Path<i64>,
    Json(input): Json<StatusRequest>,
) -> Response {
    if let Err(response) = admin(&state, &headers).await {
        return response;
    }
    if let Err(response) = require_payment_compliance(&state, &headers).await {
        return with_auth_version(response);
    }
    if id <= 0 {
        return with_auth_version(failure(StatusCode::BAD_REQUEST, "无效的ID"));
    }
    let Some(enabled) = input.enabled else {
        return failure(StatusCode::BAD_REQUEST, "参数错误");
    };
    match sqlx::query("UPDATE subscription_plans SET enabled=$2, updated_at=$3 WHERE id=$1")
        .bind(id)
        .bind(enabled)
        .bind(now())
        .execute(&state.pg)
        .await
    {
        Ok(_) => {
            evict_plan(&state, id).await;
            with_auth_version(empty_ok())
        }
        Err(_) => failure(StatusCode::INTERNAL_SERVER_ERROR, "系统错误"),
    }
}

#[derive(Deserialize)]
struct PreferenceRequest {
    billing_preference: String,
}
async fn update_preference(
    State(state): State<BillingSubscriptionsState>,
    headers: HeaderMap,
    Json(input): Json<PreferenceRequest>,
) -> Response {
    let user = match identity(&state, &headers).await {
        Ok(user) => user,
        Err(response) => return response,
    };
    let preference = normalize_preference(&input.billing_preference);
    let updated = sqlx::query("UPDATE users SET setting = jsonb_set(COALESCE(NULLIF(setting, '')::jsonb, '{}'::jsonb), '{billing_preference}', to_jsonb($2::text), TRUE) WHERE id = $1 AND deleted_at IS NULL").bind(user.id).bind(preference).execute(&state.pg).await;
    match updated {
        Ok(result) if result.rows_affected() == 0 => {
            with_auth_version(failure(StatusCode::NOT_FOUND, "用户不存在"))
        }
        Ok(_) => with_auth_version(ok(json!({"billing_preference": preference}))),
        Err(_) => with_auth_version(failure(StatusCode::INTERNAL_SERVER_ERROR, "系统错误")),
    }
}
fn normalize_preference(value: &str) -> &'static str {
    match value.trim() {
        "subscription" => "subscription",
        _ => "quota",
    }
}

async fn subscription_self(
    State(state): State<BillingSubscriptionsState>,
    headers: HeaderMap,
) -> Response {
    let user = match identity(&state, &headers).await {
        Ok(user) => user,
        Err(response) => return response,
    };
    let preference = serde_json::from_str::<Value>(&user.setting)
        .ok()
        .and_then(|setting| {
            setting
                .get("billing_preference")
                .and_then(Value::as_str)
                .map(normalize_preference)
        })
        .unwrap_or("quota");
    let all = match subscriptions(&state.pg, user.id, false).await {
        Ok(subscriptions) => subscriptions,
        Err(_) => return with_auth_version(failure(StatusCode::INTERNAL_SERVER_ERROR, "系统错误")),
    };
    let active = match subscriptions(&state.pg, user.id, true).await {
        Ok(subscriptions) => subscriptions,
        Err(_) => return with_auth_version(failure(StatusCode::INTERNAL_SERVER_ERROR, "系统错误")),
    };
    with_auth_version(ok(
        json!({"billing_preference": preference, "subscriptions": active, "all_subscriptions": all}),
    ))
}

#[derive(Serialize)]
struct Subscription {
    id: i64,
    user_id: i64,
    plan_id: i64,
    amount_total: i64,
    amount_used: i64,
    start_time: i64,
    end_time: i64,
    status: String,
    source: String,
    last_reset_time: i64,
    next_reset_time: i64,
    upgrade_group: String,
    prev_user_group: String,
    downgrade_group: String,
    allow_wallet_overflow: bool,
    created_at: i64,
    updated_at: i64,
}
#[derive(Serialize)]
struct SubscriptionView {
    subscription: Subscription,
}
const SUB_SELECT: &str = "SELECT id,user_id,plan_id,COALESCE(amount_total,0) amount_total,COALESCE(amount_used,0) amount_used,COALESCE(start_time,0) start_time,COALESCE(end_time,0) end_time,status,COALESCE(source,'') source,COALESCE(last_reset_time,0) last_reset_time,COALESCE(next_reset_time,0) next_reset_time,COALESCE(upgrade_group,'') upgrade_group,COALESCE(prev_user_group,'') prev_user_group,COALESCE(downgrade_group,'') downgrade_group,COALESCE(allow_wallet_overflow,TRUE) allow_wallet_overflow,COALESCE(created_at,0) created_at,COALESCE(updated_at,0) updated_at FROM user_subscriptions";
fn subscription_from_row(row: &sqlx::postgres::PgRow) -> Result<Subscription, sqlx::Error> {
    Ok(Subscription {
        id: row.try_get("id")?,
        user_id: row.try_get("user_id")?,
        plan_id: row.try_get("plan_id")?,
        amount_total: row.try_get("amount_total")?,
        amount_used: row.try_get("amount_used")?,
        start_time: row.try_get("start_time")?,
        end_time: row.try_get("end_time")?,
        status: row.try_get("status")?,
        source: row.try_get("source")?,
        last_reset_time: row.try_get("last_reset_time")?,
        next_reset_time: row.try_get("next_reset_time")?,
        upgrade_group: row.try_get("upgrade_group")?,
        prev_user_group: row.try_get("prev_user_group")?,
        downgrade_group: row.try_get("downgrade_group")?,
        allow_wallet_overflow: row.try_get("allow_wallet_overflow")?,
        created_at: row.try_get("created_at")?,
        updated_at: row.try_get("updated_at")?,
    })
}
async fn subscriptions(
    pg: &PgPool,
    user_id: i64,
    active_only: bool,
) -> Result<Vec<SubscriptionView>, sqlx::Error> {
    let sql = if active_only {
        format!(
            "{SUB_SELECT} WHERE user_id=$1 AND status='active' AND end_time > $2 ORDER BY end_time DESC,id DESC"
        )
    } else {
        format!("{SUB_SELECT} WHERE user_id=$1 ORDER BY end_time DESC,id DESC")
    };
    let mut query = sqlx::query(&sql).bind(user_id);
    if active_only {
        query = query.bind(now());
    }
    Ok(query
        .fetch_all(pg)
        .await?
        .iter()
        .map(subscription_from_row)
        .collect::<Result<Vec<_>, _>>()?
        .into_iter()
        .map(|subscription| SubscriptionView { subscription })
        .collect())
}

#[derive(Deserialize)]
struct BindRequest {
    user_id: i64,
    plan_id: i64,
}
#[derive(Deserialize)]
struct CreateSubscriptionRequest {
    plan_id: i64,
}
async fn admin_bind_subscription(
    State(state): State<BillingSubscriptionsState>,
    headers: HeaderMap,
    Json(input): Json<BindRequest>,
) -> Response {
    if let Err(response) = admin(&state, &headers).await {
        return response;
    }
    if let Err(response) = require_payment_compliance(&state, &headers).await {
        return with_auth_version(response);
    }
    with_auth_version(bind(&state, input.user_id, input.plan_id).await)
}
async fn admin_create_user_subscription(
    State(state): State<BillingSubscriptionsState>,
    headers: HeaderMap,
    Path(user_id): Path<i64>,
    Json(input): Json<CreateSubscriptionRequest>,
) -> Response {
    if let Err(response) = admin(&state, &headers).await {
        return response;
    }
    if let Err(response) = require_payment_compliance(&state, &headers).await {
        return with_auth_version(response);
    }
    if user_id <= 0 {
        return with_auth_version(failure(StatusCode::BAD_REQUEST, "无效的用户ID"));
    }
    with_auth_version(bind(&state, user_id, input.plan_id).await)
}
async fn bind(state: &BillingSubscriptionsState, user_id: i64, plan_id: i64) -> Response {
    if user_id <= 0 || plan_id <= 0 {
        return failure(StatusCode::BAD_REQUEST, "参数错误");
    }
    let mut tx = match state.pg.begin().await {
        Ok(tx) => tx,
        Err(_) => return failure(StatusCode::INTERNAL_SERVER_ERROR, "系统错误"),
    };
    let plan = match locked_plan(&mut tx, plan_id).await {
        Ok(Some(plan)) => plan,
        Ok(None) => return failure(StatusCode::NOT_FOUND, "套餐不存在"),
        Err(_) => return failure(StatusCode::INTERNAL_SERVER_ERROR, "系统错误"),
    };
    match create_subscription(&mut tx, user_id, &plan, "admin").await {
        Ok(message) => match tx.commit().await {
            Ok(()) => {
                evict_plan(state, plan_id).await;
                evict_user(state, user_id).await;
                if let Some(message) = message {
                    ok(json!({"message": message}))
                } else {
                    empty_ok()
                }
            }
            Err(_) => failure(StatusCode::INTERNAL_SERVER_ERROR, "系统错误"),
        },
        Err(message) => failure(StatusCode::BAD_REQUEST, message),
    }
}

async fn plan(pg: &PgPool, id: i64) -> Result<Plan, sqlx::Error> {
    sqlx::query(&format!("{PLAN_SELECT} WHERE id=$1"))
        .bind(id)
        .fetch_one(pg)
        .await
        .and_then(|row| plan_from_row(&row))
}
async fn locked_plan(
    tx: &mut Transaction<'_, Postgres>,
    id: i64,
) -> Result<Option<Plan>, sqlx::Error> {
    sqlx::query(&format!("{PLAN_SELECT} WHERE id=$1 FOR UPDATE"))
        .bind(id)
        .fetch_optional(&mut **tx)
        .await?
        .map(|row| plan_from_row(&row))
        .transpose()
}
async fn create_subscription(
    tx: &mut Transaction<'_, Postgres>,
    user_id: i64,
    plan: &Plan,
    source: &str,
) -> Result<Option<String>, &'static str> {
    let user =
        sqlx::query("SELECT \"group\" FROM users WHERE id=$1 AND deleted_at IS NULL FOR UPDATE")
            .bind(user_id)
            .fetch_optional(&mut **tx)
            .await
            .map_err(|_| "系统错误")?
            .ok_or("用户不存在")?;
    if plan.max_purchase_per_user > 0 {
        let count: i64 = sqlx::query_scalar(
            "SELECT COUNT(*) FROM user_subscriptions WHERE user_id=$1 AND plan_id=$2",
        )
        .bind(user_id)
        .bind(plan.id)
        .fetch_one(&mut **tx)
        .await
        .map_err(|_| "系统错误")?;
        if count >= plan.max_purchase_per_user {
            return Err("已达到该套餐购买上限");
        }
    }
    let current_group: String = user.try_get("group").map_err(|_| "系统错误")?;
    let start = now();
    let end = end_time(start, plan)?;
    let next = next_reset(start, end, plan);
    let changed = !plan.upgrade_group.is_empty() && plan.upgrade_group != current_group;
    if changed {
        sqlx::query("UPDATE users SET \"group\"=$2 WHERE id=$1")
            .bind(user_id)
            .bind(&plan.upgrade_group)
            .execute(&mut **tx)
            .await
            .map_err(|_| "系统错误")?;
    }
    sqlx::query("INSERT INTO user_subscriptions (user_id,plan_id,amount_total,amount_used,start_time,end_time,status,source,last_reset_time,next_reset_time,upgrade_group,prev_user_group,downgrade_group,allow_wallet_overflow,created_at,updated_at) VALUES ($1,$2,$3,0,$4,$5,'active',$6,$7,$8,$9,$10,$11,$12,$4,$4)").bind(user_id).bind(plan.id).bind(plan.total_amount).bind(start).bind(end).bind(source).bind(if next > 0 { start } else { 0 }).bind(next).bind(&plan.upgrade_group).bind(if changed { &current_group } else { "" }).bind(&plan.downgrade_group).bind(plan.allow_wallet_overflow).execute(&mut **tx).await.map_err(|_| "系统错误")?;
    Ok(changed.then(|| format!("用户分组将升级到 {}", plan.upgrade_group)))
}
fn end_time(start: i64, plan: &Plan) -> Result<i64, &'static str> {
    let seconds = match plan.duration_unit.as_str() {
        "year" => plan.duration_value.checked_mul(365 * 86_400),
        "month" => plan.duration_value.checked_mul(30 * 86_400),
        "day" => plan.duration_value.checked_mul(86_400),
        "hour" => plan.duration_value.checked_mul(3_600),
        "custom" => Some(plan.custom_seconds),
        _ => None,
    }
    .ok_or("无效的订阅周期")?;
    start.checked_add(seconds).ok_or("无效的订阅周期")
}
fn next_reset(start: i64, end: i64, plan: &Plan) -> i64 {
    let seconds = match plan.quota_reset_period.as_str() {
        "daily" => 86_400,
        "weekly" => 7 * 86_400,
        "monthly" => 30 * 86_400,
        "custom" => plan.quota_reset_custom_seconds,
        _ => 0,
    };
    let next = start.saturating_add(seconds);
    if seconds > 0 && next <= end { next } else { 0 }
}

#[derive(Deserialize)]
struct ResetRequest {
    plan_id: Option<i64>,
    advance_reset_time: Option<bool>,
}
#[derive(Serialize)]
struct ResetResult {
    plan_id: i64,
    matched_count: i64,
    reset_count: i64,
    user_count: i64,
    advance_reset_time: bool,
}
async fn admin_reset_user_subscriptions(
    State(state): State<BillingSubscriptionsState>,
    headers: HeaderMap,
    Path(user_id): Path<i64>,
    Json(input): Json<ResetRequest>,
) -> Response {
    if let Err(response) = admin(&state, &headers).await {
        return response;
    }
    if user_id <= 0 {
        return with_auth_version(failure(StatusCode::BAD_REQUEST, "无效的用户ID"));
    }
    let Some(plan_id) = input.plan_id else {
        return failure(StatusCode::BAD_REQUEST, "参数错误");
    };
    with_auth_version(
        reset(
            &state,
            Some(user_id),
            plan_id,
            input.advance_reset_time.unwrap_or(true),
        )
        .await,
    )
}
async fn admin_reset_plan(
    State(state): State<BillingSubscriptionsState>,
    headers: HeaderMap,
    Path(plan_id): Path<i64>,
    Json(input): Json<ResetRequest>,
) -> Response {
    if let Err(response) = admin(&state, &headers).await {
        return response;
    }
    if plan_id <= 0 {
        return with_auth_version(failure(StatusCode::BAD_REQUEST, "无效的ID"));
    }
    with_auth_version(
        reset(
            &state,
            None,
            plan_id,
            input.advance_reset_time.unwrap_or(true),
        )
        .await,
    )
}
async fn reset(
    state: &BillingSubscriptionsState,
    user_id: Option<i64>,
    plan_id: i64,
    advance: bool,
) -> Response {
    let mut tx = match state.pg.begin().await {
        Ok(tx) => tx,
        Err(_) => return failure(StatusCode::INTERNAL_SERVER_ERROR, "系统错误"),
    };
    let plan = match locked_plan(&mut tx, plan_id).await {
        Ok(Some(plan)) => plan,
        Ok(None) => return failure(StatusCode::NOT_FOUND, "套餐不存在"),
        Err(_) => return failure(StatusCode::INTERNAL_SERVER_ERROR, "系统错误"),
    };
    let current = now();
    let rows = match user_id { Some(user) => sqlx::query(&format!("{SUB_SELECT} WHERE user_id=$1 AND plan_id=$2 AND status='active' AND end_time>$3 ORDER BY end_time,id FOR UPDATE")).bind(user).bind(plan_id).bind(current).fetch_all(&mut *tx).await, None => sqlx::query(&format!("{SUB_SELECT} WHERE plan_id=$1 AND status='active' AND end_time>$2 ORDER BY user_id,end_time,id FOR UPDATE")).bind(plan_id).bind(current).fetch_all(&mut *tx).await };
    let rows = match rows {
        Ok(rows) => rows,
        Err(_) => return failure(StatusCode::INTERNAL_SERVER_ERROR, "系统错误"),
    };
    if user_id.is_some() && rows.is_empty() {
        return failure(StatusCode::BAD_REQUEST, "该用户没有有效的此套餐订阅");
    }
    let users = match rows
        .iter()
        .map(|row| row.try_get::<i64, _>("user_id"))
        .collect::<Result<BTreeSet<_>, _>>()
    {
        Ok(users) => users,
        Err(_) => return failure(StatusCode::INTERNAL_SERVER_ERROR, "系统错误"),
    };
    for row in &rows {
        let id: i64 = match row.try_get("id") {
            Ok(id) => id,
            Err(_) => return failure(StatusCode::INTERNAL_SERVER_ERROR, "系统错误"),
        };
        let next = if advance {
            let end: i64 = match row.try_get("end_time") {
                Ok(end) => end,
                Err(_) => return failure(StatusCode::INTERNAL_SERVER_ERROR, "系统错误"),
            };
            next_reset(current, end, &plan)
        } else {
            match row.try_get("next_reset_time") {
                Ok(next) => next,
                Err(_) => return failure(StatusCode::INTERNAL_SERVER_ERROR, "系统错误"),
            }
        };
        let last = if advance {
            if next > 0 { current } else { 0 }
        } else {
            match row.try_get("last_reset_time") {
                Ok(last) => last,
                Err(_) => return failure(StatusCode::INTERNAL_SERVER_ERROR, "系统错误"),
            }
        };
        if sqlx::query("UPDATE user_subscriptions SET amount_used=0,last_reset_time=$2,next_reset_time=$3,updated_at=$4 WHERE id=$1").bind(id).bind(last).bind(next).bind(current).execute(&mut *tx).await.is_err() { return failure(StatusCode::INTERNAL_SERVER_ERROR, "系统错误"); }
    }
    if tx.commit().await.is_err() {
        return failure(StatusCode::INTERNAL_SERVER_ERROR, "系统错误");
    };
    evict_plan(state, plan_id).await;
    ok(ResetResult {
        plan_id,
        matched_count: rows.len() as i64,
        reset_count: rows.len() as i64,
        user_count: users.len() as i64,
        advance_reset_time: advance,
    })
}

async fn admin_list_user_subscriptions(
    State(state): State<BillingSubscriptionsState>,
    headers: HeaderMap,
    Path(user_id): Path<i64>,
) -> Response {
    if let Err(response) = admin(&state, &headers).await {
        return response;
    }
    if user_id <= 0 {
        return with_auth_version(failure(StatusCode::BAD_REQUEST, "无效的用户ID"));
    }
    with_auth_version(
        subscriptions(&state.pg, user_id, false)
            .await
            .map(ok)
            .unwrap_or_else(|_| failure(StatusCode::INTERNAL_SERVER_ERROR, "系统错误")),
    )
}
async fn admin_invalidate_subscription(
    State(state): State<BillingSubscriptionsState>,
    headers: HeaderMap,
    Path(id): Path<i64>,
) -> Response {
    if let Err(response) = admin(&state, &headers).await {
        return response;
    }
    with_auth_version(change_subscription_status(&state, id, true).await)
}
async fn admin_delete_subscription(
    State(state): State<BillingSubscriptionsState>,
    headers: HeaderMap,
    Path(id): Path<i64>,
) -> Response {
    if let Err(response) = admin(&state, &headers).await {
        return response;
    }
    with_auth_version(change_subscription_status(&state, id, false).await)
}
async fn change_subscription_status(
    state: &BillingSubscriptionsState,
    id: i64,
    invalidate: bool,
) -> Response {
    if id <= 0 {
        return failure(StatusCode::BAD_REQUEST, "无效的订阅ID");
    };
    let mut tx = match state.pg.begin().await {
        Ok(tx) => tx,
        Err(_) => return failure(StatusCode::INTERNAL_SERVER_ERROR, "系统错误"),
    };
    let subscription = match locked_subscription(&mut tx, id).await {
        Ok(Some(subscription)) => subscription,
        Ok(None) => return failure(StatusCode::NOT_FOUND, "订阅不存在"),
        Err(_) => return failure(StatusCode::INTERNAL_SERVER_ERROR, "系统错误"),
    };
    let current = now();
    let downgrade = match downgrade_user_group(&mut tx, &subscription, current).await {
        Ok(group) => group,
        Err(_) => return failure(StatusCode::INTERNAL_SERVER_ERROR, "系统错误"),
    };
    let mutation = if invalidate {
        sqlx::query(
            "UPDATE user_subscriptions SET status='cancelled',end_time=$2,updated_at=$2 WHERE id=$1",
        )
        .bind(id)
        .bind(current)
        .execute(&mut *tx)
        .await
    } else {
        sqlx::query("DELETE FROM user_subscriptions WHERE id=$1")
            .bind(id)
            .execute(&mut *tx)
            .await
    };
    if mutation.is_err() || tx.commit().await.is_err() {
        return failure(StatusCode::INTERNAL_SERVER_ERROR, "系统错误");
    }
    evict_user(state, subscription.user_id).await;
    match downgrade {
        Some(group) => ok(json!({"message": format!("用户分组将回退到 {group}")})),
        None => empty_ok(),
    }
}

async fn locked_subscription(
    tx: &mut Transaction<'_, Postgres>,
    id: i64,
) -> Result<Option<Subscription>, sqlx::Error> {
    sqlx::query(&format!("{SUB_SELECT} WHERE id=$1 FOR UPDATE"))
        .bind(id)
        .fetch_optional(&mut **tx)
        .await?
        .map(|row| subscription_from_row(&row))
        .transpose()
}

/// Preserve the legacy cancellation/delete ordering: lock the subscription and
/// user, keep a later active upgraded subscription, then apply an explicit
/// downgrade group or the pre-upgrade group snapshot.
async fn downgrade_user_group(
    tx: &mut Transaction<'_, Postgres>,
    subscription: &Subscription,
    current: i64,
) -> Result<Option<String>, sqlx::Error> {
    if subscription.downgrade_group.is_empty() && subscription.upgrade_group.is_empty() {
        return Ok(None);
    }
    let user = sqlx::query("SELECT \"group\" FROM users WHERE id=$1 FOR UPDATE")
        .bind(subscription.user_id)
        .fetch_one(&mut **tx)
        .await?;
    let current_group: String = user.try_get("group")?;
    let other_active: bool = sqlx::query_scalar(
        "SELECT EXISTS(SELECT 1 FROM user_subscriptions WHERE user_id=$1 AND status='active' AND end_time>$2 AND id<>$3 AND upgrade_group<>'')",
    )
    .bind(subscription.user_id)
    .bind(current)
    .bind(subscription.id)
    .fetch_one(&mut **tx)
    .await?;
    if other_active {
        return Ok(None);
    }
    let target = if !subscription.downgrade_group.is_empty() {
        subscription.downgrade_group.as_str()
    } else if current_group == subscription.upgrade_group {
        subscription.prev_user_group.as_str()
    } else {
        ""
    };
    if target.is_empty() || target == current_group {
        return Ok(None);
    }
    sqlx::query("UPDATE users SET \"group\"=$2 WHERE id=$1")
        .bind(subscription.user_id)
        .bind(target)
        .execute(&mut **tx)
        .await?;
    Ok(Some(target.to_owned()))
}

async fn evict_plan(state: &BillingSubscriptionsState, plan_id: i64) {
    let Some(client) = &state.valkey else { return };
    let Ok(mut connection) = client.get_multiplexed_async_connection().await else {
        return;
    };
    let _: Result<(), _> = redis::cmd("DEL")
        .arg(format!("{PLAN_CACHE_PREFIX}{plan_id}"))
        .query_async(&mut connection)
        .await;
    let mut cursor = 0_u64;
    loop {
        let scan: Result<(u64, Vec<String>), _> = redis::cmd("SCAN")
            .arg(cursor)
            .arg("MATCH")
            .arg(format!("{PLAN_INFO_CACHE_PREFIX}*"))
            .arg("COUNT")
            .arg(200)
            .query_async(&mut connection)
            .await;
        let Ok((next, keys)) = scan else { return };
        if !keys.is_empty() {
            let _: Result<(), _> = redis::cmd("DEL")
                .arg(keys)
                .query_async(&mut connection)
                .await;
        }
        cursor = next;
        if cursor == 0 {
            return;
        }
    }
}

/// A failed Valkey eviction never rolls back a committed PostgreSQL change.
/// The user cache is reconstructible from PostgreSQL and its TTL bounds the
/// recovery window, matching the legacy cache-aside contract.
async fn evict_user(state: &BillingSubscriptionsState, user_id: i64) {
    let Some(client) = &state.valkey else { return };
    let Ok(mut connection) = client.get_multiplexed_async_connection().await else {
        return;
    };
    let _: Result<(), _> = redis::cmd("DEL")
        .arg(format!("{USER_CACHE_PREFIX}{user_id}"))
        .query_async(&mut connection)
        .await;
}
fn now() -> i64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map_or(0, |duration| duration.as_secs() as i64)
}

#[cfg(test)]
mod tests {
    use super::{Plan, end_time, next_reset, normalize_preference};
    fn plan() -> Plan {
        Plan {
            id: 1,
            title: "p".into(),
            subtitle: String::new(),
            price_amount: 1.0,
            currency: "USD".into(),
            duration_unit: "day".into(),
            duration_value: 1,
            custom_seconds: 0,
            enabled: true,
            sort_order: 0,
            allow_balance_pay: true,
            allow_wallet_overflow: true,
            stripe_price_id: String::new(),
            creem_product_id: String::new(),
            waffo_pancake_product_id: String::new(),
            max_purchase_per_user: 0,
            total_amount: 1,
            upgrade_group: String::new(),
            downgrade_group: String::new(),
            quota_reset_period: "daily".into(),
            quota_reset_custom_seconds: 0,
            created_at: 0,
            updated_at: 0,
        }
    }
    #[test]
    fn preference_is_idempotently_normalized() {
        assert_eq!(normalize_preference("unexpected"), "quota");
    }
    #[test]
    fn subscription_end_time_uses_plan_duration() {
        assert_eq!(end_time(100, &plan()), Ok(86_500));
    }
    #[test]
    fn reset_never_exceeds_subscription_end() {
        assert_eq!(next_reset(100, 86_499, &plan()), 0);
    }
}
