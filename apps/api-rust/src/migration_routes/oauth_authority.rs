//! First-party OAuth 2.0 authority used by `lmm-api-rs` and the Web consent UI.

mod store;
mod types;

use std::sync::Arc;

use axum::{
    Form, Json, Router,
    extract::{
        DefaultBodyLimit, Extension, Path, Query, Request, State,
        rejection::{FormRejection, JsonRejection, QueryRejection},
    },
    http::{HeaderMap, HeaderValue, StatusCode, header},
    middleware::{self, Next},
    response::{IntoResponse, Response},
    routing::{get, post},
};
use chrono::Utc;
use secrecy::SecretString;
use serde::Serialize;
use serde_json::json;
use sqlx::PgPool;

use crate::{
    ClientIpKey,
    auth::{CriticalRateLimitOutcome, DashboardAuth, enforce_user_auth},
};

use self::{
    store::OAuthStore,
    types::{
        AccessPrincipal, AuthorityError, AuthorizationDecision, AuthorizationDecisionBody,
        AuthorizationPreview, AuthorizationQuery, CLIENT_ID, CreateKeyBody, DeviceCodeForm,
        DeviceDecision, DeviceDecisionBody, Metadata, RevokeForm, TokenForm, canonical_issuer,
        validate_authorization_query,
    },
};
use super::api_token::{OAuthApiTokenError, PgValkeyApiTokenService};

const OAUTH_BODY_LIMIT_BYTES: usize = 16 * 1024;
const DEVICE_GRANT_TYPE: &str = "urn:ietf:params:oauth:grant-type:device_code";

#[derive(Clone)]
pub struct OAuthAuthorityState {
    store: OAuthStore,
    dashboard_auth: Arc<dyn DashboardAuth>,
    api_tokens: Arc<PgValkeyApiTokenService>,
    issuer: Arc<str>,
}

#[derive(Clone, Copy)]
struct DashboardPrincipal(i64);

#[derive(Clone)]
struct ScopeGuardState {
    authority: OAuthAuthorityState,
    required_scope: &'static str,
    critical: bool,
}

impl OAuthAuthorityState {
    /// Creates the authority with a canonical HTTPS issuer (or local HTTP for development).
    ///
    /// # Errors
    ///
    /// Returns an error when `issuer` is not a safe public origin.
    pub fn new(
        pg: PgPool,
        dashboard_auth: Arc<dyn DashboardAuth>,
        api_tokens: Arc<PgValkeyApiTokenService>,
        session_secret: SecretString,
        issuer: &str,
    ) -> Result<Self, &'static str> {
        let issuer = canonical_issuer(issuer).map_err(|_| "invalid OAuth issuer")?;
        Ok(Self {
            store: OAuthStore::new(pg, session_secret),
            dashboard_auth,
            api_tokens,
            issuer: Arc::from(issuer),
        })
    }
}

