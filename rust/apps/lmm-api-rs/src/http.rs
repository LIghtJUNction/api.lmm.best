use std::sync::{
    Arc,
    atomic::{AtomicUsize, Ordering},
};

use axum::{
    Json, Router,
    extract::{Request, State},
    http::{HeaderName, HeaderValue, StatusCode, header},
    middleware::{self, Next},
    response::{IntoResponse, Response},
    routing::get,
};
use lmm_application::{PublicContentService, ReadinessProbe, check_readiness};
use lmm_contracts::{
    BuildResponse, ErrorBody, ErrorEnvelope, HealthResponse, LegacySuccessEnvelope,
};
use lmm_domain::PublicContentKind;
use uuid::Uuid;

const REQUEST_ID_HEADER: HeaderName = HeaderName::from_static("x-request-id");

#[derive(Clone)]
pub struct AppState {
    pub readiness: Arc<dyn ReadinessProbe>,
    pub public_content: Arc<PublicContentService>,
    pub slot: String,
}

#[derive(Clone, Default)]
struct Inflight(Arc<AtomicUsize>);

struct InflightGuard(Inflight);

impl Drop for InflightGuard {
    fn drop(&mut self) {
        self.0.0.fetch_sub(1, Ordering::AcqRel);
    }
}

#[derive(Clone)]
struct ServerRequestId(String);

pub fn router(state: AppState) -> Router {
    let inflight = Inflight::default();
    let router = Router::new()
        .route("/livez", get(livez))
        .route("/readyz", get(readyz))
        .route("/_internal/build", get(build))
        .route("/api/notice", get(notice))
        .route("/api/about", get(about))
        .route("/api/home_page_content", get(home_page_content))
        .fallback(not_found)
        .method_not_allowed_fallback(method_not_allowed);
    #[cfg(test)]
    let router = router.route("/_test/json", axum::routing::post(test_json_extractor));
    router
        .with_state(state)
        .layer(middleware::from_fn_with_state(inflight, request_boundary))
}

#[cfg(test)]
async fn test_json_extractor(Json(_value): Json<serde_json::Value>) -> StatusCode {
    StatusCode::NO_CONTENT
}

async fn request_boundary(
    State(inflight): State<Inflight>,
    mut request: Request,
    next: Next,
) -> Response {
    inflight.0.fetch_add(1, Ordering::AcqRel);
    let _guard = InflightGuard(inflight);
    request.headers_mut().remove(&REQUEST_ID_HEADER);
    let request_id = Uuid::new_v4().to_string();
    request
        .extensions_mut()
        .insert(ServerRequestId(request_id.clone()));
    let mut response = next.run(request).await;
    if response.status().is_client_error() || response.status().is_server_error() {
        let is_json = response
            .headers()
            .get(header::CONTENT_TYPE)
            .and_then(|value| value.to_str().ok())
            .is_some_and(|value| value.starts_with("application/json"));
        if !is_json {
            response = error_response(
                response.status(),
                status_code(response.status()),
                "request rejected",
                &request_id,
            );
        }
    }
    if let Ok(value) = HeaderValue::from_str(&request_id) {
        response.headers_mut().insert(REQUEST_ID_HEADER, value);
    }
    response
}

async fn livez() -> Json<HealthResponse> {
    Json(HealthResponse { status: "ok" })
}

async fn readyz(State(state): State<AppState>, request: Request) -> Response {
    let report = check_readiness(state.readiness.as_ref()).await;
    for failure in &report.required_failures {
        tracing::warn!(
            dependency = failure.dependency,
            "required readiness check failed"
        );
    }
    for failure in &report.degraded {
        tracing::warn!(
            dependency = failure.dependency,
            "optional dependency is degraded"
        );
    }
    if !report.required_failures.is_empty() {
        error_from_request(
            StatusCode::SERVICE_UNAVAILABLE,
            "not_ready",
            "required service dependencies are unavailable",
            &request,
        )
    } else if report.degraded.is_empty() {
        Json(HealthResponse { status: "ok" }).into_response()
    } else {
        Json(HealthResponse { status: "degraded" }).into_response()
    }
}

