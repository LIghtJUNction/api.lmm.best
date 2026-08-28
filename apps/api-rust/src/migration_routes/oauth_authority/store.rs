use chrono::{DateTime, Duration, Utc};
use secrecy::SecretString;
use sqlx::{FromRow, PgPool, Postgres, Transaction};

use super::types::{
    ACCESS_TOKEN_TTL_SECONDS, AUTHORIZATION_CODE_PURPOSE, AUTHORIZATION_CODE_TTL_SECONDS,
    AUTHORIZATION_REQUEST_PURPOSE, AUTHORIZATION_REQUEST_TTL_SECONDS, AccessPrincipal,
    AuthorityError, AuthorizationPayload, CLIENT_ID, DEVICE_CODE_TTL_SECONDS,
    DEVICE_POLL_INTERVAL_SECONDS, DeviceAuthorization, REFRESH_TOKEN_TTL_SECONDS, TokenResponse,
    auth_flow_hash, normalize_scopes, normalize_user_code, opaque_hash, random_secret,
    random_user_code, validate_client, verify_pkce,
};

const OAUTH_FAMILY_LOCK_NAMESPACE: i64 = 0x4f_41_55_54_48;

#[derive(Clone)]
pub(super) struct OAuthStore {
    pg: PgPool,
    session_secret: SecretString,
}

#[derive(Debug, FromRow)]
struct AuthFlowRow {
    id: i64,
    user_id: i64,
    payload: String,
    expires_at: DateTime<Utc>,
    consumed_at: Option<DateTime<Utc>>,
}

#[derive(Debug, FromRow)]
struct DeviceGrantRow {
    id: i64,
    client_id: String,
    scopes: String,
    status: String,
    user_id: i64,
    expires_at: DateTime<Utc>,
    interval_seconds: i64,
    last_polled_at: Option<DateTime<Utc>>,
    consumed_at: Option<DateTime<Utc>>,
}

#[derive(Debug, FromRow)]
struct GrantTokenRow {
    id: i64,
    kind: String,
    user_id: i64,
    client_id: String,
    scopes: String,
    family_id: String,
    expires_at: DateTime<Utc>,
    consumed_at: Option<DateTime<Utc>>,
    revoked_at: Option<DateTime<Utc>>,
}

impl OAuthStore {
    pub(super) fn new(pg: PgPool, session_secret: SecretString) -> Self {
        Self { pg, session_secret }
    }

    pub(super) async fn create_authorization_request(
        &self,
        payload: &AuthorizationPayload,
        now: DateTime<Utc>,
    ) -> Result<String, AuthorityError> {
        let token = random_secret()?;
        let token_hash = auth_flow_hash(&self.session_secret, &token)?;
        let encoded = serde_json::to_string(payload).map_err(storage_error)?;
        sqlx::query(
            "INSERT INTO auth_flows (token_hash, purpose, provider, intent, user_id, session_id, payload, expires_at, created_at) VALUES ($1,$2,$3,'consent',0,'',$4,$5,$6)",
        )
        .bind(token_hash)
        .bind(AUTHORIZATION_REQUEST_PURPOSE)
        .bind(CLIENT_ID)
        .bind(encoded)
        .bind(now + Duration::seconds(AUTHORIZATION_REQUEST_TTL_SECONDS))
        .bind(now)
        .execute(&self.pg)
        .await.map_err(storage_error)?;
        Ok(token)
    }

    pub(super) async fn authorization_preview(
        &self,
        request_token: &str,
        now: DateTime<Utc>,
    ) -> Result<(AuthorizationPayload, DateTime<Utc>), AuthorityError> {
        let token_hash = auth_flow_hash(&self.session_secret, request_token)?;
        let row = sqlx::query_as::<_, AuthFlowRow>(
            "SELECT id, user_id, payload, expires_at, consumed_at FROM auth_flows WHERE token_hash = $1 AND purpose = $2 AND provider = $3 AND consumed_at IS NULL AND expires_at > $4",
        )
        .bind(token_hash)
        .bind(AUTHORIZATION_REQUEST_PURPOSE)
        .bind(CLIENT_ID)
        .bind(now)
        .fetch_optional(&self.pg)
        .await.map_err(storage_error)?
        .ok_or(AuthorityError::InvalidGrant)?;
        let payload = decode_authorization_payload(&row.payload)?;
        Ok((payload, row.expires_at))
    }

