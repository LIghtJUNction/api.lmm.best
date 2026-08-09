//! Open-source bounty discovery and settlement notifications.
//!
//! The Go service exposes the public bounty list through `TryUserAuth`: an
//! anonymous visitor may browse published/paused projects, while a valid
//! dashboard credential receives the current user's challenge for each
//! project. This slice owns public discovery, authenticated read views, and
//! settlement-notification acknowledgement paths. Mutating escrow, challenge,
//! and MCP operations remain Go-owned until their transaction and provider
//! evidence is migrated.

use axum::{
    Json, Router,
    extract::{Path, Query, State},
    http::{HeaderMap, HeaderValue, StatusCode, header},
    response::{IntoResponse, Response},
    routing::{get, post},
};
use base64::{Engine, engine::general_purpose::URL_SAFE_NO_PAD};
use lmm_contracts::LegacySuccessEnvelope;
use secrecy::SecretString;
use serde::{Deserialize, Serialize};
use serde_json::Value;
use sqlx::{PgPool, Row, postgres::PgRow};
use std::sync::Arc;

use crate::auth::{AuthErrorKind, DashboardAuth};

const MAX_PAGE_SIZE: i64 = 50;
const DEFAULT_PAGE_SIZE: i64 = 20;
const ENABLED_USER_STATUS: i64 = 1;
const ROLE_ADMIN: i64 = 10;
const AUTH_VERSION: &str = "864b7076dbcd0a3c01b5520316720ebf";

/// PostgreSQL and dashboard-auth dependencies for the public bounty slice.
#[derive(Clone)]
pub struct OpenSourceBountyState {
    pg: PgPool,
    auth: Arc<dyn DashboardAuth>,
}

impl OpenSourceBountyState {
    /// Creates the public bounty state from the listener's shared authorities.
    #[must_use]
    pub fn new(pg: PgPool, auth: Arc<dyn DashboardAuth>) -> Self {
        Self { pg, auth }
    }
}

/// Public discovery and authenticated bounty notification routes.
pub fn router(state: OpenSourceBountyState) -> Router {
    Router::new()
        .route("/api/open-source-bounties", get(list_bounties))
        .route(
            "/api/open-source-bounties/projects/{id}",
            get(detail_bounty),
        )
        .route("/api/open-source-bounties/config", get(bounty_config))
        .route("/api/open-source-bounties/mine", get(owned_bounties))
        .route("/api/open-source-bounties/accepted", get(accepted_bounties))
        .route(
            "/api/open-source-bounties/disputes/mine",
            get(owned_disputes),
        )
        .route(
            "/api/open-source-bounties/disputes/admin",
            get(admin_disputes),
        )
        .route(
            "/api/open-source-bounties/notifications",
            get(list_notifications),
        )
        .route(
            "/api/open-source-bounties/notifications/read",
            post(mark_notifications_read),
        )
        .route(
            "/api/open-source-bounties/tips/received",
            get(list_tip_notifications),
        )
        .route(
            "/api/open-source-bounties/tips/received/read",
            post(mark_tip_notifications_read),
        )
        .route(
            "/api/open-source-bounties/tips/{tip_id}/thank",
            post(thank_tip),
        )
        .with_state(state)
}

#[derive(Debug, Deserialize)]
struct ListQuery {
    page: Option<String>,
    page_size: Option<String>,
}

#[derive(Debug, Deserialize)]
struct DisputeListQuery {
    status: Option<String>,
    limit: Option<String>,
}

#[derive(Debug, Deserialize)]
struct NotificationQuery {
    limit: Option<String>,
}

impl NotificationQuery {
    fn normalized_limit(&self) -> i64 {
        self.limit
            .as_deref()
            .and_then(|value| value.parse::<i64>().ok())
            .filter(|limit| (1..=100).contains(limit))
            .unwrap_or(50)
    }
}

impl DisputeListQuery {
    fn normalized(&self) -> Result<(Option<&str>, i64), Box<Response>> {
        let status = self
            .status
            .as_deref()
            .map(str::trim)
            .filter(|value| matches!(*value, "open" | "resolved_paid" | "resolved_denied"));
        if self.status.as_deref().is_some_and(|value| {
            let value = value.trim();
            !value.is_empty() && status.is_none()
        }) {
            return Err(Box::new(business_failure(
                "OPEN_SOURCE_BOUNTY_INVALID_DISPUTE_FILTER",
                "invalid bounty dispute status filter",
            )));
        }
        let limit = self
            .limit
            .as_deref()
            .and_then(|value| value.parse::<i64>().ok())
            .filter(|limit| *limit > 0)
            .unwrap_or(50)
            .min(100);
        Ok((status, limit))
    }
}

impl ListQuery {
    fn normalized(&self) -> (i64, i64) {
        let page = self
            .page
            .as_deref()
            .and_then(|value| value.parse::<i64>().ok())
            .filter(|page| *page >= 1)
            .unwrap_or(1);
        let page_size = self
            .page_size
            .as_deref()
            .and_then(|value| value.parse::<i64>().ok())
            .filter(|value| (1..=MAX_PAGE_SIZE).contains(value))
            .unwrap_or(DEFAULT_PAGE_SIZE);
        (page, page_size)
    }
}

#[derive(Debug, Serialize)]
struct BountyProjectView {
    id: i64,
    owner_user_id: i64,
    repository_url: String,
    title: String,
    description: String,
    rules: String,
    reward_quota: i64,
    net_reward_quota: i64,
    reward_slots: i64,
    escrow_quota: i64,
    platform_fee_rate_bps: i64,
    platform_fee_quota: i64,
    status: String,
    created_at: i64,
    updated_at: i64,
    published_at: i64,
    closed_at: i64,
    owner_username: String,
    active_challenge_count: i64,
    approved_challenge_count: i64,
    owner_rating_average: f64,
    owner_rating_count: i64,
    owner_thank_heart_count: i64,
    #[serde(skip_serializing_if = "Option::is_none")]
    viewer_challenge: Option<BountyChallenge>,
}

#[derive(Debug, Serialize)]
struct BountyChallenge {
    id: i64,
    project_id: i64,
    participant_user_id: i64,
    github_handle: String,
    status: String,
    issue_url: String,
    pull_request_url: String,
    submission_note: String,
    review_note: String,
    reward_quota: i64,
    tip_quota: i64,
    owner_rating_score: i64,
    owner_rating_comment: String,
    owner_rated_at: i64,
    contributor_rating_score: i64,
    contributor_rating_comment: String,
    contributor_rated_at: i64,
    owner_rating_overturned: bool,
    accepted_at: i64,
    submitted_at: i64,
    reviewed_at: i64,
    rejected_at: i64,
    paid_at: i64,
    created_at: i64,
    updated_at: i64,
}

#[derive(Debug, Serialize)]
struct ListPayload {
    items: Vec<BountyProjectView>,
    total: i64,
    page: i64,
    page_size: i64,
}

#[derive(Debug, Serialize)]
struct BountyFeeConfig {
    rate_percent: f64,
    rate_basis_points: i64,
}

#[derive(Debug, Serialize)]
struct BountyProjectDetail {
    project: BountyProjectView,
    challenges: Vec<BountyChallengeView>,
    ledger: Vec<BountyLedger>,
}

#[derive(Debug, Serialize)]
struct BountyChallengeView {
    #[serde(flatten)]
    challenge: BountyChallenge,
    participant_username: String,
    project_title: String,
    repository_url: String,
    owner_username: String,
    participant_rating_average: f64,
    participant_rating_count: i64,
    owner_rating_average: f64,
    owner_rating_count: i64,
    #[serde(skip_serializing_if = "Option::is_none")]
    dispute: Option<BountyDisputeView>,
}

#[derive(Debug, Serialize)]
struct BountyLedger {
    id: i64,
    project_id: i64,
    challenge_id: i64,
    user_id: i64,
    counterparty_user_id: i64,
    kind: String,
    quota: i64,
    note: String,
    recipient_read_at: i64,
    thanked_at: i64,
    created_at: i64,
}