pub fn router(state: OAuthAuthorityState) -> Router {
    let critical_layer = middleware::from_fn_with_state(state.clone(), critical_guard);
    let dashboard_layer = middleware::from_fn_with_state(state.clone(), dashboard_guard);
    let dashboard_mutation_layer =
        middleware::from_fn_with_state(state.clone(), dashboard_mutation_guard);
    let list_scope_layer = middleware::from_fn_with_state(
        ScopeGuardState {
            authority: state.clone(),
            required_scope: "api_keys:list",
            critical: false,
        },
        scope_guard,
    );
    let create_scope_layer = middleware::from_fn_with_state(
        ScopeGuardState {
            authority: state.clone(),
            required_scope: "api_keys:create",
            critical: true,
        },
        scope_guard,
    );
    let reveal_scope_layer = middleware::from_fn_with_state(
        ScopeGuardState {
            authority: state.clone(),
            required_scope: "api_keys:reveal",
            critical: true,
        },
        scope_guard,
    );

    Router::new()
        .route("/.well-known/oauth-authorization-server", get(metadata))
        .route(
            "/oauth/authorize",
            get(begin_authorization).route_layer(critical_layer.clone()),
        )
        .route(
            "/oauth/device/code",
            post(create_device_code).route_layer(critical_layer.clone()),
        )
        .route(
            "/oauth/token",
            post(exchange_token).route_layer(critical_layer.clone()),
        )
        .route(
            "/oauth/revoke",
            post(revoke_token).route_layer(critical_layer),
        )
        .route(
            "/api/oauth/authorization/{request}",
            get(authorization_preview).route_layer(dashboard_layer),
        )
        .route(
            "/api/oauth/authorization/{request}",
            post(decide_authorization).route_layer(dashboard_mutation_layer.clone()),
        )
        .route(
            "/api/oauth/device",
            post(decide_device).route_layer(dashboard_mutation_layer),
        )
        .route(
            "/api/oauth/bootstrap/keys",
            get(list_api_keys).route_layer(list_scope_layer),
        )
        .route(
            "/api/oauth/bootstrap/keys",
            post(create_api_key).route_layer(create_scope_layer),
        )
        .route(
            "/api/oauth/bootstrap/keys/{id}/reveal",
            post(reveal_api_key).route_layer(reveal_scope_layer),
        )
        .layer(DefaultBodyLimit::max(OAUTH_BODY_LIMIT_BYTES))
        .with_state(state)
}

async fn critical_guard(
    State(state): State<OAuthAuthorityState>,
    request: Request,
    next: Next,
) -> Response {
    if let Err(response) =
        enforce_critical_limit(&state, request.extensions().get::<ClientIpKey>()).await
    {
        return response;
    }
    next.run(request).await
}

async fn dashboard_guard(
    State(state): State<OAuthAuthorityState>,
    mut request: Request,
    next: Next,
) -> Response {
    let user_id = match dashboard_user_id(&state, request.headers()).await {
        Ok(user_id) => user_id,
        Err(response) => return response,
    };
    request.extensions_mut().insert(DashboardPrincipal(user_id));
    next.run(request).await
}

async fn dashboard_mutation_guard(
    State(state): State<OAuthAuthorityState>,
    mut request: Request,
    next: Next,
) -> Response {
    let user_id = match dashboard_user_id(&state, request.headers()).await {
        Ok(user_id) => user_id,
        Err(response) => return response,
    };
    if let Err(response) =
        enforce_critical_limit(&state, request.extensions().get::<ClientIpKey>()).await
    {
        return response;
    }
    request.extensions_mut().insert(DashboardPrincipal(user_id));
    next.run(request).await
}

async fn scope_guard(
    State(guard): State<ScopeGuardState>,
    mut request: Request,
    next: Next,
) -> Response {
    let principal =
        match access_principal(&guard.authority, request.headers(), guard.required_scope).await {
            Ok(principal) => principal,
            Err(response) => return response,
        };
    if guard.critical
        && let Err(response) =
            enforce_critical_limit(&guard.authority, request.extensions().get::<ClientIpKey>())
                .await
    {
        return response;
    }
    request.extensions_mut().insert(principal);
    next.run(request).await
}

async fn metadata(State(state): State<OAuthAuthorityState>) -> Response {
    let issuer = state.issuer.as_ref();
    oauth_json(
        StatusCode::OK,
        &Metadata {
            issuer: issuer.to_owned(),
            authorization_endpoint: format!("{issuer}/oauth/authorize"),
            token_endpoint: format!("{issuer}/oauth/token"),
            revocation_endpoint: format!("{issuer}/oauth/revoke"),
            device_authorization_endpoint: format!("{issuer}/oauth/device/code"),
            response_types_supported: ["code"],
            grant_types_supported: ["authorization_code", DEVICE_GRANT_TYPE, "refresh_token"],
            code_challenge_methods_supported: ["S256"],
            token_endpoint_auth_methods_supported: ["none"],
            scopes_supported: [
                "api_keys:list",
                "api_keys:create",
                "api_keys:reveal",
                "cc_switch:import",
            ],
        },
    )
}