    pub(super) async fn decide_authorization(
        &self,
        request_token: &str,
        user_id: i64,
        approve: bool,
        now: DateTime<Utc>,
    ) -> Result<String, AuthorityError> {
        if user_id <= 0 {
            return Err(AuthorityError::Unauthorized);
        }
        let token_hash = auth_flow_hash(&self.session_secret, request_token)?;
        let mut tx = self.pg.begin().await.map_err(storage_error)?;
        let request = sqlx::query_as::<_, AuthFlowRow>(
            "SELECT id, user_id, payload, expires_at, consumed_at FROM auth_flows WHERE token_hash = $1 AND purpose = $2 AND provider = $3 FOR UPDATE",
        )
        .bind(token_hash)
        .bind(AUTHORIZATION_REQUEST_PURPOSE)
        .bind(CLIENT_ID)
        .fetch_optional(&mut *tx)
        .await.map_err(storage_error)?
        .ok_or(AuthorityError::InvalidGrant)?;
        if request.consumed_at.is_some() || request.expires_at <= now {
            return Err(AuthorityError::InvalidGrant);
        }
        let payload = decode_authorization_payload(&request.payload)?;
        let code = if approve {
            Some(
                self.insert_authorization_code(&mut tx, user_id, &payload, now)
                    .await?,
            )
        } else {
            None
        };
        let updated = sqlx::query(
            "UPDATE auth_flows SET consumed_at = $1, user_id = $2 WHERE id = $3 AND consumed_at IS NULL",
        )
        .bind(now)
        .bind(user_id)
        .bind(request.id)
        .execute(&mut *tx)
        .await.map_err(storage_error)?;
        if updated.rows_affected() != 1 {
            return Err(AuthorityError::InvalidGrant);
        }
        tx.commit().await.map_err(storage_error)?;
        authorization_callback(&payload, code.as_deref())
    }

    pub(super) async fn exchange_authorization_code(
        &self,
        code: &str,
        client_id: &str,
        redirect_uri: &str,
        verifier: &str,
        now: DateTime<Utc>,
    ) -> Result<TokenResponse, AuthorityError> {
        validate_client(client_id)?;
        let token_hash = auth_flow_hash(&self.session_secret, code)?;
        let mut tx = self.pg.begin().await.map_err(storage_error)?;
        let flow = sqlx::query_as::<_, AuthFlowRow>(
            "SELECT id, user_id, payload, expires_at, consumed_at FROM auth_flows WHERE token_hash = $1 AND purpose = $2 AND provider = $3 FOR UPDATE",
        )
        .bind(token_hash)
        .bind(AUTHORIZATION_CODE_PURPOSE)
        .bind(CLIENT_ID)
        .fetch_optional(&mut *tx)
        .await.map_err(storage_error)?
        .ok_or(AuthorityError::InvalidGrant)?;
        let payload = decode_authorization_payload(&flow.payload)?;
        if flow.consumed_at.is_some()
            || flow.expires_at <= now
            || flow.user_id <= 0
            || payload.client_id != client_id
            || payload.redirect_uri != redirect_uri
            || !verify_pkce(verifier, &payload.code_challenge)
        {
            return Err(AuthorityError::InvalidGrant);
        }
        let updated = sqlx::query(
            "UPDATE auth_flows SET consumed_at = $1 WHERE id = $2 AND consumed_at IS NULL",
        )
        .bind(now)
        .bind(flow.id)
        .execute(&mut *tx)
        .await
        .map_err(storage_error)?;
        if updated.rows_affected() != 1 {
            return Err(AuthorityError::InvalidGrant);
        }
        let pair = self
            .insert_token_pair(&mut tx, flow.user_id, &payload.scope, None, now)
            .await?;
        tx.commit().await.map_err(storage_error)?;
        Ok(pair)
    }

