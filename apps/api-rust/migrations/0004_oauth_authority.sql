-- Contract 4 forward migration for the first-party OAuth 2.1 authority.
--
-- Opaque device, access, and refresh credentials are stored only as keyed
-- hashes. PostgreSQL is authoritative for grant state and replay revocation.

CREATE TABLE IF NOT EXISTS __LMM_APP_SCHEMA__.oauth_device_grants (
    id BIGSERIAL PRIMARY KEY,
    device_code_hash CHAR(64) NOT NULL,
    user_code_hash CHAR(64) NOT NULL,
    client_id VARCHAR(64) NOT NULL,
    scopes TEXT NOT NULL,
    status VARCHAR(16) NOT NULL,
    user_id BIGINT NOT NULL DEFAULT 0,
    interval_seconds BIGINT NOT NULL,
    last_polled_at TIMESTAMPTZ,
    created_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
    expires_at TIMESTAMPTZ NOT NULL,
    consumed_at TIMESTAMPTZ
);

CREATE UNIQUE INDEX IF NOT EXISTS idx_oauth_device_grants_device_code_hash
    ON __LMM_APP_SCHEMA__.oauth_device_grants (device_code_hash);
CREATE UNIQUE INDEX IF NOT EXISTS idx_oauth_device_grants_user_code_hash
    ON __LMM_APP_SCHEMA__.oauth_device_grants (user_code_hash);
CREATE INDEX IF NOT EXISTS idx_oauth_device_grants_client_id
    ON __LMM_APP_SCHEMA__.oauth_device_grants (client_id);
CREATE INDEX IF NOT EXISTS idx_oauth_device_grants_status
    ON __LMM_APP_SCHEMA__.oauth_device_grants (status);
CREATE INDEX IF NOT EXISTS idx_oauth_device_grants_user_id
    ON __LMM_APP_SCHEMA__.oauth_device_grants (user_id);
CREATE INDEX IF NOT EXISTS idx_oauth_device_grants_expires_at
    ON __LMM_APP_SCHEMA__.oauth_device_grants (expires_at);
CREATE INDEX IF NOT EXISTS idx_oauth_device_grants_consumed_at
    ON __LMM_APP_SCHEMA__.oauth_device_grants (consumed_at);

CREATE TABLE IF NOT EXISTS __LMM_APP_SCHEMA__.oauth_grant_tokens (
    id BIGSERIAL PRIMARY KEY,
    token_hash CHAR(64) NOT NULL,
    kind VARCHAR(16) NOT NULL,
    family_id CHAR(36) NOT NULL,
    client_id VARCHAR(64) NOT NULL,
    user_id BIGINT NOT NULL,
    scopes TEXT NOT NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
    expires_at TIMESTAMPTZ NOT NULL,
    consumed_at TIMESTAMPTZ,
    revoked_at TIMESTAMPTZ
);

CREATE UNIQUE INDEX IF NOT EXISTS idx_oauth_grant_tokens_token_hash
    ON __LMM_APP_SCHEMA__.oauth_grant_tokens (token_hash);
CREATE INDEX IF NOT EXISTS idx_oauth_token_family_kind
    ON __LMM_APP_SCHEMA__.oauth_grant_tokens (family_id, kind);
CREATE INDEX IF NOT EXISTS idx_oauth_grant_tokens_client_id
    ON __LMM_APP_SCHEMA__.oauth_grant_tokens (client_id);
CREATE INDEX IF NOT EXISTS idx_oauth_grant_tokens_user_id
    ON __LMM_APP_SCHEMA__.oauth_grant_tokens (user_id);
CREATE INDEX IF NOT EXISTS idx_oauth_grant_tokens_expires_at
    ON __LMM_APP_SCHEMA__.oauth_grant_tokens (expires_at);
CREATE INDEX IF NOT EXISTS idx_oauth_grant_tokens_consumed_at
    ON __LMM_APP_SCHEMA__.oauth_grant_tokens (consumed_at);
CREATE INDEX IF NOT EXISTS idx_oauth_grant_tokens_revoked_at
    ON __LMM_APP_SCHEMA__.oauth_grant_tokens (revoked_at);

DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM pg_constraint
        WHERE conname = 'oauth_device_grants_status_check'
          AND connamespace = to_regnamespace('__LMM_APP_SCHEMA__')
    ) THEN
        ALTER TABLE __LMM_APP_SCHEMA__.oauth_device_grants
            ADD CONSTRAINT oauth_device_grants_status_check
            CHECK (status IN ('pending', 'approved', 'denied'));
    END IF;
    IF NOT EXISTS (
        SELECT 1 FROM pg_constraint
        WHERE conname = 'oauth_grant_tokens_kind_check'
          AND connamespace = to_regnamespace('__LMM_APP_SCHEMA__')
    ) THEN
        ALTER TABLE __LMM_APP_SCHEMA__.oauth_grant_tokens
            ADD CONSTRAINT oauth_grant_tokens_kind_check
            CHECK (kind IN ('access', 'refresh'));
    END IF;
END
$$;
