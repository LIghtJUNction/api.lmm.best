use std::sync::{Arc, Mutex};

use async_trait::async_trait;
use axum::{
    body::{Body, to_bytes},
    http::{HeaderMap, HeaderValue, Request, StatusCode, header},
};
use lmm_api_rs::migration_routes::{
    media_midjourney::{
        BufferedJsonReply, ImageReply, MidjourneyBackend, MidjourneyFailure, MidjourneyIdentity,
        StoredImage, SubmitReply, TaskEffect, midjourney_image_signature,
    },
    media_tasks::{MediaTaskOperation, MediaTaskService, MidjourneyMediaTaskService},
};
use serde_json::{Value, json};

#[derive(Default)]
struct MockBackend {
    submitted: Mutex<Vec<(String, String, Value)>>,
    reads: Mutex<Vec<(String, String)>>,
    recorded: Mutex<usize>,
}

#[async_trait]
impl MidjourneyBackend for MockBackend {
    async fn authenticate(
        &self,
        _headers: &HeaderMap,
        _client_ip: Option<std::net::IpAddr>,
    ) -> Result<MidjourneyIdentity, MidjourneyFailure> {
        Ok(MidjourneyIdentity {
            user_id: 7,
            token_id: "9".to_owned(),
        })
    }

    async fn submit(
        &self,
        _identity: &MidjourneyIdentity,
        mode: &str,
        operation: &str,
        _headers: &HeaderMap,
        body: Value,
    ) -> Result<SubmitReply, MidjourneyFailure> {
        self.submitted.lock().expect("submission lock").push((
            mode.to_owned(),
            operation.to_owned(),
            body,
        ));
        Ok(SubmitReply {
            response: BufferedJsonReply {
                status: StatusCode::OK,
                content_type: HeaderValue::from_static("application/json"),
                body: json!({"code":21,"description":"replayed","result":"task-1"}),
            },
            effect: TaskEffect {
                mode: "mj".to_owned(),
                operation: operation.to_owned(),
                task_id: "task-1".to_owned(),
                action: "IMAGINE".to_owned(),
                prompt: "paint a fox".to_owned(),
                state: String::new(),
                code: 21,
                description: "replayed".to_owned(),
                properties: Value::Null,
                channel_id: 3,
                quota: 10,
            },
        })
    }

    async fn record_submit(
        &self,
        _identity: &MidjourneyIdentity,
        _effect: TaskEffect,
    ) -> Result<(), MidjourneyFailure> {
        *self.recorded.lock().expect("record lock") += 1;
        Ok(())
    }

    async fn task_read(
        &self,
        _identity: &MidjourneyIdentity,
        operation: &str,
        task_id: &str,
        _headers: &HeaderMap,
        _body: Option<Value>,
    ) -> Result<BufferedJsonReply, MidjourneyFailure> {
        self.reads
            .lock()
            .expect("read lock")
            .push((operation.to_owned(), task_id.to_owned()));
        Ok(BufferedJsonReply {
            status: StatusCode::OK,
            content_type: HeaderValue::from_static("application/json"),
            body: json!({"id":task_id}),
        })
    }

    async fn image_for(&self, _: i64, _task_id: &str) -> Result<StoredImage, MidjourneyFailure> {
        Ok(StoredImage {
            url: "https://provider.example/task-1.png".to_owned(),
        })
    }

    async fn fetch_image(&self, _url: &str) -> Result<ImageReply, MidjourneyFailure> {
        Ok(ImageReply::Stream {
            content_type: HeaderValue::from_static("image/png"),
            body: Body::from(b"png".to_vec()),
        })
    }
}

fn request(path: &str, body: Body) -> Request<Body> {
    Request::builder()
        .uri(path)
        .header(header::AUTHORIZATION, "Bearer token")
        .body(body)
        .expect("request")
}

#[tokio::test]
async fn concrete_static_mj_submit_reuses_backend_accounting_and_normalizes_replay() {
    let backend = Arc::new(MockBackend::default());
    let service = MidjourneyMediaTaskService::new(Arc::clone(&backend));
    let response = service
        .protected(
            MediaTaskOperation::Submit("IMAGINE"),
            request(
                "/mj/submit/imagine",
                Body::from(r#"{"prompt":"paint a fox"}"#),
            ),
        )
        .await;

    assert_eq!(response.status(), StatusCode::OK);
    let body: Value = serde_json::from_slice(
        &to_bytes(response.into_body(), usize::MAX)
            .await
            .expect("body"),
    )
    .expect("JSON response");
    assert_eq!(body["code"], 1);
    assert_eq!(*backend.recorded.lock().expect("record lock"), 1);
    assert_eq!(
        backend
            .submitted
            .lock()
            .expect("submission lock")
            .as_slice(),
        [(
            "mj".to_owned(),
            "imagine".to_owned(),
            json!({"prompt":"paint a fox"})
        )]
    );
}

#[tokio::test]
async fn concrete_static_mj_read_scopes_the_task_id_before_backend_dispatch() {
    let backend = Arc::new(MockBackend::default());
    let service = MidjourneyMediaTaskService::new(Arc::clone(&backend));
    let response = service
        .protected(
            MediaTaskOperation::Fetch,
            request("/mj/task/owned-task/fetch", Body::empty()),
        )
        .await;

    assert_eq!(response.status(), StatusCode::OK);
    assert_eq!(
        backend.reads.lock().expect("read lock").as_slice(),
        [("fetch".to_owned(), "owned-task".to_owned())]
    );
}

#[tokio::test]
async fn concrete_static_mj_public_image_preserves_stream_without_task_writes() {
    let backend = Arc::new(MockBackend::default());
    let secret = b"test-midjourney-image-session-secret-2026";
    let service =
        MidjourneyMediaTaskService::new(Arc::clone(&backend)).with_image_signing_secret(secret);
    let signature = midjourney_image_signature(secret, 7, "task-1").expect("signature");
    let response = service
        .public_image(
            "task-1".to_owned(),
            request(
                &format!("/mj/image/task-1?uid=7&sig={signature}"),
                Body::empty(),
            ),
        )
        .await;

    assert_eq!(response.status(), StatusCode::OK);
    assert_eq!(response.headers()[header::CONTENT_TYPE], "image/png");
    assert_eq!(
        to_bytes(response.into_body(), usize::MAX)
            .await
            .expect("image"),
        b"png".as_slice()
    );
    assert_eq!(*backend.recorded.lock().expect("record lock"), 0);
}