    pub(super) async fn create_device_authorization(
        &self,
        client_id: &str,
        requested_scopes: &str,
        issuer: &str,
        now: DateTime<Utc>,
    ) -> Result<DeviceAuthorization, AuthorityError> {
        validate_client(client_id)?;
        let scopes = normalize_scopes(requested_scopes)?;
        let device_code = random_secret()?;
        let user_code = random_user_code()?;
        let device_code_hash = opaque_hash(&self.session_secret, "device-code", &device_code)?;
        let user_code_hash = opaque_hash(
            &self.session_secret,
            "user-code",
            &normalize_user_code(&user_code),
        )?;
        sqlx::query(
            "INSERT INTO oauth_device_grants (device_code_hash, user_code_hash, client_id, scopes, status, expires_at, interval_seconds, created_at) VALUES ($1,$2,$3,$4,'pending',$5,$6,$7)",
        )
        .bind(device_code_hash)
        .bind(user_code_hash)
        .bind(CLIENT_ID)
        .bind(&scopes)
        .bind(now + Duration::seconds(DEVICE_CODE_TTL_SECONDS))
        .bind(DEVICE_POLL_INTERVAL_SECONDS)
        .bind(now)
        .execute(&self.pg)
        .await.map_err(storage_error)?;

        let verification_uri = format!("{issuer}/oauth/device");
        let mut complete = reqwest::Url::parse(&verification_uri).map_err(storage_error)?;
        complete
            .query_pairs_mut()
            .append_pair("user_code", &user_code);
        Ok(DeviceAuthorization {
            device_code,
            user_code,
            verification_uri,
            verification_uri_complete: complete.into(),
            expires_in: DEVICE_CODE_TTL_SECONDS,
            interval: DEVICE_POLL_INTERVAL_SECONDS,
        })
    }

    pub(super) async fn decide_device(
        &self,
        user_code: &str,
        user_id: i64,
        approve: bool,
        now: DateTime<Utc>,
    ) -> Result<bool, AuthorityError> {
        if user_id <= 0 {
            return Err(AuthorityError::Unauthorized);
        }
        let user_code_hash = opaque_hash(
            &self.session_secret,
            "user-code",
            &normalize_user_code(user_code),
        )?;
        let mut tx = self.pg.begin().await.map_err(storage_error)?;
        let grant = sqlx::query_as::<_, DeviceGrantRow>(
            "SELECT id, client_id, scopes, status, user_id, expires_at, interval_seconds, last_polled_at, consumed_at FROM oauth_device_grants WHERE user_code_hash = $1 FOR UPDATE",
        )
        .bind(user_code_hash)
        .fetch_optional(&mut *tx)
        .await.map_err(storage_error)?
        .ok_or(AuthorityError::InvalidGrant)?;
        if grant.status != "pending" || grant.consumed_at.is_some() || grant.expires_at <= now {
            return Err(AuthorityError::InvalidGrant);
        }
        let status = if approve { "approved" } else { "denied" };
        sqlx::query("UPDATE oauth_device_grants SET status = $1, user_id = $2 WHERE id = $3")
            .bind(status)
            .bind(user_id)
            .bind(grant.id)
            .execute(&mut *tx)
            .await
            .map_err(storage_error)?;
        tx.commit().await.map_err(storage_error)?;
        Ok(approve)
    }