#[derive(Debug, Serialize)]
struct BountyDispute {
    id: i64,
    challenge_id: i64,
    project_id: i64,
    opened_by_user_id: i64,
    against_user_id: i64,
    reason: String,
    statement: String,
    project_title_snapshot: String,
    repository_url_snapshot: String,
    project_rules_snapshot: String,
    project_escrow_quota_snapshot: i64,
    challenge_status_snapshot: String,
    issue_url_snapshot: String,
    pull_request_url_snapshot: String,
    submission_note_snapshot: String,
    review_note_snapshot: String,
    reward_quota_snapshot: i64,
    tip_quota_snapshot: i64,
    owner_rating_score_snapshot: i64,
    owner_rating_comment_snapshot: String,
    contributor_rating_score_snapshot: i64,
    contributor_rating_comment_snapshot: String,
    status: String,
    resolution: String,
    resolved_by_user_id: i64,
    created_at: i64,
    updated_at: i64,
    resolved_at: i64,
}

#[derive(Debug, Serialize)]
struct BountyDisputeView {
    #[serde(flatten)]
    dispute: BountyDispute,
    project_title: String,
    repository_url: String,
    project_rules: String,
    challenge_status: String,
    current_project_escrow_quota: i64,
    issue_url: String,
    pull_request_url: String,
    submission_note: String,
    review_note: String,
    reward_quota: i64,
    tip_quota: i64,
    owner_rating_score: i64,
    owner_rating_comment: String,
    contributor_rating_score: i64,
    contributor_rating_comment: String,
    owner_username: String,
    participant_username: String,
    opened_by_username: String,
    against_username: String,
    live_evidence_changed: bool,
}

#[derive(Debug, Serialize)]
struct BountyNotification {
    id: i64,
    project_id: i64,
    challenge_id: i64,
    sender_user_id: i64,
    sender_username: String,
    kind: String,
    project_title: String,
    quota: i64,
    note: String,
    recipient_read_at: i64,
    thanked_at: i64,
    created_at: i64,
}

#[derive(Debug, Serialize)]
struct BountyTipNotification {
    id: i64,
    project_id: i64,
    challenge_id: i64,
    sender_user_id: i64,
    sender_username: String,
    project_title: String,
    quota: i64,
    note: String,
    recipient_read_at: i64,
    thanked_at: i64,
    created_at: i64,
}

#[derive(Debug, Serialize)]
struct FailureEnvelope {
    success: bool,
    code: &'static str,
    message: &'static str,
}

fn business_failure(code: &'static str, message: &'static str) -> Response {
    Json(FailureEnvelope {
        success: false,
        code,
        message,
    })
    .into_response()
}

fn auth_failure(error: AuthErrorKind) -> Response {
    let (status, code, message) = match error {
        AuthErrorKind::TokenExpired => (
            StatusCode::UNAUTHORIZED,
            "AUTH_TOKEN_EXPIRED",
            "Unauthorized, not logged in and no access token provided",
        ),
        AuthErrorKind::SessionRevoked => (
            StatusCode::UNAUTHORIZED,
            "AUTH_SESSION_REVOKED",
            "Unauthorized, not logged in and no access token provided",
        ),
        AuthErrorKind::UserDisabled => (
            StatusCode::UNAUTHORIZED,
            "AUTH_USER_DISABLED",
            "User has been banned",
        ),
        AuthErrorKind::Internal => (
            StatusCode::INTERNAL_SERVER_ERROR,
            "AUTH_INTERNAL_ERROR",
            "Database error, please contact the administrator",
        ),
        _ => (
            StatusCode::UNAUTHORIZED,
            "AUTH_UNAUTHORIZED",
            "Unauthorized, invalid access token",
        ),
    };
    (
        status,
        Json(FailureEnvelope {
            success: false,
            code,
            message,
        }),
    )
        .into_response()
}

fn internal_failure() -> Response {
    business_failure(
        "OPEN_SOURCE_BOUNTY_INTERNAL_ERROR",
        "open-source bounty operation failed",
    )
}

fn parse_fee_rate_basis_points(raw: &str) -> Option<i64> {
    let value = raw.trim();
    let (whole, fraction) = value.split_once('.').unwrap_or((value, ""));
    if whole.is_empty()
        || !whole.bytes().all(|byte| byte.is_ascii_digit())
        || fraction.len() > 2
        || !fraction.bytes().all(|byte| byte.is_ascii_digit())
    {
        return None;
    }
    if whole == "100" {
        if fraction.bytes().any(|byte| byte != b'0') {
            return None;
        }
    } else if whole.len() > 2 {
        return None;
    }
    let whole = whole.parse::<i64>().ok()?;
    if whole > 100 {
        return None;
    }
    let fraction = match fraction.len() {
        0 => 0,
        1 => fraction.parse::<i64>().ok()? * 10,
        2 => fraction.parse::<i64>().ok()?,
        _ => return None,
    };
    Some(whole * 100 + fraction)
}