async fn begin_authorization(
    State(state): State<OAuthAuthorityState>,
    input: Result<Query<AuthorizationQuery>, QueryRejection>,
) -> Response {
    let Query(input) = match input {
        Ok(input) => input,
        Err(_) => return protocol_error(AuthorityError::InvalidRequest),
    };
    let payload = match validate_authorization_query(&input) {
        Ok(payload) => payload,
        Err(error) => return protocol_error(error),
    };
    let request = match state
        .store
        .create_authorization_request(&payload, Utc::now())
        .await
    {
        Ok(request) => request,
        Err(error) => return protocol_error(error),
    };
    let mut consent = match reqwest::Url::parse(&format!("{}/oauth/consent", state.issuer)) {
        Ok(consent) => consent,
        Err(_) => return protocol_error(AuthorityError::Storage),
    };
    consent.query_pairs_mut().append_pair("request", &request);
    let location = match HeaderValue::from_str(consent.as_str()) {
        Ok(location) => location,
        Err(_) => return protocol_error(AuthorityError::Storage),
    };
    let mut response = StatusCode::FOUND.into_response();
    response.headers_mut().insert(header::LOCATION, location);
    apply_no_store_headers(&mut response);
    response
}

async fn authorization_preview(
    State(state): State<OAuthAuthorityState>,
    Extension(_principal): Extension<DashboardPrincipal>,
    Path(request): Path<String>,
) -> Response {
    match state
        .store
        .authorization_preview(&request, Utc::now())
        .await
    {
        Ok((payload, expires_at)) => legacy_success(AuthorizationPreview {
            client_id: payload.client_id,
            client_name: CLIENT_ID.to_owned(),
            redirect_uri: payload.redirect_uri,
            scopes: payload
                .scope
                .split_whitespace()
                .map(str::to_owned)
                .collect(),
            expires_at: expires_at.to_rfc3339(),
        }),
        Err(error) => legacy_error(error),
    }
}

async fn decide_authorization(
    State(state): State<OAuthAuthorityState>,
    Extension(principal): Extension<DashboardPrincipal>,
    Path(request): Path<String>,
    body: Result<Json<AuthorizationDecisionBody>, JsonRejection>,
) -> Response {
    let Json(body) = match body {
        Ok(body) => body,
        Err(_) => return legacy_error(AuthorityError::InvalidRequest),
    };
    let user_id = principal.0;
    match state
        .store
        .decide_authorization(&request, user_id, body.approve, Utc::now())
        .await
    {
        Ok(redirect_uri) => legacy_success(AuthorizationDecision { redirect_uri }),
        Err(error) => legacy_error(error),
    }
}

async fn create_device_code(
    State(state): State<OAuthAuthorityState>,
    input: Result<Form<DeviceCodeForm>, FormRejection>,
) -> Response {
    let Form(input) = match input {
        Ok(input) => input,
        Err(_) => return protocol_error(AuthorityError::InvalidRequest),
    };
    match state
        .store
        .create_device_authorization(&input.client_id, &input.scope, &state.issuer, Utc::now())
        .await
    {
        Ok(device) => oauth_json(StatusCode::OK, &device),
        Err(error) => protocol_error(error),
    }
}

async fn decide_device(
    State(state): State<OAuthAuthorityState>,
    Extension(principal): Extension<DashboardPrincipal>,
    body: Result<Json<DeviceDecisionBody>, JsonRejection>,
) -> Response {
    let Json(body) = match body {
        Ok(body) => body,
        Err(_) => return legacy_error(AuthorityError::InvalidRequest),
    };
    let user_id = principal.0;
    match state
        .store
        .decide_device(&body.user_code, user_id, body.approve, Utc::now())
        .await
    {
        Ok(approved) => legacy_success(DeviceDecision { approved }),
        Err(error) => legacy_error(error),
    }
}

