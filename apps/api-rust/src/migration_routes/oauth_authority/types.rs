use std::collections::BTreeSet;

use base64::{Engine as _, engine::general_purpose::URL_SAFE_NO_PAD};
use hmac::{Hmac, Mac};
use rand::RngCore;
use secrecy::{ExposeSecret, SecretString};
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use subtle::ConstantTimeEq;

pub(super) const CLIENT_ID: &str = "lmm-api-rs";
pub(super) const AUTHORIZATION_REQUEST_PURPOSE: &str = "oauth_authorize_request";
pub(super) const AUTHORIZATION_CODE_PURPOSE: &str = "oauth_authorization_code";
pub(super) const AUTHORIZATION_REQUEST_TTL_SECONDS: i64 = 600;
pub(super) const AUTHORIZATION_CODE_TTL_SECONDS: i64 = 180;
pub(super) const DEVICE_CODE_TTL_SECONDS: i64 = 900;
pub(super) const ACCESS_TOKEN_TTL_SECONDS: i64 = 600;
pub(super) const REFRESH_TOKEN_TTL_SECONDS: i64 = 30 * 24 * 60 * 60;
pub(super) const DEVICE_POLL_INTERVAL_SECONDS: i64 = 5;

const ALLOWED_SCOPES: [&str; 4] = [
    "api_keys:list",
    "api_keys:create",
    "api_keys:reveal",
    "cc_switch:import",
];
const DEVICE_ALPHABET: &[u8] = b"ABCDEFGHJKLMNPQRSTUVWXYZ23456789";

type HmacSha256 = Hmac<Sha256>;

#[derive(Clone, Copy, Debug, Eq, PartialEq, thiserror::Error)]
pub(super) enum AuthorityError {
    #[error("invalid_request")]
    InvalidRequest,
    #[error("invalid_client")]
    InvalidClient,
    #[error("invalid_grant")]
    InvalidGrant,
    #[error("invalid_scope")]
    InvalidScope,
    #[error("authorization_pending")]
    AuthorizationPending,
    #[error("slow_down")]
    SlowDown,
    #[error("access_denied")]
    AccessDenied,
    #[error("expired_token")]
    ExpiredToken,
    #[error("unauthorized")]
    Unauthorized,
    #[error("insufficient_scope")]
    InsufficientScope,
    #[error("storage_unavailable")]
    Storage,
}

#[derive(Clone, Debug, Deserialize, Serialize)]
pub(super) struct AuthorizationPayload {
    pub client_id: String,
    pub redirect_uri: String,
    pub scope: String,
    pub state: String,
    pub code_challenge: String,
}

#[derive(Clone, Debug, Deserialize)]
pub(super) struct AuthorizationQuery {
    pub response_type: String,
    pub client_id: String,
    pub redirect_uri: String,
    #[serde(default)]
    pub scope: String,
    #[serde(default)]
    pub state: String,
    pub code_challenge: String,
    pub code_challenge_method: String,
}

#[derive(Clone, Debug, Deserialize)]
pub(super) struct TokenForm {
    pub grant_type: String,
    #[serde(default)]
    pub code: String,
    #[serde(default)]
    pub redirect_uri: String,
    #[serde(default)]
    pub client_id: String,
    #[serde(default)]
    pub code_verifier: String,
    #[serde(default)]
    pub device_code: String,
    #[serde(default)]
    pub refresh_token: String,
}

#[derive(Clone, Debug, Deserialize)]
pub(super) struct DeviceCodeForm {
    pub client_id: String,
    #[serde(default)]
    pub scope: String,
}

#[derive(Clone, Debug, Deserialize)]
pub(super) struct RevokeForm {
    pub token: String,
    #[serde(default)]
    pub client_id: String,
}

#[derive(Clone, Debug, Deserialize)]
pub(super) struct AuthorizationDecisionBody {
    pub approve: bool,
}