fn authorization_token(headers: &HeaderMap) -> Option<String> {
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

/// Mirrors Go's unverified dashboard-JWT classification boundary.  A token
/// that declares the dashboard issuer/audience/use is never allowed to fall
/// through to opaque PAT lookup when its signature or session is invalid.
fn dashboard_token_candidate(raw: &str) -> bool {
    let mut segments = raw.trim().split('.');
    let (Some(header), Some(payload), Some(_signature), None) = (
        segments.next(),
        segments.next(),
        segments.next(),
        segments.next(),
    ) else {
        return false;
    };
    let Ok(header) = URL_SAFE_NO_PAD.decode(header) else {
        return false;
    };
    let Ok(payload) = URL_SAFE_NO_PAD.decode(payload) else {
        return false;
    };
    let Ok(header) = serde_json::from_slice::<Value>(&header) else {
        return false;
    };
    let Ok(payload) = serde_json::from_slice::<Value>(&payload) else {
        return false;
    };
    let audience_matches = payload.get("aud").is_some_and(|audience| match audience {
        Value::String(value) => value == "new-api-dashboard",
        Value::Array(values) => values
            .iter()
            .any(|value| value.as_str() == Some("new-api-dashboard")),
        _ => false,
    });
    let algorithm_registered = header
        .get("alg")
        .and_then(Value::as_str)
        .is_some_and(|algorithm| {
            matches!(
                algorithm,
                "none"
                    | "HS256"
                    | "HS384"
                    | "HS512"
                    | "RS256"
                    | "RS384"
                    | "RS512"
                    | "PS256"
                    | "PS384"
                    | "PS512"
                    | "ES256"
                    | "ES384"
                    | "ES512"
                    | "EdDSA"
            )
        });
    algorithm_registered
        && payload.get("iss").and_then(Value::as_str) == Some("new-api")
        && matches!(
            payload.get("token_use").and_then(Value::as_str),
            Some("access" | "security_proof")
        )
        && audience_matches
}

async fn optional_viewer_id(
    state: &OpenSourceBountyState,
    headers: &HeaderMap,
) -> Result<Option<i64>, Response> {
    let Some(token) = authorization_token(headers) else {
        return Ok(None);
    };

    // Go's TryUserAuth treats an unknown opaque token as anonymous.  Querying
    // the durable PAT index first preserves that distinction while keeping the
    // shared auth service authoritative for valid credentials and disabled
    // users.
    if !dashboard_token_candidate(&token) {
        let pat_owner = sqlx::query_scalar::<_, i64>(
            "SELECT id FROM users WHERE access_token = $1 AND deleted_at IS NULL",
        )
        .bind(&token)
        .fetch_optional(&state.pg)
        .await
        .map_err(|_| internal_failure())?;
        if pat_owner.is_none() {
            return Ok(None);
        }
    }

    let user = state
        .auth
        .self_user_for_optional(SecretString::from(token))
        .await
        .map_err(|error| auth_failure(error.kind))?;
    if user.id <= 0 || user.status != ENABLED_USER_STATUS {
        return Err(auth_failure(AuthErrorKind::Unauthorized));
    }
    Ok(Some(user.id))
}

async fn bounty_config(State(state): State<OpenSourceBountyState>, headers: HeaderMap) -> Response {
    let viewer_id = match required_viewer_id(&state, &headers).await {
        Ok(viewer_id) => viewer_id,
        Err(response) => return response,
    };
    let raw = match sqlx::query_scalar::<_, Option<String>>(
        "SELECT value FROM options WHERE key = 'OpenSourceBountyFeeRate'",
    )
    .fetch_optional(&state.pg)
    .await
    {
        Ok(value) => value.flatten().unwrap_or_default(),
        Err(error) => {
            tracing::error!(error = %error, viewer_id, "failed to load open-source bounty fee configuration");
            return internal_failure();
        }
    };
    let rate_basis_points = parse_fee_rate_basis_points(&raw).unwrap_or(100);
    Json(LegacySuccessEnvelope {
        success: true,
        message: "",
        data: BountyFeeConfig {
            rate_percent: rate_basis_points as f64 / 100.0,
            rate_basis_points,
        },
    })
    .into_response()
}

async fn required_viewer_id(
    state: &OpenSourceBountyState,
    headers: &HeaderMap,
) -> Result<i64, Response> {
    match optional_viewer_id(state, headers).await? {
        Some(viewer_id) => Ok(viewer_id),
        None => Err(auth_failure(AuthErrorKind::Unauthorized)),
    }
}

async fn required_admin_id(
    state: &OpenSourceBountyState,
    headers: &HeaderMap,
) -> Result<i64, Response> {
    let token =
        authorization_token(headers).ok_or_else(|| auth_failure(AuthErrorKind::Unauthorized))?;
    let user = state
        .auth
        .self_user(SecretString::from(token))
        .await
        .map_err(|error| auth_failure(error.kind))?;
    if user.id <= 0 || user.status != ENABLED_USER_STATUS {
        return Err(auth_failure(AuthErrorKind::Unauthorized));
    }
    if user.role < ROLE_ADMIN {
        return Err((
            StatusCode::FORBIDDEN,
            Json(FailureEnvelope {
                success: false,
                code: "AUTH_INSUFFICIENT_PRIVILEGE",
                message: "Unauthorized, insufficient privileges",
            }),
        )
            .into_response());
    }
    Ok(user.id)
}

fn project_select() -> &'static str {
    // Keep casts explicit: Go's integer fields are persisted differently by
    // historical PostgreSQL migrations, while the wire contract is numeric.
    "SELECT p.id::BIGINT AS id, p.owner_user_id::BIGINT AS owner_user_id, p.repository_url, p.title, p.description, p.rules, p.reward_quota::BIGINT AS reward_quota, p.net_reward_quota::BIGINT AS net_reward_quota, p.reward_slots::BIGINT AS reward_slots, p.escrow_quota::BIGINT AS escrow_quota, p.platform_fee_rate_bps::BIGINT AS platform_fee_rate_bps, p.platform_fee_quota::BIGINT AS platform_fee_quota, p.status, p.created_at::BIGINT AS created_at, p.updated_at::BIGINT AS updated_at, p.published_at::BIGINT AS published_at, p.closed_at::BIGINT AS closed_at, u.username AS owner_username, (SELECT COUNT(*)::BIGINT FROM open_source_bounty_challenges c WHERE c.project_id = p.id AND (c.status IN ('accepted','submitted') OR (c.status = 'rejected' AND c.rejected_at > $1 AND NOT EXISTS (SELECT 1 FROM open_source_bounty_disputes resolved_dispute WHERE resolved_dispute.challenge_id = c.id AND resolved_dispute.status IN ('resolved_paid','resolved_denied'))) OR EXISTS (SELECT 1 FROM open_source_bounty_disputes dispute WHERE dispute.challenge_id = c.id AND dispute.status = 'open'))) AS active_challenge_count, (SELECT COUNT(*)::BIGINT FROM open_source_bounty_challenges c WHERE c.project_id = p.id AND c.status = 'approved') AS approved_challenge_count, COALESCE((SELECT AVG(c.contributor_rating_score)::DOUBLE PRECISION FROM open_source_bounty_challenges c JOIN open_source_bounty_projects rated_project ON rated_project.id = c.project_id WHERE rated_project.owner_user_id = p.owner_user_id AND c.contributor_rating_score > 0), 0)::DOUBLE PRECISION AS owner_rating_average, (SELECT COUNT(*)::BIGINT FROM open_source_bounty_challenges c JOIN open_source_bounty_projects rated_project ON rated_project.id = c.project_id WHERE rated_project.owner_user_id = p.owner_user_id AND c.contributor_rating_score > 0) AS owner_rating_count, (SELECT COUNT(*)::BIGINT FROM open_source_bounty_ledgers heart WHERE heart.user_id = p.owner_user_id AND heart.kind = 'tip_transfer' AND heart.thanked_at > 0) AS owner_thank_heart_count FROM open_source_bounty_projects p JOIN users u ON u.id = p.owner_user_id AND u.deleted_at IS NULL"
}

fn project_from_row(row: &PgRow) -> Result<BountyProjectView, sqlx::Error> {
    Ok(BountyProjectView {
        id: row.try_get("id")?,
        owner_user_id: row.try_get("owner_user_id")?,
        repository_url: row.try_get("repository_url")?,
        title: row.try_get("title")?,
        description: row.try_get("description")?,
        rules: row.try_get("rules")?,
        reward_quota: row.try_get("reward_quota")?,
        net_reward_quota: row.try_get("net_reward_quota")?,
        reward_slots: row.try_get("reward_slots")?,
        escrow_quota: row.try_get("escrow_quota")?,
        platform_fee_rate_bps: row.try_get("platform_fee_rate_bps")?,
        platform_fee_quota: row.try_get("platform_fee_quota")?,
        status: row.try_get("status")?,
        created_at: row.try_get("created_at")?,
        updated_at: row.try_get("updated_at")?,
        published_at: row.try_get("published_at")?,
        closed_at: row.try_get("closed_at")?,
        owner_username: row.try_get("owner_username")?,
        active_challenge_count: row.try_get("active_challenge_count")?,
        approved_challenge_count: row.try_get("approved_challenge_count")?,
        owner_rating_average: row.try_get("owner_rating_average")?,
        owner_rating_count: row.try_get("owner_rating_count")?,
        owner_thank_heart_count: row.try_get("owner_thank_heart_count")?,
        viewer_challenge: None,
    })
}

fn challenge_select() -> &'static str {
    "SELECT id::BIGINT AS id, project_id::BIGINT AS project_id, participant_user_id::BIGINT AS participant_user_id, github_handle, status, issue_url, pull_request_url, submission_note, review_note, reward_quota::BIGINT AS reward_quota, tip_quota::BIGINT AS tip_quota, owner_rating_score::BIGINT AS owner_rating_score, owner_rating_comment, owner_rated_at::BIGINT AS owner_rated_at, contributor_rating_score::BIGINT AS contributor_rating_score, contributor_rating_comment, contributor_rated_at::BIGINT AS contributor_rated_at, owner_rating_overturned, accepted_at::BIGINT AS accepted_at, submitted_at::BIGINT AS submitted_at, reviewed_at::BIGINT AS reviewed_at, rejected_at::BIGINT AS rejected_at, paid_at::BIGINT AS paid_at, created_at::BIGINT AS created_at, updated_at::BIGINT AS updated_at FROM open_source_bounty_challenges"
}

fn challenge_from_row(row: &PgRow) -> Result<BountyChallenge, sqlx::Error> {
    Ok(BountyChallenge {
        id: row.try_get("id")?,
        project_id: row.try_get("project_id")?,
        participant_user_id: row.try_get("participant_user_id")?,
        github_handle: row.try_get("github_handle")?,
        status: row.try_get("status")?,
        issue_url: row.try_get("issue_url")?,
        pull_request_url: row.try_get("pull_request_url")?,
        submission_note: row.try_get("submission_note")?,
        review_note: row.try_get("review_note")?,
        reward_quota: row.try_get("reward_quota")?,
        tip_quota: row.try_get("tip_quota")?,
        owner_rating_score: row.try_get("owner_rating_score")?,
        owner_rating_comment: row.try_get("owner_rating_comment")?,
        owner_rated_at: row.try_get("owner_rated_at")?,
        contributor_rating_score: row.try_get("contributor_rating_score")?,
        contributor_rating_comment: row.try_get("contributor_rating_comment")?,
        contributor_rated_at: row.try_get("contributor_rated_at")?,
        owner_rating_overturned: row.try_get("owner_rating_overturned")?,
        accepted_at: row.try_get("accepted_at")?,
        submitted_at: row.try_get("submitted_at")?,
        reviewed_at: row.try_get("reviewed_at")?,
        rejected_at: row.try_get("rejected_at")?,
        paid_at: row.try_get("paid_at")?,
        created_at: row.try_get("created_at")?,
        updated_at: row.try_get("updated_at")?,
    })
}