async fn exchange_token(
    State(state): State<OAuthAuthorityState>,
    input: Result<Form<TokenForm>, FormRejection>,
) -> Response {
    let Form(input) = match input {
        Ok(input) => input,
        Err(_) => return protocol_error(AuthorityError::InvalidRequest),
    };
    let now = Utc::now();
    let result = match input.grant_type.as_str() {
        "authorization_code" => {
            if input.code.is_empty()
                || input.redirect_uri.is_empty()
                || input.client_id.is_empty()
                || input.code_verifier.is_empty()
            {
                Err(AuthorityError::InvalidRequest)
            } else {
                state
                    .store
                    .exchange_authorization_code(
                        &input.code,
                        &input.client_id,
                        &input.redirect_uri,
                        &input.code_verifier,
                        now,
                    )
                    .await
            }
        }
        DEVICE_GRANT_TYPE => {
            if input.device_code.is_empty() || input.client_id.is_empty() {
                Err(AuthorityError::InvalidRequest)
            } else {
                state
                    .store
                    .exchange_device_code(&input.device_code, &input.client_id, now)
                    .await
            }
        }
        "refresh_token" => {
            if input.refresh_token.is_empty() || input.client_id.is_empty() {
                Err(AuthorityError::InvalidRequest)
            } else {
                state
                    .store
                    .rotate_refresh_token(&input.refresh_token, &input.client_id, now)
                    .await
            }
        }
        _ => Err(AuthorityError::InvalidRequest),
    };
    match result {
        Ok(tokens) => oauth_json(StatusCode::OK, &tokens),
        Err(error) => protocol_error(error),
    }
}

async fn revoke_token(
    State(state): State<OAuthAuthorityState>,
    input: Result<Form<RevokeForm>, FormRejection>,
) -> Response {
    let Form(input) = match input {
        Ok(input) => input,
        Err(_) => return protocol_error(AuthorityError::InvalidRequest),
    };
    if input.token.is_empty() || input.client_id.is_empty() {
        return protocol_error(AuthorityError::InvalidRequest);
    }
    match state
        .store
        .revoke_token(&input.token, &input.client_id, Utc::now())
        .await
    {
        Ok(()) => no_store_empty(StatusCode::OK),
        Err(error) => protocol_error(error),
    }
}

async fn list_api_keys(
    State(state): State<OAuthAuthorityState>,
    Extension(principal): Extension<AccessPrincipal>,
) -> Response {
    match state.api_tokens.oauth_list(principal.user_id).await {
        Ok(keys) => oauth_json(StatusCode::OK, &keys),
        Err(error) => api_token_error(error),
    }
}

async fn create_api_key(
    State(state): State<OAuthAuthorityState>,
    Extension(principal): Extension<AccessPrincipal>,
    body: Result<Json<CreateKeyBody>, JsonRejection>,
) -> Response {
    let Json(body) = match body {
        Ok(body) => body,
        Err(_) => return protocol_error(AuthorityError::InvalidRequest),
    };
    match state
        .api_tokens
        .oauth_create(principal.user_id, &body.name)
        .await
    {
        Ok(key) => oauth_json(StatusCode::OK, &key),
        Err(error) => api_token_error(error),
    }
}

async fn reveal_api_key(
    State(state): State<OAuthAuthorityState>,
    Extension(principal): Extension<AccessPrincipal>,
    Path(id): Path<i64>,
) -> Response {
    match state.api_tokens.oauth_reveal(principal.user_id, id).await {
        Ok(key) => oauth_json(StatusCode::OK, &key),
        Err(error) => api_token_error(error),
    }
}

async fn dashboard_user_id(
    state: &OAuthAuthorityState,
    headers: &HeaderMap,
) -> Result<i64, Response> {
    let access_token =
        bearer_token(headers).ok_or_else(|| legacy_error(AuthorityError::Unauthorized))?;
    let user = state
        .dashboard_auth
        .self_user(SecretString::from(access_token.to_owned()))
        .await
        .map_err(|_| legacy_error(AuthorityError::Unauthorized))?;
    enforce_user_auth(&user).map_err(|_| legacy_error(AuthorityError::Unauthorized))?;
    Ok(user.id)
}

