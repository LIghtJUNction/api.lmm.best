//! Legacy relay routes which do not belong to the OpenAI chat, media, or
//! Anthropic/Gemini protocol slices.
//!
//! This file is deliberately self-contained while the migration router is
//! being assembled.  `routes` must be merged behind the same token-auth,
//! performance, rate-limit and channel-distribution adapters as legacy
//! `SetRelayRouter`; do not mount it as a public router.

use std::sync::Arc;

use async_trait::async_trait;
use axum::{
    Json, Router,
    body::{Body, Bytes, to_bytes},
    extract::{Request, State},
    http::{HeaderMap, HeaderName, StatusCode, header},
    response::{IntoResponse, Response},
    routing::{get, post},
};
use serde::{Deserialize, Serialize};

const MAX_RELAY_BODY_BYTES: usize = 128 * 1024 * 1024;

/// The four relay formats owned by this migration slice.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum RelayProtocol {
    AlphaSearch,
    Embedding,
    Rerank,
    OpenAi,
}

/// Request metadata produced at the same point as legacy `Distribute`.
///
/// The selected-channel adapter consumes this value from request extensions;
/// it must not re-derive a different model or upstream path later.
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct RelayRequestContext {
    pub protocol: RelayProtocol,
    pub path: String,
    pub model: Option<String>,
    pub stream: bool,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum RelayBodyEncoding {
    Identity,
    Gzip,
    Brotli,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct RelayAccounting {
    pub protocol: RelayProtocol,
    pub status: StatusCode,
    pub upstream_succeeded: bool,
}

/// Outcome of the outer legacy token-auth and channel-distribution pipeline.
///
/// The concrete implementation is intentionally supplied by the eventual
/// PostgreSQL/Valkey adapter.  Valkey is only a cache: an outage must fall
/// back to PostgreSQL instead of granting or denying access from stale state.
#[derive(Clone, Debug, Eq, PartialEq)]
pub enum RelayAuth {
    Authorized,
    Rejected { status: StatusCode, message: String },
}

#[async_trait]
pub trait RelayMiscService: Send + Sync {
    /// Legacy `SystemPerformanceCheck`. The default is deliberately closed so
    /// an adapter cannot accidentally skip load shedding.
    async fn system_performance(&self, _request: &Request) -> RelayAuth {
        missing_stage("system performance")
    }

    /// Legacy `TokenAuth`.
    async fn authorize(&self, request: &Request) -> RelayAuth;

    /// Legacy `ModelRequestRateLimit`, after token authentication and before
    /// request parsing/channel selection.
    async fn model_rate_limit(&self, _request: &Request) -> RelayAuth {
        missing_stage("model rate limit")
    }

    /// Legacy `Distribute`, including model access and channel selection.
    async fn distribute(&self, _context: &RelayRequestContext, _request: &Request) -> RelayAuth {
        missing_stage("channel distribution")
    }

    /// Decode a request body exactly once. Implementations must reject invalid
    /// gzip as 400, support gzip and Brotli, and return decompressed bytes.
    /// The default accepts identity only and fails closed for encoded bodies.
    async fn decode_body(
        &self,
        encoding: RelayBodyEncoding,
        body: Bytes,
    ) -> Result<Bytes, RelayAuth> {
        match encoding {
            RelayBodyEncoding::Identity => Ok(body),
            RelayBodyEncoding::Gzip | RelayBodyEncoding::Brotli => {
                Err(missing_stage("request decompression"))
            }
        }
    }

    /// Apply selected-channel credentials and header overrides to the safe
    /// legacy baseline. The input never contains caller credentials,
    /// `Accept-Encoding`, or hop-by-hop headers.
    async fn provider_headers(
        &self,
        _context: &RelayRequestContext,
        _headers: &HeaderMap,
    ) -> Result<HeaderMap, RelayAuth> {
        Err(missing_stage("provider header override"))
    }

    /// Send an already-authorized request to the selected upstream.  Returning
    /// `Response` rather than decoded JSON is intentional: it preserves binary
    /// replies and chunked/SSE relay streams byte-for-byte. The response body
    /// must own the upstream cancellation guard so dropping it cancels I/O.
    async fn relay(&self, protocol: RelayProtocol, request: Request) -> Response;

    /// Commit/refund quota, usage logs, rate-limit success state, and channel
    /// health for both successful and failed upstream responses.
    async fn account(
        &self,
        _context: &RelayRequestContext,
        _accounting: RelayAccounting,
    ) -> RelayAuth {
        missing_stage("relay accounting")
    }
}

#[derive(Clone)]
pub struct RelayMiscHttpState {
    service: Arc<dyn RelayMiscService>,
}

impl RelayMiscHttpState {
    #[must_use]
    pub fn new(service: Arc<dyn RelayMiscService>) -> Self {
        Self { service }
    }
}

/// Routes to merge into the authenticated relay router.
///
/// Included legacy paths:
/// - pass-through: alpha search, embeddings, rerank, and moderations;
/// - conditionally-501 endpoints: files, fine-tunes, and image variations.
///
/// The latter are 501 only after every legacy gate accepts them; auth,
/// rate-limit, malformed-model, and no-channel responses take precedence.
pub fn routes(state: RelayMiscHttpState) -> Router {
    Router::new()
        .route("/v1/alpha/search", post(alpha_search))
        .route("/v1/embeddings", post(embeddings))
        .route("/v1/rerank", post(rerank))
        .route("/v1/moderations", post(moderations))
        .route("/v1/images/variations", post(not_implemented))
        .route("/v1/files", get(not_implemented).post(not_implemented))
        .route(
            "/v1/files/{id}",
            get(not_implemented).delete(not_implemented),
        )
        .route("/v1/files/{id}/content", get(not_implemented))
        .route("/v1/fine-tunes", get(not_implemented).post(not_implemented))
        .route("/v1/fine-tunes/{id}", get(not_implemented))
        .route("/v1/fine-tunes/{id}/cancel", post(not_implemented))
        .route("/v1/fine-tunes/{id}/events", get(not_implemented))
        .with_state(state)
}

async fn alpha_search(State(state): State<RelayMiscHttpState>, request: Request) -> Response {
    relay(state, RelayProtocol::AlphaSearch, request).await
}

async fn embeddings(State(state): State<RelayMiscHttpState>, request: Request) -> Response {
    relay(state, RelayProtocol::Embedding, request).await
}

async fn rerank(State(state): State<RelayMiscHttpState>, request: Request) -> Response {
    relay(state, RelayProtocol::Rerank, request).await
}

async fn moderations(State(state): State<RelayMiscHttpState>, request: Request) -> Response {
    relay(state, RelayProtocol::OpenAi, request).await
}

async fn relay(state: RelayMiscHttpState, protocol: RelayProtocol, request: Request) -> Response {
    execute(state, protocol, request, false).await
}

async fn execute(
    state: RelayMiscHttpState,
    protocol: RelayProtocol,
    request: Request,
    frozen_not_implemented: bool,
) -> Response {
    let mut request = match decoded_request(state.service.as_ref(), request).await {
        Ok(request) => request,
        Err(response) => return response,
    };
    if let Err(response) = accepted(state.service.system_performance(&request).await) {
        return response;
    }
    if let Err(response) = accepted(state.service.authorize(&request).await) {
        return response;
    }
    if let Err(response) = accepted(state.service.model_rate_limit(&request).await) {
        return response;
    }
    let context = match request_context(protocol, &request) {
        Ok(context) => context,
        Err(response) => return response,
    };
    if let Err(response) = accepted(state.service.distribute(&context, &request).await) {
        return response;
    }
    if frozen_not_implemented {
        return not_implemented_response();
    }

    let baseline = upstream_request_headers(&context, request.headers());
    let headers = match state.service.provider_headers(&context, &baseline).await {
        Ok(headers) => sanitize_provider_headers(&headers),
        Err(rejection) => return rejected(rejection),
    };
    *request.headers_mut() = headers;
    request.extensions_mut().insert(context.clone());

    let response = filtered_upstream_response(state.service.relay(protocol, request).await);
    let accounting = RelayAccounting {
        protocol,
        status: response.status(),
        upstream_succeeded: response.status().is_success(),
    };
    if let Err(response) = accepted(state.service.account(&context, accounting).await) {
        return response;
    }
    response
}

/// Recreates the global legacy decompression boundary. Encoded bytes are never
/// forwarded with `Content-Encoding` removed: the header is deleted only after
/// the injected decoder succeeds, and the 128 MiB cap is checked again on the
/// decompressed representation.
async fn decoded_request(
    service: &dyn RelayMiscService,
    request: Request,
) -> Result<Request, Response> {
    let (mut parts, body) = request.into_parts();
    let encoded = to_bytes(body, MAX_RELAY_BODY_BYTES + 1)
        .await
        .map_err(|_| {
            legacy_request_error(StatusCode::PAYLOAD_TOO_LARGE, "request body too large")
        })?;
    if encoded.len() > MAX_RELAY_BODY_BYTES {
        return Err(legacy_request_error(
            StatusCode::PAYLOAD_TOO_LARGE,
            "request body too large",
        ));
    }
    let encoding = match parts
        .headers
        .get(header::CONTENT_ENCODING)
        .and_then(|value| value.to_str().ok())
    {
        Some("gzip") => RelayBodyEncoding::Gzip,
        Some("br") => RelayBodyEncoding::Brotli,
        _ => RelayBodyEncoding::Identity,
    };
    let decoded = service
        .decode_body(encoding, encoded)
        .await
        .map_err(rejected)?;
    if decoded.len() > MAX_RELAY_BODY_BYTES {
        return Err(legacy_request_error(
            StatusCode::PAYLOAD_TOO_LARGE,
            "request body too large",
        ));
    }
    if encoding != RelayBodyEncoding::Identity {
        parts.headers.remove(header::CONTENT_ENCODING);
    }
    parts.extensions.insert(PreparedRelayBody(decoded.clone()));
    Ok(Request::from_parts(parts, Body::from(decoded)))
}

#[derive(Clone)]
struct PreparedRelayBody(Bytes);

#[derive(Deserialize)]
struct ModelRequest {
    model: Option<serde_json::Value>,
    stream: Option<bool>,
}

fn request_context(
    protocol: RelayProtocol,
    request: &Request,
) -> Result<RelayRequestContext, Response> {
    let path = request.uri().path().to_owned();
    let bytes = request
        .extensions()
        .get::<PreparedRelayBody>()
        .map_or_else(Bytes::new, |body| body.0.clone());
    let parsed = if bytes.is_empty() {
        ModelRequest {
            model: None,
            stream: None,
        }
    } else {
        serde_json::from_slice::<ModelRequest>(&bytes).map_err(|_| {
            legacy_request_error(StatusCode::BAD_REQUEST, "invalid JSON request body")
        })?
    };
    let body_model = match parsed.model {
        Some(serde_json::Value::String(model)) => Some(model),
        Some(serde_json::Value::Null) | None => None,
        Some(_) => {
            return Err(legacy_request_error(
                StatusCode::BAD_REQUEST,
                "field model must be a string",
            ));
        }
    };
    let model = body_model.or_else(|| {
        (protocol == RelayProtocol::OpenAi && path == "/v1/moderations")
            .then(|| "text-moderation-stable".to_owned())
    });
    Ok(RelayRequestContext {
        protocol,
        path,
        model,
        stream: parsed.stream.unwrap_or(false),
    })
}

fn upstream_request_headers(context: &RelayRequestContext, headers: &HeaderMap) -> HeaderMap {
    let mut forwarded = filter_headers(headers, |name| {
        matches!(name.as_str(), "accept" | "content-type")
    });
    if context.stream && !forwarded.contains_key(header::ACCEPT) {
        forwarded.insert(
            header::ACCEPT,
            axum::http::HeaderValue::from_static("text/event-stream"),
        );
    }
    forwarded
}

fn sanitize_provider_headers(headers: &HeaderMap) -> HeaderMap {
    let connection_named = connection_named_headers(headers);
    filter_headers(headers, |name| {
        !connection_named.iter().any(|candidate| candidate == name) && !is_hop_by_hop(name)
    })
}

fn filtered_upstream_response(mut response: Response) -> Response {
    let connection_named = connection_named_headers(response.headers());
    let headers = filter_headers(response.headers(), |name| {
        !connection_named
            .iter()
            .any(|connection_name| connection_name == name)
            && !is_hop_by_hop(name)
    });
    *response.headers_mut() = headers;
    response
}

fn connection_named_headers(headers: &HeaderMap) -> Vec<HeaderName> {
    headers
        .get_all(header::CONNECTION)
        .iter()
        .filter_map(|value| value.to_str().ok())
        .flat_map(|value| value.split(','))
        .filter_map(|value| HeaderName::try_from(value.trim()).ok())
        .collect()
}

fn is_hop_by_hop(name: &HeaderName) -> bool {
    matches!(
        name.as_str(),
        "connection"
            | "keep-alive"
            | "proxy-authenticate"
            | "proxy-authorization"
            | "te"
            | "trailer"
            | "transfer-encoding"
            | "upgrade"
    )
}

fn filter_headers(headers: &HeaderMap, include: impl Fn(&HeaderName) -> bool) -> HeaderMap {
    headers
        .iter()
        .filter(|(name, _)| include(name))
        .map(|(name, value)| (name.clone(), value.clone()))
        .collect()
}

async fn not_implemented(State(state): State<RelayMiscHttpState>, request: Request) -> Response {
    execute(state, RelayProtocol::OpenAi, request, true).await
}

fn not_implemented_response() -> Response {
    let mut response = (
        StatusCode::NOT_IMPLEMENTED,
        Json(LegacyNotImplementedEnvelope {
            error: LegacyOpenAiError {
                message: "API not implemented",
                kind: "new_api_error",
                param: "",
                code: "api_not_implemented",
            },
        }),
    )
        .into_response();
    response.headers_mut().insert(
        header::CONTENT_TYPE,
        axum::http::HeaderValue::from_static("application/json; charset=utf-8"),
    );
    response
}

fn accepted(outcome: RelayAuth) -> Result<(), Response> {
    match outcome {
        RelayAuth::Authorized => Ok(()),
        rejection => Err(rejected(rejection)),
    }
}

fn rejected(rejection: RelayAuth) -> Response {
    match rejection {
        RelayAuth::Authorized => legacy_request_error(
            StatusCode::INTERNAL_SERVER_ERROR,
            "invalid authorized rejection",
        ),
        RelayAuth::Rejected { status, message } => legacy_auth_error(status, message),
    }
}

fn missing_stage(stage: &'static str) -> RelayAuth {
    RelayAuth::Rejected {
        status: StatusCode::SERVICE_UNAVAILABLE,
        message: format!("Rust relay-misc {stage} adapter is unavailable"),
    }
}

fn legacy_auth_error(status: StatusCode, message: String) -> Response {
    (
        status,
        Json(LegacyErrorEnvelope {
            error: LegacyOpenAiError {
                message: &message,
                kind: "new_api_error",
                param: "",
                code: "",
            },
        }),
    )
        .into_response()
}

fn legacy_request_error(status: StatusCode, message: &'static str) -> Response {
    (
        status,
        Json(LegacyErrorEnvelope {
            error: LegacyOpenAiError {
                message,
                kind: "invalid_request_error",
                param: "",
                code: "",
            },
        }),
    )
        .into_response()
}

#[derive(Serialize)]
struct LegacyNotImplementedEnvelope {
    error: LegacyOpenAiError<&'static str>,
}

#[derive(Serialize)]
struct LegacyErrorEnvelope<'a> {
    error: LegacyOpenAiError<&'a str>,
}

#[derive(Serialize)]
struct LegacyOpenAiError<T: Serialize> {
    message: T,
    #[serde(rename = "type")]
    kind: &'static str,
    param: &'static str,
    code: &'static str,
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::atomic::{AtomicUsize, Ordering};

    use axum::{
        body::Body,
        http::{HeaderValue, Request as HttpRequest},
    };
    use tower::ServiceExt;

    #[cfg(test)]
    use axum::http::header;

    #[derive(Clone)]
    struct TestService {
        auth: RelayAuth,
        status: StatusCode,
        headers: Vec<(&'static str, &'static str)>,
        body: Vec<u8>,
    }

    #[async_trait]
    impl RelayMiscService for TestService {
        async fn system_performance(&self, _: &Request) -> RelayAuth {
            RelayAuth::Authorized
        }
        async fn authorize(&self, _: &Request) -> RelayAuth {
            self.auth.clone()
        }
        async fn model_rate_limit(&self, _: &Request) -> RelayAuth {
            RelayAuth::Authorized
        }
        async fn distribute(&self, _: &RelayRequestContext, _: &Request) -> RelayAuth {
            RelayAuth::Authorized
        }
        async fn provider_headers(
            &self,
            _: &RelayRequestContext,
            headers: &HeaderMap,
        ) -> Result<HeaderMap, RelayAuth> {
            Ok(headers.clone())
        }
        async fn relay(&self, _: RelayProtocol, _: Request) -> Response {
            let mut reply = Response::new(Body::from(self.body.clone()));
            *reply.status_mut() = self.status;
            for (name, value) in &self.headers {
                reply
                    .headers_mut()
                    .insert(*name, HeaderValue::from_static(value));
            }
            reply
        }
        async fn account(&self, _: &RelayRequestContext, _: RelayAccounting) -> RelayAuth {
            RelayAuth::Authorized
        }
    }

    fn app(
        auth: RelayAuth,
        status: StatusCode,
        headers: Vec<(&'static str, &'static str)>,
        body: Vec<u8>,
    ) -> Router {
        routes(RelayMiscHttpState::new(Arc::new(TestService {
            auth,
            status,
            headers,
            body,
        })))
    }

    #[test]
    fn route_construction_has_no_duplicate_misc_paths() {
        let result = std::panic::catch_unwind(|| {
            let _router = app(RelayAuth::Authorized, StatusCode::OK, vec![], vec![]);
        });
        assert!(result.is_ok());
    }

    #[tokio::test]
    async fn unsupported_routes_keep_legacy_501_json_after_authentication() {
        let response = app(RelayAuth::Authorized, StatusCode::OK, vec![], vec![])
            .oneshot(
                HttpRequest::delete("/v1/files/file-1")
                    .body(Body::empty())
                    .unwrap(),
            )
            .await
            .unwrap();
        assert_eq!(response.status(), StatusCode::NOT_IMPLEMENTED);
        assert_eq!(
            response.headers()[header::CONTENT_TYPE],
            "application/json; charset=utf-8"
        );
        let body = axum::body::to_bytes(response.into_body(), usize::MAX)
            .await
            .unwrap();
        assert_eq!(
            body,
            r#"{"error":{"message":"API not implemented","type":"new_api_error","param":"","code":"api_not_implemented"}}"#
        );
    }

    #[tokio::test]
    async fn authorization_failure_prevents_an_upstream_call() {
        let response = app(
            RelayAuth::Rejected {
                status: StatusCode::UNAUTHORIZED,
                message: "Invalid token".into(),
            },
            StatusCode::OK,
            vec![],
            b"must not be forwarded".to_vec(),
        )
        .oneshot(HttpRequest::post("/v1/rerank").body(Body::empty()).unwrap())
        .await
        .unwrap();
        assert_eq!(response.status(), StatusCode::UNAUTHORIZED);
        let body = axum::body::to_bytes(response.into_body(), usize::MAX)
            .await
            .unwrap();
        assert!(
            std::str::from_utf8(&body)
                .unwrap()
                .contains("Invalid token")
        );
    }

    #[tokio::test]
    async fn upstream_error_binary_body_and_headers_are_untouched() {
        let response = app(
            RelayAuth::Authorized,
            StatusCode::BAD_GATEWAY,
            vec![
                ("content-type", "audio/mpeg"),
                ("x-upstream-request-id", "up-1"),
            ],
            vec![0, 255, 7],
        )
        .oneshot(
            HttpRequest::post("/v1/embeddings")
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();
        assert_eq!(response.status(), StatusCode::BAD_GATEWAY);
        assert_eq!(response.headers()[header::CONTENT_TYPE], "audio/mpeg");
        assert_eq!(response.headers()["x-upstream-request-id"], "up-1");
        assert_eq!(
            axum::body::to_bytes(response.into_body(), usize::MAX)
                .await
                .unwrap(),
            vec![0, 255, 7]
        );
    }

    #[test]
    fn forwarded_request_headers_exclude_client_credentials_and_transport_state() {
        let mut headers = HeaderMap::new();
        headers.insert(header::ACCEPT, HeaderValue::from_static("application/json"));
        headers.insert(
            header::CONTENT_TYPE,
            HeaderValue::from_static("application/json"),
        );
        headers.insert(
            header::AUTHORIZATION,
            HeaderValue::from_static("Bearer client-secret"),
        );
        headers.insert(header::CONNECTION, HeaderValue::from_static("x-client-hop"));
        headers.insert("x-client-hop", HeaderValue::from_static("do-not-forward"));
        headers.insert("x-request-id", HeaderValue::from_static("request-1"));

        let forwarded = upstream_request_headers(
            &RelayRequestContext {
                protocol: RelayProtocol::Embedding,
                path: "/v1/embeddings".to_owned(),
                model: Some("text-embedding-3-small".to_owned()),
                stream: false,
            },
            &headers,
        );

        assert_eq!(forwarded[header::ACCEPT], "application/json");
        assert_eq!(forwarded[header::CONTENT_TYPE], "application/json");
        assert!(forwarded.get("x-request-id").is_none());
        assert!(forwarded.get(header::AUTHORIZATION).is_none());
        assert!(forwarded.get(header::CONNECTION).is_none());
        assert!(forwarded.get("x-client-hop").is_none());
    }

    #[test]
    fn upstream_response_headers_exclude_standard_and_connection_named_hops() {
        let mut response = Response::new(Body::empty());
        response.headers_mut().insert(
            header::CONNECTION,
            HeaderValue::from_static("x-provider-hop"),
        );
        response
            .headers_mut()
            .insert("x-provider-hop", HeaderValue::from_static("remove"));
        response.headers_mut().insert(
            header::CONTENT_TYPE,
            HeaderValue::from_static("application/json"),
        );
        response
            .headers_mut()
            .insert("x-upstream-request-id", HeaderValue::from_static("up-1"));

        let response = filtered_upstream_response(response);

        assert!(response.headers().get(header::CONNECTION).is_none());
        assert!(response.headers().get("x-provider-hop").is_none());
        assert_eq!(response.headers()[header::CONTENT_TYPE], "application/json");
        assert_eq!(response.headers()["x-upstream-request-id"], "up-1");
    }

    struct LoopbackService {
        base_url: String,
        accounted: AtomicUsize,
    }

    #[async_trait]
    impl RelayMiscService for LoopbackService {
        async fn system_performance(&self, _: &Request) -> RelayAuth {
            RelayAuth::Authorized
        }

        async fn authorize(&self, _: &Request) -> RelayAuth {
            RelayAuth::Authorized
        }

        async fn model_rate_limit(&self, _: &Request) -> RelayAuth {
            RelayAuth::Authorized
        }

        async fn distribute(&self, context: &RelayRequestContext, _: &Request) -> RelayAuth {
            if context.path == "/v1/moderations" {
                assert_eq!(context.model.as_deref(), Some("text-moderation-stable"));
            }
            RelayAuth::Authorized
        }

        async fn provider_headers(
            &self,
            context: &RelayRequestContext,
            headers: &HeaderMap,
        ) -> Result<HeaderMap, RelayAuth> {
            let mut headers = headers.clone();
            headers.insert(
                header::AUTHORIZATION,
                HeaderValue::from_static("Bearer provider-owned-secret"),
            );
            if context.protocol == RelayProtocol::AlphaSearch {
                headers.insert("x-fixture-mode", HeaderValue::from_static("sse"));
            } else if context.protocol == RelayProtocol::Rerank {
                headers.insert("x-fixture-mode", HeaderValue::from_static("error"));
            }
            Ok(headers)
        }

        async fn relay(&self, _: RelayProtocol, request: Request) -> Response {
            let context = request
                .extensions()
                .get::<RelayRequestContext>()
                .expect("relay context")
                .clone();
            let (parts, body) = request.into_parts();
            let body = match to_bytes(body, MAX_RELAY_BODY_BYTES).await {
                Ok(body) => body,
                Err(_) => return StatusCode::PAYLOAD_TOO_LARGE.into_response(),
            };
            let client = reqwest::Client::new();
            let mut outbound = client
                .post(format!("{}{}", self.base_url, context.path))
                .body(body);
            for (name, value) in &parts.headers {
                outbound = outbound.header(name, value);
            }
            let upstream = match outbound.send().await {
                Ok(upstream) => upstream,
                Err(_) => return StatusCode::BAD_GATEWAY.into_response(),
            };
            let status = upstream.status();
            let headers = upstream.headers().clone();
            let mut response = Response::new(Body::from_stream(upstream.bytes_stream()));
            *response.status_mut() = status;
            *response.headers_mut() = headers;
            response
        }

        async fn account(&self, _: &RelayRequestContext, _: RelayAccounting) -> RelayAuth {
            self.accounted.fetch_add(1, Ordering::SeqCst);
            RelayAuth::Authorized
        }
    }

    /// Invoked by `relay-misc-differential.sh` against its loopback-only
    /// provider. It is ignored so ordinary unit tests never perform network I/O.
    #[tokio::test]
    #[ignore = "requires the differential runner's loopback provider"]
    async fn loopback_provider_contract() {
        let base_url = std::env::var("LMM_RELAY_MISC_PROVIDER_URL")
            .expect("LMM_RELAY_MISC_PROVIDER_URL is required");
        assert!(base_url.starts_with("http://127.0.0.1:"));
        let service = Arc::new(LoopbackService {
            base_url,
            accounted: AtomicUsize::new(0),
        });
        let app = routes(RelayMiscHttpState::new(service.clone()));
        let cases = [
            (
                "/v1/alpha/search",
                r#"{"model":"gpt-test","query":"hello","stream":true}"#,
                StatusCode::OK,
                Some("text/event-stream"),
            ),
            (
                "/v1/embeddings",
                r#"{"model":"text-embedding-3-small","input":"hello"}"#,
                StatusCode::OK,
                Some("application/json"),
            ),
            (
                "/v1/rerank",
                r#"{"model":"rerank-v3","query":"hello","documents":["hello"]}"#,
                StatusCode::TOO_MANY_REQUESTS,
                Some("application/json"),
            ),
            (
                "/v1/moderations",
                r#"{"input":"hello"}"#,
                StatusCode::OK,
                Some("application/json"),
            ),
        ];
        for (path, body, expected_status, expected_content_type) in cases {
            let response = app
                .clone()
                .oneshot(
                    HttpRequest::post(path)
                        .header(header::AUTHORIZATION, "Bearer caller-secret")
                        .header(header::CONTENT_TYPE, "application/json")
                        .body(Body::from(body))
                        .unwrap(),
                )
                .await
                .unwrap();
            assert_eq!(response.status(), expected_status, "{path}");
            assert_eq!(
                response
                    .headers()
                    .get(header::CONTENT_TYPE)
                    .and_then(|value| value.to_str().ok()),
                expected_content_type,
                "{path}",
            );
            let _body = to_bytes(response.into_body(), MAX_RELAY_BODY_BYTES)
                .await
                .unwrap();
        }
        assert_eq!(service.accounted.load(Ordering::SeqCst), cases.len());
    }
}