fn challenge_view_select() -> &'static str {
    "SELECT c.id::BIGINT AS id, c.project_id::BIGINT AS project_id, c.participant_user_id::BIGINT AS participant_user_id, c.github_handle, c.status, c.issue_url, c.pull_request_url, c.submission_note, c.review_note, c.reward_quota::BIGINT AS reward_quota, c.tip_quota::BIGINT AS tip_quota, c.owner_rating_score::BIGINT AS owner_rating_score, c.owner_rating_comment, c.owner_rated_at::BIGINT AS owner_rated_at, c.contributor_rating_score::BIGINT AS contributor_rating_score, c.contributor_rating_comment, c.contributor_rated_at::BIGINT AS contributor_rated_at, c.owner_rating_overturned, c.accepted_at::BIGINT AS accepted_at, c.submitted_at::BIGINT AS submitted_at, c.reviewed_at::BIGINT AS reviewed_at, c.rejected_at::BIGINT AS rejected_at, c.paid_at::BIGINT AS paid_at, c.created_at::BIGINT AS created_at, c.updated_at::BIGINT AS updated_at, participant.username AS participant_username, p.title AS project_title, p.repository_url AS repository_url, owner.username AS owner_username, COALESCE((SELECT AVG(history.owner_rating_score)::DOUBLE PRECISION FROM open_source_bounty_challenges history WHERE history.participant_user_id = c.participant_user_id AND history.owner_rating_score > 0 AND history.owner_rating_overturned = FALSE), 0)::DOUBLE PRECISION AS participant_rating_average, (SELECT COUNT(*)::BIGINT FROM open_source_bounty_challenges history WHERE history.participant_user_id = c.participant_user_id AND history.owner_rating_score > 0 AND history.owner_rating_overturned = FALSE) AS participant_rating_count, COALESCE((SELECT AVG(history.contributor_rating_score)::DOUBLE PRECISION FROM open_source_bounty_challenges history JOIN open_source_bounty_projects history_project ON history_project.id = history.project_id WHERE history_project.owner_user_id = p.owner_user_id AND history.contributor_rating_score > 0), 0)::DOUBLE PRECISION AS owner_rating_average, (SELECT COUNT(*)::BIGINT FROM open_source_bounty_challenges history JOIN open_source_bounty_projects history_project ON history_project.id = history.project_id WHERE history_project.owner_user_id = p.owner_user_id AND history.contributor_rating_score > 0) AS owner_rating_count FROM open_source_bounty_challenges c JOIN users participant ON participant.id = c.participant_user_id JOIN open_source_bounty_projects p ON p.id = c.project_id JOIN users owner ON owner.id = p.owner_user_id"
}

fn challenge_view_from_row(row: &PgRow) -> Result<BountyChallengeView, sqlx::Error> {
    Ok(BountyChallengeView {
        challenge: challenge_from_row(row)?,
        participant_username: row.try_get("participant_username")?,
        project_title: row.try_get("project_title")?,
        repository_url: row.try_get("repository_url")?,
        owner_username: row.try_get("owner_username")?,
        participant_rating_average: row.try_get("participant_rating_average")?,
        participant_rating_count: row.try_get("participant_rating_count")?,
        owner_rating_average: row.try_get("owner_rating_average")?,
        owner_rating_count: row.try_get("owner_rating_count")?,
        dispute: None,
    })
}

fn ledger_from_row(row: &PgRow) -> Result<BountyLedger, sqlx::Error> {
    Ok(BountyLedger {
        id: row.try_get("id")?,
        project_id: row.try_get("project_id")?,
        challenge_id: row.try_get("challenge_id")?,
        user_id: row.try_get("user_id")?,
        counterparty_user_id: row.try_get("counterparty_user_id")?,
        kind: row.try_get("kind")?,
        quota: row.try_get("quota")?,
        note: row.try_get("note")?,
        recipient_read_at: row.try_get("recipient_read_at")?,
        thanked_at: row.try_get("thanked_at")?,
        created_at: row.try_get("created_at")?,
    })
}

fn dispute_view_select() -> &'static str {
    "SELECT d.id::BIGINT AS id, d.challenge_id::BIGINT AS challenge_id, d.project_id::BIGINT AS project_id, d.opened_by_user_id::BIGINT AS opened_by_user_id, d.against_user_id::BIGINT AS against_user_id, d.reason, d.statement, d.project_title_snapshot, d.repository_url_snapshot, d.project_rules_snapshot, d.project_escrow_quota_snapshot::BIGINT AS project_escrow_quota_snapshot, d.challenge_status_snapshot, d.issue_url_snapshot, d.pull_request_url_snapshot, d.submission_note_snapshot, d.review_note_snapshot, d.reward_quota_snapshot::BIGINT AS reward_quota_snapshot, d.tip_quota_snapshot::BIGINT AS tip_quota_snapshot, d.owner_rating_score_snapshot::BIGINT AS owner_rating_score_snapshot, d.owner_rating_comment_snapshot, d.contributor_rating_score_snapshot::BIGINT AS contributor_rating_score_snapshot, d.contributor_rating_comment_snapshot, d.status, d.resolution, d.resolved_by_user_id::BIGINT AS resolved_by_user_id, d.created_at::BIGINT AS created_at, d.updated_at::BIGINT AS updated_at, d.resolved_at::BIGINT AS resolved_at, p.title AS project_title, p.repository_url AS repository_url, p.rules AS project_rules, c.status AS challenge_status, p.escrow_quota::BIGINT AS current_project_escrow_quota, c.issue_url AS issue_url, c.pull_request_url AS pull_request_url, c.submission_note AS submission_note, c.review_note AS review_note, c.reward_quota::BIGINT AS reward_quota, c.tip_quota::BIGINT AS tip_quota, c.owner_rating_score::BIGINT AS owner_rating_score, c.owner_rating_comment AS owner_rating_comment, c.contributor_rating_score::BIGINT AS contributor_rating_score, c.contributor_rating_comment AS contributor_rating_comment, owner.username AS owner_username, participant.username AS participant_username, opener.username AS opened_by_username, against_user.username AS against_username, CASE WHEN p.title <> d.project_title_snapshot OR p.repository_url <> d.repository_url_snapshot OR p.rules <> d.project_rules_snapshot OR c.status <> d.challenge_status_snapshot OR c.issue_url <> d.issue_url_snapshot OR c.pull_request_url <> d.pull_request_url_snapshot OR c.submission_note <> d.submission_note_snapshot OR c.review_note <> d.review_note_snapshot OR c.reward_quota <> d.reward_quota_snapshot OR c.tip_quota <> d.tip_quota_snapshot OR c.owner_rating_score <> d.owner_rating_score_snapshot OR c.owner_rating_comment <> d.owner_rating_comment_snapshot OR c.contributor_rating_score <> d.contributor_rating_score_snapshot OR c.contributor_rating_comment <> d.contributor_rating_comment_snapshot THEN TRUE ELSE FALSE END AS live_evidence_changed FROM open_source_bounty_disputes d JOIN open_source_bounty_challenges c ON c.id = d.challenge_id JOIN open_source_bounty_projects p ON p.id = d.project_id JOIN users owner ON owner.id = p.owner_user_id JOIN users participant ON participant.id = c.participant_user_id JOIN users opener ON opener.id = d.opened_by_user_id JOIN users against_user ON against_user.id = d.against_user_id"
}