async fn build(State(state): State<AppState>) -> Json<BuildResponse> {
    Json(BuildResponse {
        version: env!("CARGO_PKG_VERSION"),
        revision: option_env!("LMM_BUILD_REVISION").unwrap_or("unknown"),
        slot: state.slot,
    })
}

async fn notice(State(state): State<AppState>, request: Request) -> Response {
    public_content(state, request, PublicContentKind::Notice).await
}

async fn about(State(state): State<AppState>, request: Request) -> Response {
    public_content(state, request, PublicContentKind::About).await
}

async fn home_page_content(State(state): State<AppState>, request: Request) -> Response {
    public_content(state, request, PublicContentKind::HomePage).await
}

async fn public_content(state: AppState, request: Request, kind: PublicContentKind) -> Response {
    match state.public_content.read(kind).await {
        Ok(data) => Json(LegacySuccessEnvelope {
            success: true,
            message: "",
            data,
        })
        .into_response(),
        Err(error) => {
            tracing::error!(%error, "authoritative public content read failed");
            error_from_request(
                StatusCode::INTERNAL_SERVER_ERROR,
                "content_unavailable",
                "public content is temporarily unavailable",
                &request,
            )
        }
    }
}

async fn not_found(request: Request) -> Response {
    error_from_request(
        StatusCode::NOT_FOUND,
        "not_found",
        "route not found",
        &request,
    )
}

async fn method_not_allowed(request: Request) -> Response {
    error_from_request(
        StatusCode::METHOD_NOT_ALLOWED,
        "method_not_allowed",
        "method not allowed",
        &request,
    )
}

fn error_from_request(
    status: StatusCode,
    code: &'static str,
    message: &str,
    request: &Request,
) -> Response {
    let request_id = request
        .extensions()
        .get::<ServerRequestId>()
        .map_or("unknown", |value| value.0.as_str());
    error_response(status, code, message, request_id)
}

fn error_response(
    status: StatusCode,
    code: &'static str,
    message: &str,
    request_id: &str,
) -> Response {
    (
        status,
        Json(ErrorEnvelope {
            error: ErrorBody {
                code,
                message: message.to_owned(),
            },
            request_id: request_id.to_owned(),
        }),
    )
        .into_response()
}

fn status_code(status: StatusCode) -> &'static str {
    match status {
        StatusCode::BAD_REQUEST | StatusCode::UNPROCESSABLE_ENTITY => "invalid_request",
        StatusCode::METHOD_NOT_ALLOWED => "method_not_allowed",
        StatusCode::NOT_FOUND => "not_found",
        StatusCode::SERVICE_UNAVAILABLE => "not_ready",
        _ if status.is_server_error() => "internal_error",
        _ => "request_rejected",
    }
}

#[cfg(test)]
mod tests {
    use super::{AppState, router};
    use async_trait::async_trait;
    use axum::{
        body::Body,
        http::{Request, StatusCode},
    };
    use lmm_application::{
        ProbeError, PublicContentCache, PublicContentCacheError, PublicContentError,
        PublicContentRepository, PublicContentService, ReadinessProbe,
    };
    use lmm_domain::PublicContentKind;
    use serde_json::Value;
    use std::sync::Arc;
    use tower::ServiceExt;