#[derive(Clone, Debug, Deserialize)]
pub(super) struct DeviceDecisionBody {
    pub user_code: String,
    pub approve: bool,
}

#[derive(Clone, Debug, Deserialize)]
pub(super) struct CreateKeyBody {
    #[serde(default)]
    pub name: String,
}

#[derive(Clone, Debug, Serialize)]
pub(super) struct AuthorizationPreview {
    pub client_id: String,
    pub client_name: String,
    pub redirect_uri: String,
    pub scopes: Vec<String>,
    pub expires_at: String,
}

#[derive(Clone, Debug, Serialize)]
pub(super) struct AuthorizationDecision {
    pub redirect_uri: String,
}

#[derive(Clone, Debug, Serialize)]
pub(super) struct DeviceDecision {
    pub approved: bool,
}

#[derive(Clone, Debug, Serialize)]
pub(super) struct DeviceAuthorization {
    pub device_code: String,
    pub user_code: String,
    pub verification_uri: String,
    pub verification_uri_complete: String,
    pub expires_in: i64,
    pub interval: i64,
}

#[derive(Clone, Debug, Serialize)]
pub(super) struct TokenResponse {
    pub access_token: String,
    pub token_type: &'static str,
    pub expires_in: i64,
    pub refresh_token: String,
    pub scope: String,
}

