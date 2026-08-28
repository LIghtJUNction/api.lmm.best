use std::{
    collections::HashMap,
    io::{self, IsTerminal, Write as _},
    process::Command,
    time::{Duration, Instant},
};

use base64::{Engine as _, engine::general_purpose::URL_SAFE_NO_PAD};
use rand::TryRngCore;
use reqwest::{Client, StatusCode, Url, redirect::Policy};
use secrecy::{ExposeSecret, SecretString};
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use thiserror::Error;
use tokio::{
    io::{AsyncReadExt, AsyncWriteExt},
    net::{TcpListener, TcpStream},
    time::{sleep, timeout},
};

use super::cc_switch_import::{CcSwitchApp, ImportError, build_provider_uri, open_provider_uri};

const CLIENT_ID: &str = "lmm-api-rs";
const DEFAULT_SCOPE: &str = "api_keys:create api_keys:list api_keys:reveal cc_switch:import";
const CALLBACK_PATH: &str = "/oauth/callback";
const CALLBACK_TIMEOUT: Duration = Duration::from_secs(180);
const MAX_CALLBACK_BYTES: usize = 8192;

#[derive(Clone, Debug)]
pub struct LoginOptions {
    pub issuer: String,
    pub force_device: bool,
    pub no_open: bool,
    pub no_store: bool,
    pub no_import: bool,
    pub api_key_id: Option<i32>,
    pub create_key: Option<String>,
    pub cc_switch_app: CcSwitchApp,
}

