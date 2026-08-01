#![deny(missing_docs)]
//! Stable HTTP contracts shared across the migration boundary.
use serde::Serialize;

/// Standard error envelope returned by the Rust HTTP edge.
#[derive(Debug, Serialize)]
pub struct ErrorEnvelope {
    /// Machine-readable error details.
    pub error: ErrorBody,
    /// Request correlation identifier.
    pub request_id: String,
}
/// Machine-readable error body.
#[derive(Debug, Serialize)]
pub struct ErrorBody {
    /// Stable error code.
    pub code: &'static str,
    /// Safe client-facing message.
    pub message: String,
}
/// Health endpoint response.
#[derive(Debug, Serialize)]
pub struct HealthResponse {
    /// Overall state (`ok` or `unavailable`).
    pub status: &'static str,
}
/// Build metadata safe to expose on the internal listener.
#[derive(Debug, Serialize)]
pub struct BuildResponse {
    /// Package version.
    pub version: &'static str,
    /// Source revision injected by the native package build.
    pub revision: &'static str,
    /// Runtime blue/green slot identity.
    pub slot: String,
}