async fn access_principal(
    state: &OAuthAuthorityState,
    headers: &HeaderMap,
    required_scope: &str,
) -> Result<AccessPrincipal, Response> {
    let access_token =
        bearer_token(headers).ok_or_else(|| protocol_error(AuthorityError::Unauthorized))?;
    let principal = state
        .store
        .access_principal(access_token, Utc::now())
        .await
        .map_err(protocol_error)?;
    principal
        .require_scope(required_scope)
        .map_err(protocol_error)?;
    Ok(principal)
}

async fn enforce_critical_limit(
    state: &OAuthAuthorityState,
    client_ip: Option<&ClientIpKey>,
) -> Result<(), Response> {
    let client_ip = client_ip
        .map(|value| value.0.as_str())
        .ok_or_else(|| protocol_error(AuthorityError::Storage))?;
    match state
        .dashboard_auth
        .check_critical_rate_limit(client_ip)
        .await
    {
        Ok(CriticalRateLimitOutcome::Allowed) => Ok(()),
        Ok(CriticalRateLimitOutcome::Rejected {
            retry_after_seconds,
        }) => {
            let mut response = oauth_json(
                StatusCode::TOO_MANY_REQUESTS,
                &json!({
                    "error": "temporarily_unavailable",
                    "error_description": "Too many sensitive requests; retry later."
                }),
            );
            if let Ok(value) = HeaderValue::from_str(&retry_after_seconds.to_string()) {
                response.headers_mut().insert(header::RETRY_AFTER, value);
            }
            Err(response)
        }
        Err(_) => Err(protocol_error(AuthorityError::Storage)),
    }
}

fn bearer_token(headers: &HeaderMap) -> Option<&str> {
    let value = headers.get(header::AUTHORIZATION)?.to_str().ok()?;
    let (scheme, token) = value.split_once(' ')?;
    if scheme.eq_ignore_ascii_case("bearer")
        && !token.is_empty()
        && !token.chars().any(char::is_whitespace)
    {
        Some(token)
    } else {
        None
    }
}

fn legacy_success<T: Serialize>(data: T) -> Response {
    oauth_json(StatusCode::OK, &json!({ "success": true, "data": data }))
}

fn legacy_error(error: AuthorityError) -> Response {
    let status = match error {
        AuthorityError::Unauthorized => StatusCode::UNAUTHORIZED,
        AuthorityError::Storage => StatusCode::SERVICE_UNAVAILABLE,
        _ => StatusCode::BAD_REQUEST,
    };
    let message = match error {
        AuthorityError::InvalidGrant => "The OAuth request is invalid, expired, or already used.",
        AuthorityError::Unauthorized => "Authentication is required.",
        AuthorityError::Storage => "The OAuth authority is temporarily unavailable.",
        _ => "The OAuth request could not be completed.",
    };
    oauth_json(status, &json!({ "success": false, "message": message }))
}