fn dispute_view_from_row(row: &PgRow) -> Result<BountyDisputeView, sqlx::Error> {
    Ok(BountyDisputeView {
        dispute: BountyDispute {
            id: row.try_get("id")?,
            challenge_id: row.try_get("challenge_id")?,
            project_id: row.try_get("project_id")?,
            opened_by_user_id: row.try_get("opened_by_user_id")?,
            against_user_id: row.try_get("against_user_id")?,
            reason: row.try_get("reason")?,
            statement: row.try_get("statement")?,
            project_title_snapshot: row.try_get("project_title_snapshot")?,
            repository_url_snapshot: row.try_get("repository_url_snapshot")?,
            project_rules_snapshot: row.try_get("project_rules_snapshot")?,
            project_escrow_quota_snapshot: row.try_get("project_escrow_quota_snapshot")?,
            challenge_status_snapshot: row.try_get("challenge_status_snapshot")?,
            issue_url_snapshot: row.try_get("issue_url_snapshot")?,
            pull_request_url_snapshot: row.try_get("pull_request_url_snapshot")?,
            submission_note_snapshot: row.try_get("submission_note_snapshot")?,
            review_note_snapshot: row.try_get("review_note_snapshot")?,
            reward_quota_snapshot: row.try_get("reward_quota_snapshot")?,
            tip_quota_snapshot: row.try_get("tip_quota_snapshot")?,
            owner_rating_score_snapshot: row.try_get("owner_rating_score_snapshot")?,
            owner_rating_comment_snapshot: row.try_get("owner_rating_comment_snapshot")?,
            contributor_rating_score_snapshot: row.try_get("contributor_rating_score_snapshot")?,
            contributor_rating_comment_snapshot: row
                .try_get("contributor_rating_comment_snapshot")?,
            status: row.try_get("status")?,
            resolution: row.try_get("resolution")?,
            resolved_by_user_id: row.try_get("resolved_by_user_id")?,
            created_at: row.try_get("created_at")?,
            updated_at: row.try_get("updated_at")?,
            resolved_at: row.try_get("resolved_at")?,
        },
        project_title: row.try_get("project_title")?,
        repository_url: row.try_get("repository_url")?,
        project_rules: row.try_get("project_rules")?,
        challenge_status: row.try_get("challenge_status")?,
        current_project_escrow_quota: row.try_get("current_project_escrow_quota")?,
        issue_url: row.try_get("issue_url")?,
        pull_request_url: row.try_get("pull_request_url")?,
        submission_note: row.try_get("submission_note")?,
        review_note: row.try_get("review_note")?,
        reward_quota: row.try_get("reward_quota")?,
        tip_quota: row.try_get("tip_quota")?,
        owner_rating_score: row.try_get("owner_rating_score")?,
        owner_rating_comment: row.try_get("owner_rating_comment")?,
        contributor_rating_score: row.try_get("contributor_rating_score")?,
        contributor_rating_comment: row.try_get("contributor_rating_comment")?,
        owner_username: row.try_get("owner_username")?,
        participant_username: row.try_get("participant_username")?,
        opened_by_username: row.try_get("opened_by_username")?,
        against_username: row.try_get("against_username")?,
        live_evidence_changed: row.try_get("live_evidence_changed")?,
    })
}

fn challenge_priority(status: &str) -> i64 {
    match status {
        "approved" => 4,
        "accepted" | "submitted" => 3,
        "rejected" => 2,
        "withdrawn" | "cancelled" => 1,
        _ => 0,
    }
}

async fn attach_viewer_challenges(
    state: &OpenSourceBountyState,
    views: &mut [BountyProjectView],
    viewer_id: Option<i64>,
) -> Result<(), sqlx::Error> {
    let Some(viewer_id) = viewer_id else {
        return Ok(());
    };
    if views.is_empty() {
        return Ok(());
    }
    let project_ids = views.iter().map(|view| view.id).collect::<Vec<_>>();
    let query = format!(
        "{} WHERE participant_user_id = $1 AND project_id = ANY($2)",
        challenge_select()
    );
    let rows = sqlx::query(&query)
        .bind(viewer_id)
        .bind(&project_ids)
        .fetch_all(&state.pg)
        .await?;
    let mut selected = std::collections::HashMap::<i64, BountyChallenge>::new();
    for row in rows {
        let challenge = challenge_from_row(&row)?;
        let replace = selected.get(&challenge.project_id).is_none_or(|current| {
            challenge_priority(&challenge.status) > challenge_priority(&current.status)
                || (challenge_priority(&challenge.status) == challenge_priority(&current.status)
                    && challenge.id > current.id)
        });
        if replace {
            selected.insert(challenge.project_id, challenge);
        }
    }
    for view in views {
        view.viewer_challenge = selected.remove(&view.id);
    }
    Ok(())
}

async fn attach_disputes(
    state: &OpenSourceBountyState,
    views: &mut [BountyChallengeView],
) -> Result<(), sqlx::Error> {
    if views.is_empty() {
        return Ok(());
    }
    let challenge_ids = views
        .iter()
        .map(|view| view.challenge.id)
        .collect::<Vec<_>>();
    let query = format!(
        "{} WHERE d.challenge_id = ANY($1) ORDER BY d.created_at DESC, d.id DESC",
        dispute_view_select()
    );
    let rows = sqlx::query(&query)
        .bind(&challenge_ids)
        .fetch_all(&state.pg)
        .await?;
    let mut selected = std::collections::HashMap::<i64, BountyDisputeView>::new();
    for row in rows {
        let dispute = dispute_view_from_row(&row)?;
        selected
            .entry(dispute.dispute.challenge_id)
            .or_insert(dispute);
    }
    for view in views {
        view.dispute = selected.remove(&view.challenge.id);
    }
    Ok(())
}

async fn detail_bounty(
    State(state): State<OpenSourceBountyState>,
    Path(project_id): Path<String>,
    headers: HeaderMap,
) -> Response {
    let project_id = match project_id.parse::<i64>() {
        Ok(project_id) if project_id > 0 => project_id,
        _ => {
            return business_failure(
                "OPEN_SOURCE_BOUNTY_INVALID_ID",
                "invalid open-source bounty identifier",
            );
        }
    };
    let viewer_id = match optional_viewer_id(&state, &headers).await {
        Ok(viewer_id) => viewer_id,
        Err(response) => return response,
    };
    let now = chrono::Utc::now().timestamp();
    let query = format!("{} WHERE p.id = $2", project_select());
    let row = match sqlx::query(&query)
        .bind(now - 7 * 24 * 60 * 60)
        .bind(project_id)
        .fetch_optional(&state.pg)
        .await
    {
        Ok(row) => row,
        Err(error) => {
            tracing::error!(error = %error, project_id, "failed to load public open-source bounty detail");
            return internal_failure();
        }
    };
    let Some(row) = row else {
        return business_failure(
            "OPEN_SOURCE_BOUNTY_NOT_FOUND",
            "bounty project was not found",
        );
    };
    let mut project = match project_from_row(&row) {
        Ok(project) => project,
        Err(error) => {
            tracing::error!(error = %error, project_id, "failed to decode open-source bounty detail");
            return internal_failure();
        }
    };
    if matches!(project.status.as_str(), "draft" | "closed")
        && viewer_id != Some(project.owner_user_id)
    {
        return business_failure(
            "OPEN_SOURCE_BOUNTY_NOT_FOUND",
            "bounty project was not found",
        );
    }
    if let Err(error) =
        attach_viewer_challenges(&state, std::slice::from_mut(&mut project), viewer_id).await
    {
        tracing::error!(error = %error, project_id, "failed to attach bounty viewer challenge");
        return internal_failure();
    }
    let mut challenges = Vec::new();
    let mut ledger = Vec::new();
    if viewer_id == Some(project.owner_user_id) {
        let challenge_query = format!(
            "{} WHERE c.project_id = $1 ORDER BY c.created_at DESC, c.id DESC",
            challenge_view_select()
        );
        let rows = match sqlx::query(&challenge_query)
            .bind(project_id)
            .fetch_all(&state.pg)
            .await
        {
            Ok(rows) => rows,
            Err(error) => {
                tracing::error!(error = %error, project_id, "failed to load bounty challenges");
                return internal_failure();
            }
        };
        for row in rows {
            match challenge_view_from_row(&row) {
                Ok(challenge) => challenges.push(challenge),
                Err(error) => {
                    tracing::error!(error = %error, project_id, "failed to decode bounty challenge");
                    return internal_failure();
                }
            }
        }
        if let Err(error) = attach_disputes(&state, &mut challenges).await {
            tracing::error!(error = %error, project_id, "failed to attach bounty disputes");
            return internal_failure();
        }
        let ledger_query = "SELECT id::BIGINT AS id, project_id::BIGINT AS project_id, challenge_id::BIGINT AS challenge_id, user_id::BIGINT AS user_id, counterparty_user_id::BIGINT AS counterparty_user_id, kind, quota::BIGINT AS quota, note, recipient_read_at::BIGINT AS recipient_read_at, thanked_at::BIGINT AS thanked_at, created_at::BIGINT AS created_at FROM open_source_bounty_ledgers WHERE project_id = $1 ORDER BY created_at DESC, id DESC";
        let rows = match sqlx::query(ledger_query)
            .bind(project_id)
            .fetch_all(&state.pg)
            .await
        {
            Ok(rows) => rows,
            Err(error) => {
                tracing::error!(error = %error, project_id, "failed to load bounty ledger");
                return internal_failure();
            }
        };
        for row in rows {
            match ledger_from_row(&row) {
                Ok(entry) => ledger.push(entry),
                Err(error) => {
                    tracing::error!(error = %error, project_id, "failed to decode bounty ledger");
                    return internal_failure();
                }
            }
        }
    }
    let mut response = Json(LegacySuccessEnvelope {
        success: true,
        message: "",
        data: BountyProjectDetail {
            project,
            challenges,
            ledger,
        },
    })
    .into_response();
    if viewer_id.is_some() {
        response
            .headers_mut()
            .insert("auth-version", HeaderValue::from_static(AUTH_VERSION));
    }
    response
}