#[derive(Debug, Error)]
pub enum OAuthClientError {
    #[error("invalid OAuth issuer or metadata: {0}")]
    InvalidMetadata(String),
    #[error("OAuth HTTP request failed: {0}")]
    Http(String),
    #[error("OAuth server returned HTTP {status}: {code}")]
    Protocol { status: u16, code: String },
    #[error("generate PKCE or OAuth state: {0}")]
    Random(String),
    #[error("start loopback callback server: {0}")]
    Loopback(String),
    #[error("OAuth callback timed out")]
    CallbackTimeout,
    #[error("OAuth callback state did not match")]
    StateMismatch,
    #[error("the user denied OAuth authorization")]
    AccessDenied,
    #[error("open browser: {0}")]
    Browser(String),
    #[error("API key selection requires an interactive terminal or --api-key-id/--create-key")]
    KeySelectionRequired,
    #[error("API key response was invalid")]
    InvalidKeyResponse,
    #[error(transparent)]
    CcSwitch(#[from] ImportError),
    #[error("read API key selection: {0}")]
    SelectionIo(#[from] io::Error),
}

#[derive(Clone, Debug, Deserialize)]
struct AuthorizationServerMetadata {
    issuer: String,
    authorization_endpoint: String,
    token_endpoint: String,
    device_authorization_endpoint: String,
    revocation_endpoint: String,
}

#[derive(Debug, Deserialize)]
struct RawTokenResponse {
    access_token: String,
    token_type: String,
    expires_in: u64,
    refresh_token: Option<String>,
    scope: String,
}

struct TokenResponse {
    access_token: SecretString,
    refresh_token: Option<SecretString>,
    scope: String,
}

#[derive(Debug, Deserialize)]
struct OAuthProtocolError {
    error: String,
}

#[derive(Debug, Deserialize)]
struct DeviceAuthorization {
    device_code: String,
    user_code: String,
    verification_uri: String,
    verification_uri_complete: String,
    expires_in: u64,
    interval: u64,
}

#[derive(Clone, Debug, Deserialize)]
struct ApiKeySummary {
    id: i32,
    name: String,
}

#[derive(Debug, Deserialize)]
struct ApiKeyList {
    keys: Vec<ApiKeySummary>,
}

#[derive(Debug, Deserialize)]
struct RawApiKeySecret {
    key: String,
}

#[derive(Debug, Serialize)]
struct ApiKeyCreate<'a> {
    name: &'a str,
}

struct ApiKeySecret(SecretString);

pub async fn login(options: LoginOptions) -> Result<(), OAuthClientError> {
    if options.api_key_id.is_some() && options.create_key.is_some() {
        return Err(OAuthClientError::InvalidKeyResponse);
    }
    let issuer = normalize_issuer(&options.issuer)?;
    let client = oauth_http_client()?;
    let metadata = discover(&client, &issuer).await?;
    let stored = if !options.no_store && !options.force_device {
        refresh_from_keyring(&client, &metadata).await
    } else {
        None
    };
    let token = if let Some(token) = stored {
        token
    } else if options.force_device {
        device_login(&client, &metadata, options.no_open).await?
    } else {
        match loopback_login(&client, &metadata, options.no_open).await {
            Ok(token) => token,
            Err(error @ (OAuthClientError::AccessDenied | OAuthClientError::StateMismatch)) => {
                return Err(error);
            }
            Err(error) => {
                eprintln!("Loopback OAuth was unavailable ({error}); falling back to Device Flow.");
                device_login(&client, &metadata, options.no_open).await?
            }
        }
    };
    if !token
        .scope
        .split_ascii_whitespace()
        .any(|scope| scope == "api_keys:list")
    {
        return Err(OAuthClientError::Protocol {
            status: 200,
            code: "missing_required_scope".to_owned(),
        });
    }
    if !options.no_store
        && let Some(refresh_token) = token.refresh_token.as_ref()
        && let Err(error) = store_refresh_token(&metadata.issuer, refresh_token)
    {
        eprintln!("warning: OS credential storage is unavailable: {error}");
    }
    if options.no_import {
        println!("OAuth login completed.");
        return Ok(());
    }

    let api_key = obtain_api_key(
        &client,
        &metadata,
        &token.access_token,
        options.api_key_id,
        options.create_key.as_deref(),
    )
    .await?;
    let endpoint = Url::parse(&metadata.issuer)
        .map_err(|error| OAuthClientError::InvalidMetadata(error.to_string()))?;
    let import_uri = build_provider_uri(options.cc_switch_app, &endpoint, api_key.0)?;
    open_provider_uri(&import_uri)?;
    println!("OAuth login completed and the provider was handed to CC Switch.");
    Ok(())
}

fn normalize_issuer(raw: &str) -> Result<Url, OAuthClientError> {
    let mut issuer = Url::parse(raw.trim())
        .map_err(|error| OAuthClientError::InvalidMetadata(error.to_string()))?;
    let local = issuer
        .host_str()
        .and_then(|host| host.parse::<std::net::IpAddr>().ok())
        .is_some_and(|address| address.is_loopback());
    if (issuer.scheme() != "https" && !(issuer.scheme() == "http" && local))
        || issuer.host_str().is_none()
        || issuer.username() != ""
        || issuer.password().is_some()
        || issuer.query().is_some()
        || issuer.fragment().is_some()
    {
        return Err(OAuthClientError::InvalidMetadata(
            "issuer must be HTTPS (or a loopback HTTP test issuer)".to_owned(),
        ));
    }
    let normalized_path = issuer.path().trim_end_matches('/').to_owned();
    if !normalized_path.is_empty() {
        return Err(OAuthClientError::InvalidMetadata(
            "issuer must not contain a path".to_owned(),
        ));
    }
    issuer.set_path("");
    Ok(issuer)
}

fn oauth_http_client() -> Result<Client, OAuthClientError> {
    Client::builder()
        .user_agent(concat!("lmm-api-rs/", env!("CARGO_PKG_VERSION")))
        .connect_timeout(Duration::from_secs(10))
        .timeout(Duration::from_secs(30))
        .redirect(Policy::none())
        .build()
        .map_err(|error| OAuthClientError::Http(error.to_string()))
}

async fn discover(
    client: &Client,
    issuer: &Url,
) -> Result<AuthorizationServerMetadata, OAuthClientError> {
    let discovery_url = issuer
        .join(".well-known/oauth-authorization-server")
        .map_err(|error| OAuthClientError::InvalidMetadata(error.to_string()))?;
    let response = client
        .get(discovery_url)
        .send()
        .await
        .map_err(|error| OAuthClientError::Http(error.to_string()))?;
    if !response.status().is_success() {
        return Err(OAuthClientError::Protocol {
            status: response.status().as_u16(),
            code: "metadata_unavailable".to_owned(),
        });
    }
    let metadata: AuthorizationServerMetadata = response
        .json()
        .await
        .map_err(|error| OAuthClientError::InvalidMetadata(error.to_string()))?;
    let advertised = normalize_issuer(&metadata.issuer)?;
    if advertised != *issuer {
        return Err(OAuthClientError::InvalidMetadata(
            "metadata issuer mismatch".to_owned(),
        ));
    }
    for endpoint in [
        &metadata.authorization_endpoint,
        &metadata.token_endpoint,
        &metadata.device_authorization_endpoint,
        &metadata.revocation_endpoint,
    ] {
        validate_endpoint_origin(issuer, endpoint)?;
    }
    Ok(metadata)
}

fn validate_endpoint_origin(issuer: &Url, endpoint: &str) -> Result<(), OAuthClientError> {
    let endpoint = Url::parse(endpoint)
        .map_err(|error| OAuthClientError::InvalidMetadata(error.to_string()))?;
    if endpoint.scheme() != issuer.scheme()
        || endpoint.host_str() != issuer.host_str()
        || endpoint.port_or_known_default() != issuer.port_or_known_default()
        || endpoint.username() != ""
        || endpoint.password().is_some()
        || endpoint.query().is_some()
        || endpoint.fragment().is_some()
    {
        return Err(OAuthClientError::InvalidMetadata(
            "OAuth endpoint origin mismatch".to_owned(),
        ));
    }
    Ok(())
}

async fn loopback_login(
    client: &Client,
    metadata: &AuthorizationServerMetadata,
    no_open: bool,
) -> Result<TokenResponse, OAuthClientError> {
    let listener = TcpListener::bind((std::net::Ipv4Addr::LOCALHOST, 0))
        .await
        .map_err(|error| OAuthClientError::Loopback(error.to_string()))?;
    let port = listener
        .local_addr()
        .map_err(|error| OAuthClientError::Loopback(error.to_string()))?
        .port();
    let redirect_uri = format!("http://127.0.0.1:{port}{CALLBACK_PATH}");
    let verifier = random_urlsafe(64)?;
    let state = random_urlsafe(32)?;
    let challenge = URL_SAFE_NO_PAD.encode(Sha256::digest(verifier.as_bytes()));
    let mut authorization = Url::parse(&metadata.authorization_endpoint)
        .map_err(|error| OAuthClientError::InvalidMetadata(error.to_string()))?;
    authorization
        .query_pairs_mut()
        .append_pair("client_id", CLIENT_ID)
        .append_pair("redirect_uri", &redirect_uri)
        .append_pair("response_type", "code")
        .append_pair("scope", DEFAULT_SCOPE)
        .append_pair("state", &state)
        .append_pair("code_challenge", &challenge)
        .append_pair("code_challenge_method", "S256");
    open_or_print(&authorization, no_open)?;

    let (code, callback_state) = timeout(CALLBACK_TIMEOUT, receive_callback(listener))
        .await
        .map_err(|_| OAuthClientError::CallbackTimeout)??;
    if callback_state != state {
        return Err(OAuthClientError::StateMismatch);
    }
    exchange_token(
        client,
        &metadata.token_endpoint,
        &[
            ("grant_type", "authorization_code"),
            ("client_id", CLIENT_ID),
            ("code", &code),
            ("redirect_uri", &redirect_uri),
            ("code_verifier", &verifier),
        ],
    )
    .await
}

async fn receive_callback(listener: TcpListener) -> Result<(String, String), OAuthClientError> {
    let (mut socket, _) = listener
        .accept()
        .await
        .map_err(|error| OAuthClientError::Loopback(error.to_string()))?;
    let result = parse_callback_request(&mut socket).await;
    let success = result.is_ok();
    let message = if success {
        "Authorization complete. You may close this window."
    } else {
        "Authorization failed. Return to the terminal for details."
    };
    let body = format!(
        "<!doctype html><html><head><meta charset=\"utf-8\"><title>lmm-api-rs</title></head><body><p>{message}</p></body></html>"
    );
    let response = format!(
        "HTTP/1.1 {}\r\nContent-Type: text/html; charset=utf-8\r\nCache-Control: no-store\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{}",
        if success { "200 OK" } else { "400 Bad Request" },
        body.len(),
        body
    );
    socket
        .write_all(response.as_bytes())
        .await
        .map_err(|error| OAuthClientError::Loopback(error.to_string()))?;
    result
}

async fn parse_callback_request(
    socket: &mut TcpStream,
) -> Result<(String, String), OAuthClientError> {
    let mut request = Vec::with_capacity(1024);
    loop {
        if request.len() >= MAX_CALLBACK_BYTES {
            return Err(OAuthClientError::Loopback(
                "callback request exceeded size limit".to_owned(),
            ));
        }
        let mut chunk = [0_u8; 1024];
        let read = socket
            .read(&mut chunk)
            .await
            .map_err(|error| OAuthClientError::Loopback(error.to_string()))?;
        if read == 0 {
            break;
        }
        request.extend_from_slice(&chunk[..read]);
        if request.windows(4).any(|window| window == b"\r\n\r\n") {
            break;
        }
    }
    let request = std::str::from_utf8(&request)
        .map_err(|error| OAuthClientError::Loopback(error.to_string()))?;
    let request_line = request
        .lines()
        .next()
        .ok_or_else(|| OAuthClientError::Loopback("callback request was empty".to_owned()))?;
    let parts: Vec<_> = request_line.split_ascii_whitespace().collect();
    if parts.len() != 3 || parts[0] != "GET" || parts[2] != "HTTP/1.1" {
        return Err(OAuthClientError::Loopback(
            "callback request line was invalid".to_owned(),
        ));
    }
    let callback = Url::parse(&format!("http://127.0.0.1{}", parts[1]))
        .map_err(|error| OAuthClientError::Loopback(error.to_string()))?;
    if callback.path() != CALLBACK_PATH || callback.fragment().is_some() {
        return Err(OAuthClientError::Loopback(
            "callback path was invalid".to_owned(),
        ));
    }
    let parameters: HashMap<_, _> = callback.query_pairs().into_owned().collect();
    if parameters
        .get("error")
        .is_some_and(|error| error == "access_denied")
    {
        return Err(OAuthClientError::AccessDenied);
    }
    let code = parameters
        .get("code")
        .filter(|value| !value.is_empty())
        .cloned()
        .ok_or_else(|| OAuthClientError::Loopback("callback code was missing".to_owned()))?;
    let state = parameters
        .get("state")
        .filter(|value| !value.is_empty())
        .cloned()
        .ok_or_else(|| OAuthClientError::Loopback("callback state was missing".to_owned()))?;
    Ok((code, state))
}

async fn device_login(
    client: &Client,
    metadata: &AuthorizationServerMetadata,
    no_open: bool,
) -> Result<TokenResponse, OAuthClientError> {
    let endpoint = Url::parse(&metadata.device_authorization_endpoint)
        .map_err(|error| OAuthClientError::InvalidMetadata(error.to_string()))?;
    let response = client
        .post(endpoint)
        .header(
            reqwest::header::CONTENT_TYPE,
            "application/x-www-form-urlencoded",
        )
        .form(&[("client_id", CLIENT_ID), ("scope", DEFAULT_SCOPE)])
        .send()
        .await
        .map_err(|error| OAuthClientError::Http(error.to_string()))?;
    let device: DeviceAuthorization = decode_success(response).await?;
    let issuer = normalize_issuer(&metadata.issuer)?;
    validate_endpoint_origin(&issuer, &device.verification_uri)?;
    let verification = Url::parse(&device.verification_uri_complete)
        .map_err(|error| OAuthClientError::InvalidMetadata(error.to_string()))?;
    if verification.scheme() != issuer.scheme()
        || verification.host_str() != issuer.host_str()
        || verification.port_or_known_default() != issuer.port_or_known_default()
    {
        return Err(OAuthClientError::InvalidMetadata(
            "device verification origin mismatch".to_owned(),
        ));
    }
    println!(
        "Open {} and enter code {}",
        device.verification_uri, device.user_code
    );
    if !no_open && let Err(error) = open_browser(&verification) {
        eprintln!("warning: could not open a browser: {error}");
    }

    let deadline = Instant::now() + Duration::from_secs(device.expires_in);
    let mut interval = Duration::from_secs(device.interval.max(1));
    while Instant::now() < deadline {
        sleep(interval).await;
        match exchange_token(
            client,
            &metadata.token_endpoint,
            &[
                ("grant_type", "urn:ietf:params:oauth:grant-type:device_code"),
                ("client_id", CLIENT_ID),
                ("device_code", &device.device_code),
            ],
        )
        .await
        {
            Ok(token) => return Ok(token),
            Err(OAuthClientError::Protocol { code, .. }) if code == "authorization_pending" => {}
            Err(OAuthClientError::Protocol { code, .. }) if code == "slow_down" => {
                interval += Duration::from_secs(5);
            }
            Err(error) => return Err(error),
        }
    }
    Err(OAuthClientError::CallbackTimeout)
}

async fn exchange_token(
    client: &Client,
    endpoint: &str,
    form: &[(&str, &str)],
) -> Result<TokenResponse, OAuthClientError> {
    let endpoint = Url::parse(endpoint)
        .map_err(|error| OAuthClientError::InvalidMetadata(error.to_string()))?;
    let response = client
        .post(endpoint)
        .header(
            reqwest::header::CONTENT_TYPE,
            "application/x-www-form-urlencoded",
        )
        .form(form)
        .send()
        .await
        .map_err(|error| OAuthClientError::Http(error.to_string()))?;
    let status = response.status();
    if !status.is_success() {
        return Err(protocol_error(response, status).await);
    }
    let raw: RawTokenResponse = response
        .json()
        .await
        .map_err(|error| OAuthClientError::Http(error.to_string()))?;
    if !raw.token_type.eq_ignore_ascii_case("bearer")
        || raw.expires_in == 0
        || raw.access_token.is_empty()
    {
        return Err(OAuthClientError::Protocol {
            status: status.as_u16(),
            code: "invalid_token_response".to_owned(),
        });
    }
    Ok(TokenResponse {
        access_token: SecretString::from(raw.access_token),
        refresh_token: raw.refresh_token.map(SecretString::from),
        scope: raw.scope,
    })
}

async fn protocol_error(response: reqwest::Response, status: StatusCode) -> OAuthClientError {
    let code = response
        .json::<OAuthProtocolError>()
        .await
        .map(|error| error.error)
        .unwrap_or_else(|_| "invalid_response".to_owned());
    OAuthClientError::Protocol {
        status: status.as_u16(),
        code,
    }
}

async fn decode_success<T: for<'de> Deserialize<'de>>(
    response: reqwest::Response,
) -> Result<T, OAuthClientError> {
    let status = response.status();
    if !status.is_success() {
        return Err(protocol_error(response, status).await);
    }
    response
        .json()
        .await
        .map_err(|error| OAuthClientError::Http(error.to_string()))
}

async fn obtain_api_key(
    client: &Client,
    metadata: &AuthorizationServerMetadata,
    access_token: &SecretString,
    requested_id: Option<i32>,
    create_name: Option<&str>,
) -> Result<ApiKeySecret, OAuthClientError> {
    if let Some(name) = create_name {
        return create_api_key(client, metadata, access_token, name).await;
    }
    if let Some(id) = requested_id {
        return reveal_api_key(client, metadata, access_token, id).await;
    }
    let keys = list_api_keys(client, metadata, access_token).await?;
    if keys.is_empty() {
        return create_api_key(client, metadata, access_token, "lmm-api-rs").await;
    }
    let selected = if keys.len() == 1 {
        keys[0].id
    } else {
        select_api_key(&keys)?
    };
    reveal_api_key(client, metadata, access_token, selected).await
}

async fn list_api_keys(
    client: &Client,
    metadata: &AuthorizationServerMetadata,
    access_token: &SecretString,
) -> Result<Vec<ApiKeySummary>, OAuthClientError> {
    let endpoint = resource_endpoint(metadata, "/api/oauth/bootstrap/keys")?;
    let response = client
        .get(endpoint)
        .bearer_auth(access_token.expose_secret())
        .send()
        .await
        .map_err(|error| OAuthClientError::Http(error.to_string()))?;
    let list: ApiKeyList = decode_success(response).await?;
    Ok(list.keys)
}

async fn create_api_key(
    client: &Client,
    metadata: &AuthorizationServerMetadata,
    access_token: &SecretString,
    name: &str,
) -> Result<ApiKeySecret, OAuthClientError> {
    let endpoint = resource_endpoint(metadata, "/api/oauth/bootstrap/keys")?;
    let response = client
        .post(endpoint)
        .bearer_auth(access_token.expose_secret())
        .json(&ApiKeyCreate { name })
        .send()
        .await
        .map_err(|error| OAuthClientError::Http(error.to_string()))?;
    decode_api_key(response).await
}

async fn reveal_api_key(
    client: &Client,
    metadata: &AuthorizationServerMetadata,
    access_token: &SecretString,
    id: i32,
) -> Result<ApiKeySecret, OAuthClientError> {
    if id <= 0 {
        return Err(OAuthClientError::InvalidKeyResponse);
    }
    let endpoint = resource_endpoint(metadata, &format!("/api/oauth/bootstrap/keys/{id}/reveal"))?;
    let response = client
        .post(endpoint)
        .bearer_auth(access_token.expose_secret())
        .send()
        .await
        .map_err(|error| OAuthClientError::Http(error.to_string()))?;
    decode_api_key(response).await
}

async fn decode_api_key(response: reqwest::Response) -> Result<ApiKeySecret, OAuthClientError> {
    let raw: RawApiKeySecret = decode_success(response).await?;
    if raw.key.len() < 16 {
        return Err(OAuthClientError::InvalidKeyResponse);
    }
    Ok(ApiKeySecret(SecretString::from(raw.key)))
}

fn resource_endpoint(
    metadata: &AuthorizationServerMetadata,
    path: &str,
) -> Result<Url, OAuthClientError> {
    let issuer = Url::parse(&metadata.issuer)
        .map_err(|error| OAuthClientError::InvalidMetadata(error.to_string()))?;
    issuer
        .join(path)
        .map_err(|error| OAuthClientError::InvalidMetadata(error.to_string()))
}

fn select_api_key(keys: &[ApiKeySummary]) -> Result<i32, OAuthClientError> {
    if !io::stdin().is_terminal() {
        return Err(OAuthClientError::KeySelectionRequired);
    }
    println!("Available api.lmm.best API keys:");
    for (index, key) in keys.iter().enumerate() {
        println!("  {}. {} (id {})", index + 1, key.name, key.id);
    }
    print!("Select a key [1-{}]: ", keys.len());
    io::stdout().flush()?;
    let mut selection = String::new();
    io::stdin().read_line(&mut selection)?;
    let index: usize = selection
        .trim()
        .parse()
        .map_err(|_| OAuthClientError::KeySelectionRequired)?;
    keys.get(index.saturating_sub(1))
        .map(|key| key.id)
        .ok_or(OAuthClientError::KeySelectionRequired)
}

fn random_urlsafe(size: usize) -> Result<String, OAuthClientError> {
    let mut bytes = vec![0_u8; size];
    rand::rngs::OsRng
        .try_fill_bytes(&mut bytes)
        .map_err(|error| OAuthClientError::Random(error.to_string()))?;
    Ok(URL_SAFE_NO_PAD.encode(bytes))
}

fn open_or_print(url: &Url, no_open: bool) -> Result<(), OAuthClientError> {
    if no_open {
        println!("Open this authorization URL in a browser:\n{url}");
        Ok(())
    } else {
        open_browser(url)
    }
}

fn open_browser(url: &Url) -> Result<(), OAuthClientError> {
    let status = match std::env::consts::OS {
        "linux" => Command::new("xdg-open").arg(url.as_str()).status(),
        "macos" => Command::new("open").arg(url.as_str()).status(),
        "windows" => Command::new("rundll32.exe")
            .arg("url.dll,FileProtocolHandler")
            .arg(url.as_str())
            .status(),
        platform => {
            return Err(OAuthClientError::Browser(format!(
                "unsupported platform {platform}"
            )));
        }
    }
    .map_err(|error| OAuthClientError::Browser(error.to_string()))?;
    if status.success() {
        Ok(())
    } else {
        Err(OAuthClientError::Browser(status.to_string()))
    }
}

async fn refresh_from_keyring(
    client: &Client,
    metadata: &AuthorizationServerMetadata,
) -> Option<TokenResponse> {
    let account = URL_SAFE_NO_PAD.encode(Sha256::digest(metadata.issuer.as_bytes()));
    let entry = keyring::Entry::new("best.lmm.api.lmm-api-rs", &account).ok()?;
    let refresh_token = match entry.get_password() {
        Ok(token) => SecretString::from(token),
        Err(keyring::Error::NoEntry) => return None,
        Err(error) => {
            eprintln!("warning: OS credential storage is unavailable: {error}");
            return None;
        }
    };
    match exchange_token(
        client,
        &metadata.token_endpoint,
        &[
            ("grant_type", "refresh_token"),
            ("client_id", CLIENT_ID),
            ("refresh_token", refresh_token.expose_secret()),
        ],
    )
    .await
    {
        Ok(token) => Some(token),
        Err(_) => {
            if let Err(error) = entry.delete_credential()
                && !matches!(error, keyring::Error::NoEntry)
            {
                eprintln!("warning: failed to remove rejected refresh token: {error}");
            }
            None
        }
    }
}

fn store_refresh_token(issuer: &str, refresh_token: &SecretString) -> Result<(), keyring::Error> {
    let account = URL_SAFE_NO_PAD.encode(Sha256::digest(issuer.as_bytes()));
    let entry = keyring::Entry::new("best.lmm.api.lmm-api-rs", &account)?;
    entry.set_password(refresh_token.expose_secret())
}

#[cfg(test)]
mod tests {
    use std::collections::HashMap;