    pub(super) async fn exchange_device_code(
        &self,
        device_code: &str,
        client_id: &str,
        now: DateTime<Utc>,
    ) -> Result<TokenResponse, AuthorityError> {
        validate_client(client_id)?;
        let device_code_hash = opaque_hash(&self.session_secret, "device-code", device_code)?;
        let mut tx = self.pg.begin().await.map_err(storage_error)?;
        let mut grant = sqlx::query_as::<_, DeviceGrantRow>(
            "SELECT id, client_id, scopes, status, user_id, expires_at, interval_seconds, last_polled_at, consumed_at FROM oauth_device_grants WHERE device_code_hash = $1 FOR UPDATE",
        )
        .bind(device_code_hash)
        .fetch_optional(&mut *tx)
        .await.map_err(storage_error)?
        .ok_or(AuthorityError::InvalidGrant)?;
        if grant.client_id != client_id || grant.consumed_at.is_some() {
            return Err(AuthorityError::InvalidGrant);
        }
        if grant.expires_at <= now {
            sqlx::query(
                "UPDATE oauth_device_grants SET consumed_at = COALESCE(consumed_at, $1) WHERE id = $2",
            )
            .bind(now)
            .bind(grant.id)
            .execute(&mut *tx)
            .await.map_err(storage_error)?;
            tx.commit().await.map_err(storage_error)?;
            return Err(AuthorityError::ExpiredToken);
        }
        let slow_down = grant
            .last_polled_at
            .is_some_and(|last| now < last + Duration::seconds(grant.interval_seconds));
        if slow_down {
            grant.interval_seconds += 5;
        }
        sqlx::query(
            "UPDATE oauth_device_grants SET last_polled_at = $1, interval_seconds = $2 WHERE id = $3",
        )
        .bind(now)
        .bind(grant.interval_seconds)
        .bind(grant.id)
        .execute(&mut *tx)
        .await
        .map_err(storage_error)?;
        if slow_down {
            tx.commit().await.map_err(storage_error)?;
            return Err(AuthorityError::SlowDown);
        }
        if grant.status == "denied" {
            sqlx::query(
                "UPDATE oauth_device_grants SET consumed_at = $1 WHERE id = $2 AND consumed_at IS NULL",
            )
            .bind(now)
            .bind(grant.id)
            .execute(&mut *tx)
            .await
            .map_err(storage_error)?;
            tx.commit().await.map_err(storage_error)?;
            return Err(AuthorityError::AccessDenied);
        }
        if grant.status == "pending" {
            tx.commit().await.map_err(storage_error)?;
            return Err(AuthorityError::AuthorizationPending);
        }
        if grant.status != "approved" || grant.user_id <= 0 {
            return Err(AuthorityError::InvalidGrant);
        }
        let pair = self
            .insert_token_pair(&mut tx, grant.user_id, &grant.scopes, None, now)
            .await?;
        let updated = sqlx::query(
            "UPDATE oauth_device_grants SET consumed_at = $1 WHERE id = $2 AND status = 'approved' AND consumed_at IS NULL",
        )
        .bind(now)
        .bind(grant.id)
        .execute(&mut *tx)
        .await.map_err(storage_error)?;
        if updated.rows_affected() != 1 {
            return Err(AuthorityError::InvalidGrant);
        }
        tx.commit().await.map_err(storage_error)?;
        Ok(pair)
    }

    pub(super) async fn rotate_refresh_token(
        &self,
        refresh_token: &str,
        client_id: &str,
        now: DateTime<Utc>,
    ) -> Result<TokenResponse, AuthorityError> {
        validate_client(client_id)?;
        if !refresh_token.starts_with("lmm_ort_") {
            return Err(AuthorityError::InvalidGrant);
        }
        let token_hash = opaque_hash(&self.session_secret, "refresh", refresh_token)?;
        let mut tx = self.pg.begin().await.map_err(storage_error)?;
        let family_id = sqlx::query_scalar::<_, String>(
            "SELECT family_id FROM oauth_grant_tokens WHERE token_hash = $1 AND kind = 'refresh'",
        )
        .bind(&token_hash)
        .fetch_optional(&mut *tx)
        .await
        .map_err(storage_error)?
        .ok_or(AuthorityError::InvalidGrant)?;
        lock_token_family(&mut tx, &family_id).await?;
        let token = sqlx::query_as::<_, GrantTokenRow>(
            "SELECT id, kind, user_id, client_id, scopes, family_id, expires_at, consumed_at, revoked_at FROM oauth_grant_tokens WHERE token_hash = $1 AND kind = 'refresh' FOR UPDATE",
        )
        .bind(token_hash)
        .fetch_optional(&mut *tx)
        .await
        .map_err(storage_error)?
        .ok_or(AuthorityError::InvalidGrant)?;
        if token.client_id != client_id || token.expires_at <= now {
            return Err(AuthorityError::InvalidGrant);
        }
        if token.consumed_at.is_some() || token.revoked_at.is_some() {
            sqlx::query(
                "UPDATE oauth_grant_tokens SET revoked_at = COALESCE(revoked_at, $1) WHERE family_id = $2",
            )
            .bind(now)
            .bind(&token.family_id)
            .execute(&mut *tx)
            .await.map_err(storage_error)?;
            tx.commit().await.map_err(storage_error)?;
            return Err(AuthorityError::InvalidGrant);
        }
        let updated = sqlx::query(
            "UPDATE oauth_grant_tokens SET consumed_at = $1 WHERE id = $2 AND consumed_at IS NULL AND revoked_at IS NULL",
        )
        .bind(now)
        .bind(token.id)
        .execute(&mut *tx)
        .await.map_err(storage_error)?;
        if updated.rows_affected() != 1 {
            return Err(AuthorityError::InvalidGrant);
        }
        let pair = self
            .insert_token_pair(
                &mut tx,
                token.user_id,
                &token.scopes,
                Some(&token.family_id),
                now,
            )
            .await?;
        tx.commit().await.map_err(storage_error)?;
        Ok(pair)
    }