async fn list_bounties(
    State(state): State<OpenSourceBountyState>,
    Query(query): Query<ListQuery>,
    headers: HeaderMap,
) -> Response {
    let (page, page_size) = query.normalized();
    let viewer_id = match optional_viewer_id(&state, &headers).await {
        Ok(viewer_id) => viewer_id,
        Err(response) => return response,
    };
    let total = match sqlx::query_scalar::<_, i64>(
        "SELECT COUNT(*)::BIGINT FROM open_source_bounty_projects WHERE status IN ('published', 'paused')",
    )
    .fetch_one(&state.pg)
    .await
    {
        Ok(total) => total,
        Err(error) => {
            tracing::error!(error = %error, "failed to count public open-source bounties");
            return internal_failure();
        }
    };
    let now = chrono::Utc::now().timestamp();
    let query_sql = format!(
        "{} WHERE p.status IN ('published', 'paused') ORDER BY p.reward_quota DESC, CASE WHEN p.status = 'published' THEN 0 ELSE 1 END ASC, p.published_at ASC, p.id ASC OFFSET $2 LIMIT $3",
        project_select()
    );
    let rows = match sqlx::query(&query_sql)
        .bind(now - 7 * 24 * 60 * 60)
        .bind((page - 1).saturating_mul(page_size))
        .bind(page_size)
        .fetch_all(&state.pg)
        .await
    {
        Ok(rows) => rows,
        Err(error) => {
            tracing::error!(error = %error, "failed to list public open-source bounties");
            return internal_failure();
        }
    };
    let mut items = Vec::with_capacity(rows.len());
    for row in rows {
        match project_from_row(&row) {
            Ok(item) => items.push(item),
            Err(error) => {
                tracing::error!(error = %error, "failed to decode public open-source bounty");
                return internal_failure();
            }
        }
    }
    if let Err(error) = attach_viewer_challenges(&state, &mut items, viewer_id).await {
        tracing::error!(error = %error, "failed to attach public bounty viewer challenge");
        return internal_failure();
    }
    let mut response = Json(LegacySuccessEnvelope {
        success: true,
        message: "",
        data: ListPayload {
            items,
            total,
            page,
            page_size,
        },
    })
    .into_response();
    if viewer_id.is_some() {
        response
            .headers_mut()
            .insert("auth-version", HeaderValue::from_static(AUTH_VERSION));
    }
    response
}

async fn owned_bounties(
    State(state): State<OpenSourceBountyState>,
    headers: HeaderMap,
) -> Response {
    let viewer_id = match required_viewer_id(&state, &headers).await {
        Ok(viewer_id) => viewer_id,
        Err(response) => return response,
    };
    let now = chrono::Utc::now().timestamp();
    let query = format!(
        "{} WHERE p.owner_user_id = $2 ORDER BY p.created_at DESC, p.id DESC",
        project_select()
    );
    let rows = match sqlx::query(&query)
        .bind(now - 7 * 24 * 60 * 60)
        .bind(viewer_id)
        .fetch_all(&state.pg)
        .await
    {
        Ok(rows) => rows,
        Err(error) => {
            tracing::error!(error = %error, viewer_id, "failed to list owned open-source bounties");
            return internal_failure();
        }
    };
    let mut items = Vec::with_capacity(rows.len());
    for row in rows {
        match project_from_row(&row) {
            Ok(item) => items.push(item),
            Err(error) => {
                tracing::error!(error = %error, viewer_id, "failed to decode owned open-source bounty");
                return internal_failure();
            }
        }
    }
    let mut response = Json(LegacySuccessEnvelope {
        success: true,
        message: "",
        data: items,
    })
    .into_response();
    response
        .headers_mut()
        .insert("auth-version", HeaderValue::from_static(AUTH_VERSION));
    response
}

async fn accepted_bounties(
    State(state): State<OpenSourceBountyState>,
    headers: HeaderMap,
) -> Response {
    let viewer_id = match required_viewer_id(&state, &headers).await {
        Ok(viewer_id) => viewer_id,
        Err(response) => return response,
    };
    let query = format!(
        "{} WHERE c.participant_user_id = $1 ORDER BY c.updated_at DESC, c.id DESC",
        challenge_view_select()
    );
    let rows = match sqlx::query(&query)
        .bind(viewer_id)
        .fetch_all(&state.pg)
        .await
    {
        Ok(rows) => rows,
        Err(error) => {
            tracing::error!(error = %error, viewer_id, "failed to list accepted open-source bounty challenges");
            return internal_failure();
        }
    };
    let mut items = Vec::with_capacity(rows.len());
    for row in rows {
        match challenge_view_from_row(&row) {
            Ok(item) => items.push(item),
            Err(error) => {
                tracing::error!(error = %error, viewer_id, "failed to decode accepted open-source bounty challenge");
                return internal_failure();
            }
        }
    }
    if let Err(error) = attach_disputes(&state, &mut items).await {
        tracing::error!(error = %error, viewer_id, "failed to attach accepted bounty disputes");
        return internal_failure();
    }
    let mut response = Json(LegacySuccessEnvelope {
        success: true,
        message: "",
        data: items,
    })
    .into_response();
    response
        .headers_mut()
        .insert("auth-version", HeaderValue::from_static(AUTH_VERSION));
    response
}

async fn owned_disputes(
    State(state): State<OpenSourceBountyState>,
    Query(query): Query<DisputeListQuery>,
    headers: HeaderMap,
) -> Response {
    let viewer_id = match required_viewer_id(&state, &headers).await {
        Ok(viewer_id) => viewer_id,
        Err(response) => return response,
    };
    let (status, limit) = match query.normalized() {
        Ok(values) => values,
        Err(response) => return *response,
    };
    let mut sql = format!(
        "{} WHERE (d.opened_by_user_id = $1 OR d.against_user_id = $1)",
        dispute_view_select()
    );
    if status.is_some() {
        sql.push_str(" AND d.status = $2");
    }
    sql.push_str(" ORDER BY CASE WHEN d.status = 'open' THEN 0 ELSE 1 END, d.updated_at DESC, d.id DESC LIMIT $");
    sql.push_str(if status.is_some() { "3" } else { "2" });
    let mut request = sqlx::query(&sql).bind(viewer_id);
    if let Some(status) = status {
        request = request.bind(status);
    }
    let rows = match request.bind(limit).fetch_all(&state.pg).await {
        Ok(rows) => rows,
        Err(error) => {
            tracing::error!(error = %error, viewer_id, "failed to list owned open-source bounty disputes");
            return internal_failure();
        }
    };
    let mut items = Vec::with_capacity(rows.len());
    for row in rows {
        match dispute_view_from_row(&row) {
            Ok(item) => items.push(item),
            Err(error) => {
                tracing::error!(error = %error, viewer_id, "failed to decode owned open-source bounty dispute");
                return internal_failure();
            }
        }
    }
    let mut response = Json(LegacySuccessEnvelope {
        success: true,
        message: "",
        data: items,
    })
    .into_response();
    response
        .headers_mut()
        .insert("auth-version", HeaderValue::from_static(AUTH_VERSION));
    response
}