    use super::{
        AuthorizationServerMetadata, CALLBACK_PATH, OAuthClientError, normalize_issuer,
        resource_endpoint, validate_endpoint_origin,
    };

    #[test]
    fn issuer_and_endpoint_origins_are_pinned() -> Result<(), Box<dyn std::error::Error>> {
        let issuer = normalize_issuer("https://api.lmm.best/")?;
        validate_endpoint_origin(&issuer, "https://api.lmm.best/oauth/token")?;
        assert!(validate_endpoint_origin(&issuer, "https://evil.example/oauth/token").is_err());
        assert!(normalize_issuer("http://api.lmm.best").is_err());
        assert!(normalize_issuer("http://127.0.0.1:3000").is_ok());
        Ok(())
    }

    #[test]
    fn resource_endpoint_remains_on_the_metadata_issuer() -> Result<(), Box<dyn std::error::Error>>
    {
        let metadata = AuthorizationServerMetadata {
            issuer: "https://api.lmm.best".to_owned(),
            authorization_endpoint: "https://api.lmm.best/oauth/authorize".to_owned(),
            token_endpoint: "https://api.lmm.best/oauth/token".to_owned(),
            device_authorization_endpoint: "https://api.lmm.best/oauth/device/code".to_owned(),
            revocation_endpoint: "https://api.lmm.best/oauth/revoke".to_owned(),
        };
        let endpoint = resource_endpoint(&metadata, "/api/oauth/bootstrap/keys")?;
        assert_eq!(
            endpoint.as_str(),
            "https://api.lmm.best/api/oauth/bootstrap/keys"
        );
        Ok(())
    }

    #[test]
    fn callback_contract_requires_code_state_and_exact_path() -> Result<(), OAuthClientError> {
        let callback = reqwest::Url::parse(&format!(
            "http://127.0.0.1:4000{CALLBACK_PATH}?code=test-code&state=test-state"
        ))
        .map_err(|error| OAuthClientError::Loopback(error.to_string()))?;
        let parameters: HashMap<_, _> = callback.query_pairs().into_owned().collect();
        assert_eq!(callback.path(), CALLBACK_PATH);
        assert_eq!(
            parameters.get("code").map(String::as_str),
            Some("test-code")
        );
        assert_eq!(
            parameters.get("state").map(String::as_str),
            Some("test-state")
        );
        Ok(())
    }
}