    pub(super) async fn revoke_token(
        &self,
        raw_token: &str,
        client_id: &str,
        now: DateTime<Utc>,
    ) -> Result<(), AuthorityError> {
        validate_client(client_id)?;
        let refresh_hash = opaque_hash(&self.session_secret, "refresh", raw_token)?;
        let access_hash = opaque_hash(&self.session_secret, "access", raw_token)?;
        let mut tx = self.pg.begin().await.map_err(storage_error)?;
        let family_id = sqlx::query_scalar::<_, String>(
            "SELECT family_id FROM oauth_grant_tokens WHERE (token_hash = $1 AND kind = 'refresh') OR (token_hash = $2 AND kind = 'access')",
        )
        .bind(&refresh_hash)
        .bind(&access_hash)
        .fetch_optional(&mut *tx)
        .await
        .map_err(storage_error)?;
        let Some(family_id) = family_id else {
            tx.commit().await.map_err(storage_error)?;
            return Ok(());
        };
        lock_token_family(&mut tx, &family_id).await?;
        let token = sqlx::query_as::<_, GrantTokenRow>(
            "SELECT id, kind, user_id, client_id, scopes, family_id, expires_at, consumed_at, revoked_at FROM oauth_grant_tokens WHERE (token_hash = $1 AND kind = 'refresh') OR (token_hash = $2 AND kind = 'access') FOR UPDATE",
        )
        .bind(refresh_hash)
        .bind(access_hash)
        .fetch_optional(&mut *tx)
        .await
        .map_err(storage_error)?
        .ok_or(AuthorityError::InvalidGrant)?;
        if token.client_id != client_id {
            return Err(AuthorityError::InvalidClient);
        }
        if token.kind == "refresh" {
            sqlx::query(
                "UPDATE oauth_grant_tokens SET revoked_at = COALESCE(revoked_at, $1) WHERE family_id = $2",
            )
            .bind(now)
            .bind(token.family_id)
            .execute(&mut *tx)
            .await
            .map_err(storage_error)?;
        } else {
            sqlx::query(
                "UPDATE oauth_grant_tokens SET revoked_at = COALESCE(revoked_at, $1) WHERE id = $2",
            )
            .bind(now)
            .bind(token.id)
            .execute(&mut *tx)
            .await
            .map_err(storage_error)?;
        }
        tx.commit().await.map_err(storage_error)?;
        Ok(())
    }

    pub(super) async fn access_principal(
        &self,
        access_token: &str,
        now: DateTime<Utc>,
    ) -> Result<AccessPrincipal, AuthorityError> {
        if !access_token.starts_with("lmm_oat_") {
            return Err(AuthorityError::Unauthorized);
        }
        let token_hash = opaque_hash(&self.session_secret, "access", access_token)?;
        let row = sqlx::query_as::<_, (i64, String)>(
            "SELECT token_record.user_id, token_record.scopes FROM oauth_grant_tokens AS token_record JOIN users ON users.id = token_record.user_id AND users.deleted_at IS NULL AND users.status = 1 WHERE token_record.token_hash = $1 AND token_record.kind = 'access' AND token_record.client_id = $2 AND token_record.revoked_at IS NULL AND token_record.consumed_at IS NULL AND token_record.expires_at > $3",
        )
        .bind(token_hash)
        .bind(CLIENT_ID)
        .bind(now)
        .fetch_optional(&self.pg)
        .await.map_err(storage_error)?
        .ok_or(AuthorityError::Unauthorized)?;
        Ok(AccessPrincipal::from_parts(row.0, &row.1))
    }