#[derive(Clone, Debug, Serialize)]
pub(super) struct Metadata {
    pub issuer: String,
    pub authorization_endpoint: String,
    pub token_endpoint: String,
    pub revocation_endpoint: String,
    pub device_authorization_endpoint: String,
    pub response_types_supported: [&'static str; 1],
    pub grant_types_supported: [&'static str; 3],
    pub code_challenge_methods_supported: [&'static str; 1],
    pub token_endpoint_auth_methods_supported: [&'static str; 1],
    pub scopes_supported: [&'static str; 4],
}

#[derive(Clone, Debug)]
pub(super) struct AccessPrincipal {
    pub user_id: i64,
    scopes: BTreeSet<String>,
}

impl AccessPrincipal {
    pub(super) fn require_scope(&self, scope: &str) -> Result<(), AuthorityError> {
        if self.scopes.contains(scope) {
            Ok(())
        } else {
            Err(AuthorityError::InsufficientScope)
        }
    }

    pub(super) fn from_parts(user_id: i64, scope: &str) -> Self {
        Self {
            user_id,
            scopes: scope.split_whitespace().map(str::to_owned).collect(),
        }
    }
}

pub(super) fn validate_authorization_query(
    input: &AuthorizationQuery,
) -> Result<AuthorizationPayload, AuthorityError> {
    if input.response_type != "code" {
        return Err(AuthorityError::InvalidRequest);
    }
    if input.client_id != CLIENT_ID {
        return Err(AuthorityError::InvalidClient);
    }
    validate_redirect_uri(&input.redirect_uri)?;
    if input.code_challenge_method != "S256"
        || !is_pkce_value(&input.code_challenge)
        || !is_oauth_state(&input.state)
    {
        return Err(AuthorityError::InvalidRequest);
    }
    Ok(AuthorizationPayload {
        client_id: input.client_id.clone(),
        redirect_uri: input.redirect_uri.clone(),
        scope: normalize_scopes(&input.scope)?,
        state: input.state.clone(),
        code_challenge: input.code_challenge.clone(),
    })
}

pub(super) fn normalize_scopes(value: &str) -> Result<String, AuthorityError> {
    let requested: BTreeSet<&str> = value.split_whitespace().collect();
    if requested.is_empty()
        || requested
            .iter()
            .any(|scope| !ALLOWED_SCOPES.contains(scope))
    {
        return Err(AuthorityError::InvalidScope);
    }
    Ok(requested.into_iter().collect::<Vec<_>>().join(" "))
}

pub(super) fn validate_client(client_id: &str) -> Result<(), AuthorityError> {
    if client_id == CLIENT_ID {
        Ok(())
    } else {
        Err(AuthorityError::InvalidClient)
    }
}

pub(super) fn validate_redirect_uri(value: &str) -> Result<(), AuthorityError> {
    if !(value.starts_with("http://127.0.0.1:") || value.starts_with("http://[::1]:")) {
        return Err(AuthorityError::InvalidRequest);
    }
    let parsed = reqwest::Url::parse(value).map_err(|_| AuthorityError::InvalidRequest)?;
    let host = parsed.host_str().ok_or(AuthorityError::InvalidRequest)?;
    let port = parsed.port().ok_or(AuthorityError::InvalidRequest)?;
    if parsed.scheme() != "http"
        || (host != "127.0.0.1" && host != "::1")
        || port < 1024
        || parsed.path() != "/oauth/callback"
        || parsed.query().is_some()
        || parsed.fragment().is_some()
        || !parsed.username().is_empty()
        || parsed.password().is_some()
    {
        return Err(AuthorityError::InvalidRequest);
    }
    Ok(())
}

pub(super) fn canonical_issuer(value: &str) -> Result<String, AuthorityError> {
    let parsed = reqwest::Url::parse(value).map_err(|_| AuthorityError::Storage)?;
    let host = parsed.host_str().ok_or(AuthorityError::Storage)?;
    let local_http = parsed.scheme() == "http" && (host == "127.0.0.1" || host == "::1");
    if (parsed.scheme() != "https" && !local_http)
        || parsed.query().is_some()
        || parsed.fragment().is_some()
        || !parsed.username().is_empty()
        || parsed.password().is_some()
    {
        return Err(AuthorityError::Storage);
    }
    Ok(value.trim_end_matches('/').to_owned())
}

pub(super) fn verify_pkce(verifier: &str, expected: &str) -> bool {
    let actual = URL_SAFE_NO_PAD.encode(Sha256::digest(verifier.as_bytes()));
    actual.as_bytes().ct_eq(expected.as_bytes()).into()
}

pub(super) fn auth_flow_hash(
    session_secret: &SecretString,
    token: &str,
) -> Result<String, AuthorityError> {
    hmac_hex(
        format!("auth-flow-v1:{}", session_secret.expose_secret()).as_bytes(),
        token.as_bytes(),
    )
}

pub(super) fn opaque_hash(
    session_secret: &SecretString,
    kind: &str,
    value: &str,
) -> Result<String, AuthorityError> {
    hmac_hex(
        format!("auth-flow-v1:{}", session_secret.expose_secret()).as_bytes(),
        format!("oauth:{kind}:{value}").as_bytes(),
    )
}

fn hmac_hex(key: &[u8], value: &[u8]) -> Result<String, AuthorityError> {
    let mut mac = HmacSha256::new_from_slice(key).map_err(|_| AuthorityError::Storage)?;
    mac.update(value);
    Ok(hex::encode(mac.finalize().into_bytes()))
}

pub(super) fn random_secret() -> Result<String, AuthorityError> {
    let mut bytes = [0_u8; 32];
    rand::rng().fill_bytes(&mut bytes);
    Ok(URL_SAFE_NO_PAD.encode(bytes))
}

pub(super) fn random_user_code() -> Result<String, AuthorityError> {
    let mut bytes = [0_u8; 8];
    rand::rng().fill_bytes(&mut bytes);
    let raw = bytes
        .iter()
        .map(|value| DEVICE_ALPHABET[usize::from(*value) % DEVICE_ALPHABET.len()] as char)
        .collect::<String>();
    Ok(format!("{}-{}", &raw[..4], &raw[4..]))
}

pub(super) fn normalize_user_code(value: &str) -> String {
    value.trim().replace('-', "").to_uppercase()
}

fn is_oauth_state(value: &str) -> bool {
    (32..=512).contains(&value.len())
        && value
            .bytes()
            .all(|byte| byte.is_ascii_alphanumeric() || matches!(byte, b'-' | b'.' | b'_' | b'~'))
}

fn is_pkce_value(value: &str) -> bool {
    (43..=128).contains(&value.len())
        && value
            .bytes()
            .all(|byte| byte.is_ascii_alphanumeric() || matches!(byte, b'-' | b'_' | b'.' | b'~'))
}

#[cfg(test)]
mod tests {
    use super::{
        AuthorityError, AuthorizationQuery, auth_flow_hash, canonical_issuer, normalize_scopes,
        opaque_hash, validate_authorization_query, validate_redirect_uri, verify_pkce,
    };
    use base64::{Engine as _, engine::general_purpose::URL_SAFE_NO_PAD};
    use secrecy::SecretString;
    use sha2::{Digest, Sha256};

    #[test]
    fn authorization_query_accepts_the_fixed_client_and_exact_loopback_callback() {
        let verifier = "a".repeat(64);
        let challenge = URL_SAFE_NO_PAD.encode(Sha256::digest(verifier.as_bytes()));
        let result = validate_authorization_query(&AuthorizationQuery {
            response_type: "code".to_owned(),
            client_id: "lmm-api-rs".to_owned(),
            redirect_uri: "http://127.0.0.1:49152/oauth/callback".to_owned(),
            scope: "cc_switch:import api_keys:list".to_owned(),
            state: "s".repeat(43),
            code_challenge: challenge.clone(),
            code_challenge_method: "S256".to_owned(),
        });
        assert!(result.is_ok(), "expected valid request, got {result:?}");
        assert!(verify_pkce(&verifier, &challenge));
    }

    #[test]
    fn redirect_uri_rejects_noncanonical_loopback_and_decorated_urls() {
        for value in [
            "https://127.0.0.1:49152/oauth/callback",
            "http://localhost:49152/oauth/callback",
            "http://127.1:49152/oauth/callback",
            "http://127.0.0.1:80/oauth/callback",
            "http://127.0.0.1:49152/oauth/callback?code=leak",
            "http://user@127.0.0.1:49152/oauth/callback",
        ] {
            assert_eq!(
                validate_redirect_uri(value),
                Err(AuthorityError::InvalidRequest)
            );
        }
    }

    #[test]
    fn scopes_are_canonical_and_unknown_values_fail_closed() {
        assert_eq!(
            normalize_scopes("cc_switch:import api_keys:list api_keys:list"),
            Ok("api_keys:list cc_switch:import".to_owned())
        );
        assert_eq!(
            normalize_scopes("api_keys:list admin"),
            Err(AuthorityError::InvalidScope)
        );
    }

    #[test]
    fn hmac_and_pkce_vectors_match_the_go_authority_contract() {
        let secret = SecretString::from("oauth-contract-test-session-secret".to_owned());
        assert_eq!(
            auth_flow_hash(&secret, "authorization-request-token"),
            Ok("bdce4c4b125c53d8d191a6c988bb84fd3ac703fa913fa5797250f8d516271562".to_owned())
        );
        assert_eq!(
            opaque_hash(&secret, "access-token", "access-token-value"),
            Ok("b09a2fff0bc85028977df6ab0370080c18e4f6d7d12d9830bbd31d64c646b1c2".to_owned())
        );
        assert!(verify_pkce(
            "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~",
            "ImpiCd8pp4MveCNnbIS7-GXEtB0xF5HMIDoWqvGA5ig"
        ));
    }

    #[test]
    fn issuer_requires_https_except_for_local_development() {
        assert_eq!(
            canonical_issuer("https://api.example.com/"),
            Ok("https://api.example.com".to_owned())
        );
        assert_eq!(
            canonical_issuer("http://127.0.0.1:3000"),
            Ok("http://127.0.0.1:3000".to_owned())
        );
        assert_eq!(
            canonical_issuer("http://localhost:3000"),
            Err(AuthorityError::Storage)
        );
        assert_eq!(
            canonical_issuer("http://api.example.com"),
            Err(AuthorityError::Storage)
        );
    }
}