fn protocol_error(error: AuthorityError) -> Response {
    let (status, code, description) = match error {
        AuthorityError::InvalidRequest => (
            StatusCode::BAD_REQUEST,
            "invalid_request",
            "The request is missing or invalid.",
        ),
        AuthorityError::InvalidClient => (
            StatusCode::UNAUTHORIZED,
            "invalid_client",
            "The OAuth client is not supported.",
        ),
        AuthorityError::InvalidGrant => (
            StatusCode::BAD_REQUEST,
            "invalid_grant",
            "The grant is invalid, expired, revoked, or already used.",
        ),
        AuthorityError::InvalidScope => (
            StatusCode::BAD_REQUEST,
            "invalid_scope",
            "One or more requested scopes are not supported.",
        ),
        AuthorityError::AuthorizationPending => (
            StatusCode::BAD_REQUEST,
            "authorization_pending",
            "The user has not completed authorization.",
        ),
        AuthorityError::SlowDown => (
            StatusCode::BAD_REQUEST,
            "slow_down",
            "Poll less frequently.",
        ),
        AuthorityError::AccessDenied => (
            StatusCode::BAD_REQUEST,
            "access_denied",
            "The user denied authorization.",
        ),
        AuthorityError::ExpiredToken => (
            StatusCode::BAD_REQUEST,
            "expired_token",
            "The device code has expired.",
        ),
        AuthorityError::Unauthorized => (
            StatusCode::UNAUTHORIZED,
            "invalid_token",
            "The access token is invalid or expired.",
        ),
        AuthorityError::InsufficientScope => (
            StatusCode::FORBIDDEN,
            "insufficient_scope",
            "The access token does not grant the required scope.",
        ),
        AuthorityError::Storage => (
            StatusCode::SERVICE_UNAVAILABLE,
            "temporarily_unavailable",
            "The OAuth authority is temporarily unavailable.",
        ),
    };
    let mut response = oauth_json(
        status,
        &json!({ "error": code, "error_description": description }),
    );
    if matches!(
        error,
        AuthorityError::Unauthorized | AuthorityError::InsufficientScope
    ) {
        let challenge = format!("Bearer realm=\"api.lmm.best\", error=\"{code}\"");
        if let Ok(value) = HeaderValue::from_str(&challenge) {
            response
                .headers_mut()
                .insert(header::WWW_AUTHENTICATE, value);
        }
    }
    response
}

fn api_token_error(error: OAuthApiTokenError) -> Response {
    let (status, code, description) = match error {
        OAuthApiTokenError::InvalidName => (
            StatusCode::BAD_REQUEST,
            "invalid_request",
            "The API Key name is invalid.",
        ),
        OAuthApiTokenError::Limit => (
            StatusCode::CONFLICT,
            "api_key_limit_reached",
            "The API Key limit has been reached.",
        ),
        OAuthApiTokenError::NotFound => (
            StatusCode::NOT_FOUND,
            "api_key_not_found",
            "The requested API Key was not found.",
        ),
        OAuthApiTokenError::Unavailable => (
            StatusCode::SERVICE_UNAVAILABLE,
            "temporarily_unavailable",
            "API Key storage is temporarily unavailable.",
        ),
    };
    oauth_json(
        status,
        &json!({ "error": code, "error_description": description }),
    )
}

fn oauth_json<T: Serialize + ?Sized>(status: StatusCode, body: &T) -> Response {
    let mut response = (status, Json(body)).into_response();
    apply_no_store_headers(&mut response);
    response
}

fn no_store_empty(status: StatusCode) -> Response {
    let mut response = status.into_response();
    apply_no_store_headers(&mut response);
    response
}

fn apply_no_store_headers(response: &mut Response) {
    response
        .headers_mut()
        .insert(header::CACHE_CONTROL, HeaderValue::from_static("no-store"));
    response
        .headers_mut()
        .insert(header::PRAGMA, HeaderValue::from_static("no-cache"));
}

#[cfg(test)]
mod tests {
    use super::bearer_token;
    use axum::http::{HeaderMap, HeaderValue, header};

    #[test]
    fn bearer_token_accepts_one_case_insensitive_scheme_and_no_whitespace() {
        let mut headers = HeaderMap::new();
        headers.insert(
            header::AUTHORIZATION,
            HeaderValue::from_static("bEaReR opaque-token"),
        );
        assert_eq!(bearer_token(&headers), Some("opaque-token"));
    }

    #[test]
    fn bearer_token_rejects_malformed_or_ambiguous_values() {
        for value in [
            "opaque-token",
            "Basic opaque-token",
            "Bearer ",
            "Bearer one two",
            "Bearer\tone",
        ] {
            let mut headers = HeaderMap::new();
            headers.insert(
                header::AUTHORIZATION,
                HeaderValue::from_str(value).expect("test header must be valid"),
            );
            assert_eq!(bearer_token(&headers), None, "value: {value}");
        }
    }
}