    async fn insert_authorization_code(
        &self,
        tx: &mut Transaction<'_, Postgres>,
        user_id: i64,
        payload: &AuthorizationPayload,
        now: DateTime<Utc>,
    ) -> Result<String, AuthorityError> {
        let code = random_secret()?;
        let token_hash = auth_flow_hash(&self.session_secret, &code)?;
        let encoded = serde_json::to_string(payload).map_err(storage_error)?;
        sqlx::query(
            "INSERT INTO auth_flows (token_hash, purpose, provider, intent, user_id, session_id, payload, expires_at, created_at) VALUES ($1,$2,$3,'exchange',$4,'',$5,$6,$7)",
        )
        .bind(token_hash)
        .bind(AUTHORIZATION_CODE_PURPOSE)
        .bind(CLIENT_ID)
        .bind(user_id)
        .bind(encoded)
        .bind(now + Duration::seconds(AUTHORIZATION_CODE_TTL_SECONDS))
        .bind(now)
        .execute(&mut **tx)
        .await.map_err(storage_error)?;
        Ok(code)
    }

    async fn insert_token_pair(
        &self,
        tx: &mut Transaction<'_, Postgres>,
        user_id: i64,
        scopes: &str,
        existing_family_id: Option<&str>,
        now: DateTime<Utc>,
    ) -> Result<TokenResponse, AuthorityError> {
        let access_token = format!("lmm_oat_{}", random_secret()?);
        let refresh_token = format!("lmm_ort_{}", random_secret()?);
        let family_id = match existing_family_id {
            Some(value) => value.to_owned(),
            None => uuid::Uuid::new_v4().to_string(),
        };
        let access_hash = opaque_hash(&self.session_secret, "access", &access_token)?;
        let refresh_hash = opaque_hash(&self.session_secret, "refresh", &refresh_token)?;
        sqlx::query(
            "INSERT INTO oauth_grant_tokens (token_hash, kind, user_id, client_id, scopes, family_id, expires_at, created_at) VALUES ($1,'access',$2,$3,$4,$5,$6,$7), ($8,'refresh',$2,$3,$4,$5,$9,$7)",
        )
        .bind(access_hash)
        .bind(user_id)
        .bind(CLIENT_ID)
        .bind(scopes)
        .bind(&family_id)
        .bind(now + Duration::seconds(ACCESS_TOKEN_TTL_SECONDS))
        .bind(now)
        .bind(refresh_hash)
        .bind(now + Duration::seconds(REFRESH_TOKEN_TTL_SECONDS))
        .execute(&mut **tx)
        .await
        .map_err(storage_error)?;
        Ok(TokenResponse {
            access_token,
            token_type: "Bearer",
            expires_in: ACCESS_TOKEN_TTL_SECONDS,
            refresh_token,
            scope: scopes.to_owned(),
        })
    }
}

async fn lock_token_family(
    tx: &mut Transaction<'_, Postgres>,
    family_id: &str,
) -> Result<(), AuthorityError> {
    sqlx::query("SELECT pg_advisory_xact_lock(hashtextextended($1, $2))")
        .bind(family_id)
        .bind(OAUTH_FAMILY_LOCK_NAMESPACE)
        .execute(&mut **tx)
        .await
        .map_err(storage_error)?;
    Ok(())
}

fn storage_error(error: impl std::fmt::Display) -> AuthorityError {
    tracing::warn!(%error, "OAuth authority storage operation failed");
    AuthorityError::Storage
}

fn decode_authorization_payload(value: &str) -> Result<AuthorizationPayload, AuthorityError> {
    serde_json::from_str(value).map_err(storage_error)
}

fn authorization_callback(
    payload: &AuthorizationPayload,
    code: Option<&str>,
) -> Result<String, AuthorityError> {
    let mut callback =
        reqwest::Url::parse(&payload.redirect_uri).map_err(|_| AuthorityError::InvalidRequest)?;
    {
        let mut query = callback.query_pairs_mut();
        if let Some(code) = code {
            query.append_pair("code", code);
        } else {
            query.append_pair("error", "access_denied");
        }
        query.append_pair("state", &payload.state);
    }
    Ok(callback.into())
}