async fn admin_disputes(
    State(state): State<OpenSourceBountyState>,
    Query(query): Query<DisputeListQuery>,
    headers: HeaderMap,
) -> Response {
    let admin_id = match required_admin_id(&state, &headers).await {
        Ok(admin_id) => admin_id,
        Err(response) => return response,
    };
    let (status, limit) = match query.normalized() {
        Ok(values) => values,
        Err(response) => return *response,
    };
    let mut sql = dispute_view_select().to_owned();
    if status.is_some() {
        sql.push_str(" WHERE d.status = $1");
    }
    sql.push_str(" ORDER BY CASE WHEN d.status = 'open' THEN 0 ELSE 1 END, d.updated_at DESC, d.id DESC LIMIT $");
    sql.push_str(if status.is_some() { "2" } else { "1" });
    let mut request = sqlx::query(&sql);
    if let Some(status) = status {
        request = request.bind(status);
    }
    let rows = match request.bind(limit).fetch_all(&state.pg).await {
        Ok(rows) => rows,
        Err(error) => {
            tracing::error!(error = %error, admin_id, "failed to list administrator open-source bounty disputes");
            return internal_failure();
        }
    };
    let mut items = Vec::with_capacity(rows.len());
    for row in rows {
        match dispute_view_from_row(&row) {
            Ok(item) => items.push(item),
            Err(error) => {
                tracing::error!(error = %error, admin_id, "failed to decode administrator open-source bounty dispute");
                return internal_failure();
            }
        }
    }
    let mut response = Json(LegacySuccessEnvelope {
        success: true,
        message: "",
        data: items,
    })
    .into_response();
    response
        .headers_mut()
        .insert("auth-version", HeaderValue::from_static(AUTH_VERSION));
    response
}

fn notification_from_row(row: &PgRow) -> Result<BountyNotification, sqlx::Error> {
    Ok(BountyNotification {
        id: row.try_get("id")?,
        project_id: row.try_get("project_id")?,
        challenge_id: row.try_get("challenge_id")?,
        sender_user_id: row.try_get("sender_user_id")?,
        sender_username: row.try_get("sender_username")?,
        kind: row.try_get("kind")?,
        project_title: row.try_get("project_title")?,
        quota: row.try_get("quota")?,
        note: row.try_get("note")?,
        recipient_read_at: row.try_get("recipient_read_at")?,
        thanked_at: row.try_get("thanked_at")?,
        created_at: row.try_get("created_at")?,
    })
}

fn tip_notification_from_row(row: &PgRow) -> Result<BountyTipNotification, sqlx::Error> {
    Ok(BountyTipNotification {
        id: row.try_get("id")?,
        project_id: row.try_get("project_id")?,
        challenge_id: row.try_get("challenge_id")?,
        sender_user_id: row.try_get("sender_user_id")?,
        sender_username: row.try_get("sender_username")?,
        project_title: row.try_get("project_title")?,
        quota: row.try_get("quota")?,
        note: row.try_get("note")?,
        recipient_read_at: row.try_get("recipient_read_at")?,
        thanked_at: row.try_get("thanked_at")?,
        created_at: row.try_get("created_at")?,
    })
}

fn add_auth_version(response: &mut Response) {
    response
        .headers_mut()
        .insert("auth-version", HeaderValue::from_static(AUTH_VERSION));
}

async fn list_notifications(
    State(state): State<OpenSourceBountyState>,
    Query(query): Query<NotificationQuery>,
    headers: HeaderMap,
) -> Response {
    let viewer_id = match required_viewer_id(&state, &headers).await {
        Ok(viewer_id) => viewer_id,
        Err(response) => return response,
    };
    let limit = query.normalized_limit();
    let rows = match sqlx::query(
        "SELECT notification.id::BIGINT AS id, notification.project_id::BIGINT AS project_id, \
                notification.challenge_id::BIGINT AS challenge_id, notification.user_id::BIGINT AS sender_user_id, \
                sender.username AS sender_username, notification.kind, project.title AS project_title, \
                notification.quota::BIGINT AS quota, notification.note, notification.recipient_read_at::BIGINT AS recipient_read_at, \
                notification.thanked_at::BIGINT AS thanked_at, notification.created_at::BIGINT AS created_at \
         FROM open_source_bounty_ledgers notification \
         JOIN users sender ON sender.id = notification.user_id AND sender.deleted_at IS NULL \
         JOIN open_source_bounty_projects project ON project.id = notification.project_id \
         WHERE notification.kind IN ('tip_transfer', 'reward_transfer', 'dispute_reward_transfer') \
           AND notification.counterparty_user_id = $1 \
         ORDER BY notification.created_at DESC, notification.id DESC LIMIT $2",
    )
    .bind(viewer_id)
    .bind(limit)
    .fetch_all(&state.pg)
    .await
    {
        Ok(rows) => rows,
        Err(error) => {
            tracing::error!(error = %error, viewer_id, "failed to list open-source bounty notifications");
            return internal_failure();
        }
    };
    let mut items = Vec::with_capacity(rows.len());
    for row in rows {
        match notification_from_row(&row) {
            Ok(item) => items.push(item),
            Err(error) => {
                tracing::error!(error = %error, viewer_id, "failed to decode open-source bounty notification");
                return internal_failure();
            }
        }
    }
    let mut response = Json(LegacySuccessEnvelope {
        success: true,
        message: "",
        data: items,
    })
    .into_response();
    add_auth_version(&mut response);
    response
}

async fn mark_notifications_read(
    State(state): State<OpenSourceBountyState>,
    headers: HeaderMap,
) -> Response {
    let viewer_id = match required_viewer_id(&state, &headers).await {
        Ok(viewer_id) => viewer_id,
        Err(response) => return response,
    };
    let now = chrono::Utc::now().timestamp();
    if let Err(error) = sqlx::query(
        "UPDATE open_source_bounty_ledgers \
         SET recipient_read_at = $1 \
         WHERE kind IN ('tip_transfer', 'reward_transfer', 'dispute_reward_transfer') \
           AND counterparty_user_id = $2 AND recipient_read_at = 0",
    )
    .bind(now)
    .bind(viewer_id)
    .execute(&state.pg)
    .await
    {
        tracing::error!(error = %error, viewer_id, "failed to mark open-source bounty notifications read");
        return internal_failure();
    }
    let mut response = Json(LegacySuccessEnvelope {
        success: true,
        message: "",
        data: Value::Null,
    })
    .into_response();
    add_auth_version(&mut response);
    response
}

async fn list_tip_notifications(
    State(state): State<OpenSourceBountyState>,
    Query(query): Query<NotificationQuery>,
    headers: HeaderMap,
) -> Response {
    let viewer_id = match required_viewer_id(&state, &headers).await {
        Ok(viewer_id) => viewer_id,
        Err(response) => return response,
    };
    let limit = query.normalized_limit();
    let rows = match sqlx::query(
        "SELECT tip.id::BIGINT AS id, tip.project_id::BIGINT AS project_id, tip.challenge_id::BIGINT AS challenge_id, \
                tip.user_id::BIGINT AS sender_user_id, sender.username AS sender_username, project.title AS project_title, \
                tip.quota::BIGINT AS quota, tip.note, tip.recipient_read_at::BIGINT AS recipient_read_at, \
                tip.thanked_at::BIGINT AS thanked_at, tip.created_at::BIGINT AS created_at \
         FROM open_source_bounty_ledgers tip \
         JOIN users sender ON sender.id = tip.user_id AND sender.deleted_at IS NULL \
         JOIN open_source_bounty_projects project ON project.id = tip.project_id \
         WHERE tip.kind = 'tip_transfer' AND tip.counterparty_user_id = $1 \
         ORDER BY tip.created_at DESC, tip.id DESC LIMIT $2",
    )
    .bind(viewer_id)
    .bind(limit)
    .fetch_all(&state.pg)
    .await
    {
        Ok(rows) => rows,
        Err(error) => {
            tracing::error!(error = %error, viewer_id, "failed to list open-source bounty tip notifications");
            return internal_failure();
        }
    };
    let mut items = Vec::with_capacity(rows.len());
    for row in rows {
        match tip_notification_from_row(&row) {
            Ok(item) => items.push(item),
            Err(error) => {
                tracing::error!(error = %error, viewer_id, "failed to decode open-source bounty tip notification");
                return internal_failure();
            }
        }
    }
    let mut response = Json(LegacySuccessEnvelope {
        success: true,
        message: "",
        data: items,
    })
    .into_response();
    add_auth_version(&mut response);
    response
}