    struct MockProbe(Option<&'static str>);

    struct MockContentRepository(Option<String>);

    struct MissingCache;

    #[async_trait]
    impl PublicContentCache for MissingCache {
        async fn get(
            &self,
            _kind: PublicContentKind,
        ) -> Result<Option<String>, PublicContentCacheError> {
            Ok(None)
        }

        async fn put(
            &self,
            _kind: PublicContentKind,
            _value: &str,
        ) -> Result<(), PublicContentCacheError> {
            Ok(())
        }
    }

    #[async_trait]
    impl PublicContentRepository for MockContentRepository {
        async fn get(
            &self,
            _kind: PublicContentKind,
        ) -> Result<Option<String>, PublicContentError> {
            Ok(self.0.clone())
        }
    }

    fn state(failing: Option<&'static str>) -> AppState {
        AppState {
            readiness: Arc::new(MockProbe(failing)),
            public_content: Arc::new(PublicContentService::new(
                Arc::new(MockContentRepository(Some("configured content".to_owned()))),
                Arc::new(MissingCache),
            )),
            slot: "blue".to_owned(),
        }
    }

    #[async_trait]
    impl ReadinessProbe for MockProbe {
        async fn postgres(&self) -> Result<(), ProbeError> {
            self.result("postgres")
        }
        async fn valkey(&self) -> Result<(), ProbeError> {
            self.result("valkey")
        }
        async fn schema_compatible(&self) -> Result<(), ProbeError> {
            self.result("schema")
        }
    }

    impl MockProbe {
        fn result(&self, dependency: &'static str) -> Result<(), ProbeError> {
            if self.0 == Some(dependency) {
                Err(ProbeError { dependency })
            } else {
                Ok(())
            }
        }
    }

    async fn call(
        method: &str,
        uri: &str,
        client_id: Option<&str>,
        failing: Option<&'static str>,
    ) -> (StatusCode, String, Value) {
        let mut builder = Request::builder().method(method).uri(uri);
        if let Some(value) = client_id {
            builder = builder.header("x-request-id", value);
        }
        let request = builder.body(Body::empty()).expect("test request is valid");
        let response = router(state(failing))
            .oneshot(request)
            .await
            .expect("router is infallible");
        let status = response.status();
        let id = response
            .headers()
            .get("x-request-id")
            .expect("server id exists")
            .to_str()
            .expect("server id is ASCII")
            .to_owned();
        let bytes = axum::body::to_bytes(response.into_body(), usize::MAX)
            .await
            .expect("test body is readable");
        let body = serde_json::from_slice(&bytes).expect("response is JSON");
        (status, id, body)
    }

    #[tokio::test]
    async fn boundary_should_replace_untrusted_request_id_and_echo_server_id() {
        let (_, id, body) = call("GET", "/missing", Some("attacker-controlled"), None).await;
        assert_ne!(id, "attacker-controlled");
        assert_eq!(body["request_id"], id);
    }

    #[tokio::test]
    async fn errors_should_share_the_json_envelope() {
        for (method, uri, failing, expected) in [
            ("GET", "/missing", None, 404),
            ("POST", "/livez", None, 405),
            ("GET", "/readyz", Some("postgres"), 503),
        ] {
            let (status, id, body) = call(method, uri, None, failing).await;
            assert_eq!(status.as_u16(), expected);
            assert_eq!(body["request_id"], id);
            assert!(body["error"]["code"].is_string());
        }
    }

    #[tokio::test]
    async fn extractor_rejection_should_use_the_json_envelope() {
        let request = Request::builder()
            .method("POST")
            .uri("/_test/json")
            .header("content-type", "application/json")
            .body(Body::from("{"))
            .expect("test request is valid");
        let response = router(state(None))
            .oneshot(request)
            .await
            .expect("router is infallible");
        assert_eq!(response.status(), StatusCode::BAD_REQUEST);
        assert_eq!(response.headers()["content-type"], "application/json");
    }

    #[tokio::test]
    async fn build_should_report_runtime_slot_identity() {
        let (_, _, body) = call("GET", "/_internal/build", None, None).await;
        assert_eq!(body["slot"], "blue");
    }

    #[tokio::test]
    async fn valkey_failure_should_degrade_without_rejecting_traffic() {
        let (status, _, body) = call("GET", "/readyz", None, Some("valkey")).await;
        assert_eq!(status, StatusCode::OK);
        assert_eq!(body["status"], "degraded");
    }

    #[tokio::test]
    async fn public_content_should_match_the_go_success_envelope() {
        for uri in ["/api/notice", "/api/about", "/api/home_page_content"] {
            let (status, _, body) = call("GET", uri, None, None).await;
            assert_eq!(status, StatusCode::OK);
            assert_eq!(body["success"], true);
            assert_eq!(body["message"], "");
            assert_eq!(body["data"], "configured content");
        }
    }
}