async fn mark_tip_notifications_read(
    State(state): State<OpenSourceBountyState>,
    headers: HeaderMap,
) -> Response {
    let viewer_id = match required_viewer_id(&state, &headers).await {
        Ok(viewer_id) => viewer_id,
        Err(response) => return response,
    };
    let now = chrono::Utc::now().timestamp();
    if let Err(error) = sqlx::query(
        "UPDATE open_source_bounty_ledgers \
         SET recipient_read_at = $1 \
         WHERE kind = 'tip_transfer' AND counterparty_user_id = $2 AND recipient_read_at = 0",
    )
    .bind(now)
    .bind(viewer_id)
    .execute(&state.pg)
    .await
    {
        tracing::error!(error = %error, viewer_id, "failed to mark open-source bounty tip notifications read");
        return internal_failure();
    }
    let mut response = Json(LegacySuccessEnvelope {
        success: true,
        message: "",
        data: Value::Null,
    })
    .into_response();
    add_auth_version(&mut response);
    response
}

async fn thank_tip(
    State(state): State<OpenSourceBountyState>,
    Path(tip_id): Path<i64>,
    headers: HeaderMap,
) -> Response {
    let viewer_id = match required_viewer_id(&state, &headers).await {
        Ok(viewer_id) => viewer_id,
        Err(response) => return response,
    };
    if tip_id <= 0 {
        return business_failure(
            "OPEN_SOURCE_BOUNTY_INVALID_ID",
            "invalid open-source bounty tip identifier",
        );
    }
    let now = chrono::Utc::now().timestamp();
    let mut transaction = match state.pg.begin().await {
        Ok(transaction) => transaction,
        Err(error) => {
            tracing::error!(error = %error, viewer_id, tip_id, "failed to begin bounty tip acknowledgement");
            return internal_failure();
        }
    };
    if let Err(error) = sqlx::query(
        "UPDATE open_source_bounty_ledgers SET thanked_at = $1, recipient_read_at = $1 \
         WHERE id = $2 AND kind = 'tip_transfer' AND counterparty_user_id = $3 AND thanked_at = 0",
    )
    .bind(now)
    .bind(tip_id)
    .bind(viewer_id)
    .execute(&mut *transaction)
    .await
    {
        tracing::error!(error = %error, viewer_id, tip_id, "failed to acknowledge bounty tip");
        return internal_failure();
    }
    let row = match sqlx::query(
        "SELECT tip.id::BIGINT AS id, tip.project_id::BIGINT AS project_id, tip.challenge_id::BIGINT AS challenge_id, \
                tip.user_id::BIGINT AS sender_user_id, sender.username AS sender_username, project.title AS project_title, \
                tip.quota::BIGINT AS quota, tip.note, tip.recipient_read_at::BIGINT AS recipient_read_at, \
                tip.thanked_at::BIGINT AS thanked_at, tip.created_at::BIGINT AS created_at \
         FROM open_source_bounty_ledgers tip \
         JOIN users sender ON sender.id = tip.user_id AND sender.deleted_at IS NULL \
         JOIN open_source_bounty_projects project ON project.id = tip.project_id \
         WHERE tip.id = $1 AND tip.kind = 'tip_transfer' AND tip.counterparty_user_id = $2",
    )
    .bind(tip_id)
    .bind(viewer_id)
    .fetch_optional(&mut *transaction)
    .await
    {
        Ok(row) => row,
        Err(error) => {
            tracing::error!(error = %error, viewer_id, tip_id, "failed to load acknowledged bounty tip");
            return internal_failure();
        }
    };
    let Some(row) = row else {
        return business_failure(
            "OPEN_SOURCE_BOUNTY_TIP_NOT_FOUND",
            "tip notification was not found",
        );
    };
    let notification = match tip_notification_from_row(&row) {
        Ok(notification) => notification,
        Err(error) => {
            tracing::error!(error = %error, viewer_id, tip_id, "failed to decode acknowledged bounty tip");
            return internal_failure();
        }
    };
    if let Err(error) = transaction.commit().await {
        tracing::error!(error = %error, viewer_id, tip_id, "failed to commit bounty tip acknowledgement");
        return internal_failure();
    }
    let mut response = Json(LegacySuccessEnvelope {
        success: true,
        message: "",
        data: notification,
    })
    .into_response();
    add_auth_version(&mut response);
    response
}

#[cfg(test)]
mod tests {
    use base64::Engine;

    use super::{
        DEFAULT_PAGE_SIZE, DisputeListQuery, ListQuery, MAX_PAGE_SIZE, NotificationQuery,
        challenge_priority, dashboard_token_candidate, parse_fee_rate_basis_points,
    };

    #[test]
    fn list_query_matches_go_defaults_and_bounds() {
        assert_eq!(
            ListQuery {
                page: None,
                page_size: None
            }
            .normalized(),
            (1, DEFAULT_PAGE_SIZE)
        );
        assert_eq!(
            ListQuery {
                page: Some("0".to_owned()),
                page_size: Some("0".to_owned())
            }
            .normalized(),
            (1, DEFAULT_PAGE_SIZE)
        );
        assert_eq!(
            ListQuery {
                page: Some("3".to_owned()),
                page_size: Some(MAX_PAGE_SIZE.to_string())
            }
            .normalized(),
            (3, MAX_PAGE_SIZE)
        );
        assert_eq!(
            ListQuery {
                page: Some("-4".to_owned()),
                page_size: Some((MAX_PAGE_SIZE + 1).to_string())
            }
            .normalized(),
            (1, DEFAULT_PAGE_SIZE)
        );
    }

    #[test]
    fn only_dashboard_access_tokens_are_classified_as_internal() {
        let encode = |value: &str| base64::engine::general_purpose::URL_SAFE_NO_PAD.encode(value);
        let header = encode(r#"{"alg":"HS256"}"#);
        let dashboard =
            encode(r#"{"iss":"new-api","aud":["new-api-dashboard"],"token_use":"access"}"#);
        let proof =
            encode(r#"{"iss":"new-api","aud":["new-api-dashboard"],"token_use":"security_proof"}"#);
        let external = encode(r#"{"iss":"external","aud":["other"],"token_use":"access"}"#);
        assert!(dashboard_token_candidate(&format!(
            "{header}.{dashboard}.sig"
        )));
        assert!(dashboard_token_candidate(&format!("{header}.{proof}.sig")));
        assert!(!dashboard_token_candidate(&format!(
            "{header}.{external}.sig"
        )));
    }

    #[test]
    fn viewer_challenge_priority_matches_go() {
        assert_eq!(challenge_priority("approved"), 4);
        assert_eq!(challenge_priority("accepted"), 3);
        assert_eq!(challenge_priority("submitted"), 3);
        assert_eq!(challenge_priority("rejected"), 2);
        assert_eq!(challenge_priority("withdrawn"), 1);
        assert_eq!(challenge_priority("cancelled"), 1);
        assert_eq!(challenge_priority("draft"), 0);
    }

    #[test]
    fn fee_rate_parser_matches_go_basis_points_contract() {
        assert_eq!(parse_fee_rate_basis_points("0"), Some(0));
        assert_eq!(parse_fee_rate_basis_points("1"), Some(100));
        assert_eq!(parse_fee_rate_basis_points("2.5"), Some(250));
        assert_eq!(parse_fee_rate_basis_points("100.00"), Some(10_000));
        for value in ["", "001", "100.01", "101", "1.234", "-1"] {
            assert_eq!(parse_fee_rate_basis_points(value), None, "value={value}");
        }
    }

    #[test]
    fn dispute_list_query_matches_go_filter_and_limit_bounds() {
        let query = DisputeListQuery {
            status: Some(" resolved_paid ".to_owned()),
            limit: Some("101".to_owned()),
        };
        assert_eq!(query.normalized().unwrap(), (Some("resolved_paid"), 100));
        let default = DisputeListQuery {
            status: Some(" ".to_owned()),
            limit: Some("not-a-number".to_owned()),
        };
        assert_eq!(default.normalized().unwrap(), (None, 50));
        let invalid = DisputeListQuery {
            status: Some("pending".to_owned()),
            limit: None,
        };
        assert!(invalid.normalized().is_err());
    }

    #[test]
    fn notification_limit_matches_go_default_and_bounds() {
        assert_eq!(NotificationQuery { limit: None }.normalized_limit(), 50);
        assert_eq!(
            NotificationQuery {
                limit: Some("100".to_owned())
            }
            .normalized_limit(),
            100
        );
        for value in ["0", "-1", "101", "not-a-number"] {
            assert_eq!(
                NotificationQuery {
                    limit: Some(value.to_owned())
                }
                .normalized_limit(),
                50,
                "value={value}"
            );
        }
    }
}
