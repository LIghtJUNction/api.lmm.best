-- Contract 3 forward migration for current dashboard workflow data.
--
-- Contract 2 is immutable. Contract 3 adds the Go-owned archival,
-- developer-access, release-note, compensation-gift, and advanced-security facts required by
-- newly mounted Rust routes without rewriting existing status or historical data.

ALTER TABLE __LMM_APP_SCHEMA__.open_source_bounty_projects
    ADD COLUMN IF NOT EXISTS archived_at BIGINT NOT NULL DEFAULT 0;

UPDATE __LMM_APP_SCHEMA__.open_source_bounty_projects
SET archived_at = 0
WHERE archived_at IS NULL;

ALTER TABLE __LMM_APP_SCHEMA__.open_source_bounty_projects
    ALTER COLUMN archived_at SET DEFAULT 0,
    ALTER COLUMN archived_at SET NOT NULL;

CREATE INDEX IF NOT EXISTS idx_open_source_bounty_projects_archived_at
    ON __LMM_APP_SCHEMA__.open_source_bounty_projects (archived_at);

CREATE TABLE IF NOT EXISTS __LMM_APP_SCHEMA__.developer_access_requests (
    id BIGSERIAL PRIMARY KEY,
    user_id BIGINT NOT NULL,
    status VARCHAR(20) NOT NULL DEFAULT 'pending',
    source VARCHAR(40) NOT NULL DEFAULT 'legacy',
    reason TEXT,
    ai_recommendation TEXT,
    admin_user_id BIGINT,
    admin_note TEXT,
    created_at BIGINT NOT NULL,
    reviewed_at BIGINT NOT NULL DEFAULT 0
);

CREATE INDEX IF NOT EXISTS idx_developer_access_requests_user_id
    ON __LMM_APP_SCHEMA__.developer_access_requests (user_id);
CREATE INDEX IF NOT EXISTS idx_developer_access_requests_status
    ON __LMM_APP_SCHEMA__.developer_access_requests (status);
CREATE INDEX IF NOT EXISTS idx_developer_access_requests_source
    ON __LMM_APP_SCHEMA__.developer_access_requests (source);
CREATE INDEX IF NOT EXISTS idx_developer_access_requests_admin_user_id
    ON __LMM_APP_SCHEMA__.developer_access_requests (admin_user_id);
CREATE INDEX IF NOT EXISTS idx_developer_access_requests_created_at
    ON __LMM_APP_SCHEMA__.developer_access_requests (created_at);

CREATE TABLE IF NOT EXISTS __LMM_APP_SCHEMA__.release_notes (
    id BIGSERIAL PRIMARY KEY,
    version VARCHAR(128) NOT NULL,
    revision BIGINT NOT NULL,
    content TEXT NOT NULL,
    published_at BIGINT NOT NULL,
    published_by BIGINT NOT NULL
);

CREATE UNIQUE INDEX IF NOT EXISTS idx_release_note_version_revision
    ON __LMM_APP_SCHEMA__.release_notes (version, revision);
CREATE INDEX IF NOT EXISTS idx_release_notes_published_at
    ON __LMM_APP_SCHEMA__.release_notes (published_at);
CREATE INDEX IF NOT EXISTS idx_release_notes_published_by
    ON __LMM_APP_SCHEMA__.release_notes (published_by);

CREATE TABLE IF NOT EXISTS __LMM_APP_SCHEMA__.release_note_reads (
    id BIGSERIAL PRIMARY KEY,
    release_note_id BIGINT NOT NULL,
    user_id BIGINT NOT NULL,
    read_at BIGINT NOT NULL
);

CREATE UNIQUE INDEX IF NOT EXISTS idx_release_note_read_user_note
    ON __LMM_APP_SCHEMA__.release_note_reads (release_note_id, user_id);

CREATE TABLE IF NOT EXISTS __LMM_APP_SCHEMA__.gifts (
    id BIGSERIAL PRIMARY KEY,
    title VARCHAR(64) NOT NULL,
    description VARCHAR(255) DEFAULT '',
    quota BIGINT NOT NULL,
    start_at BIGINT NOT NULL,
    end_at BIGINT NOT NULL,
    min_used_quota BIGINT NOT NULL DEFAULT 0,
    min_account_age_days BIGINT NOT NULL DEFAULT 0,
    enabled BOOLEAN NOT NULL DEFAULT TRUE,
    created_at BIGINT
);

CREATE INDEX IF NOT EXISTS idx_gifts_start_at
    ON __LMM_APP_SCHEMA__.gifts (start_at);
CREATE INDEX IF NOT EXISTS idx_gifts_end_at
    ON __LMM_APP_SCHEMA__.gifts (end_at);

CREATE TABLE IF NOT EXISTS __LMM_APP_SCHEMA__.gift_claims (
    id BIGSERIAL PRIMARY KEY,
    gift_id BIGINT NOT NULL,
    user_id BIGINT NOT NULL,
    username VARCHAR(64) DEFAULT '',
    quota BIGINT NOT NULL,
    created_at BIGINT
);

CREATE UNIQUE INDEX IF NOT EXISTS idx_gift_user
    ON __LMM_APP_SCHEMA__.gift_claims (gift_id, user_id);
CREATE INDEX IF NOT EXISTS idx_gift_claims_username
    ON __LMM_APP_SCHEMA__.gift_claims (username);

CREATE TABLE IF NOT EXISTS __LMM_APP_SCHEMA__.advanced_security_events (
    id BIGSERIAL PRIMARY KEY,
    created_at BIGINT,
    request_id TEXT,
    user_id BIGINT,
    username TEXT,
    token_id BIGINT,
    channel_id BIGINT,
    model_name TEXT,
    "group" TEXT,
    endpoint TEXT,
    decision TEXT,
    rule_id TEXT,
    rule_name TEXT,
    category TEXT,
    layer TEXT,
    severity TEXT,
    source TEXT,
    rule_version TEXT,
    pattern_digest TEXT,
    input_digest TEXT,
    match_count BIGINT
);

CREATE INDEX IF NOT EXISTS idx_advanced_security_events_created_at
    ON __LMM_APP_SCHEMA__.advanced_security_events (created_at);
CREATE INDEX IF NOT EXISTS idx_advanced_security_events_request_id
    ON __LMM_APP_SCHEMA__.advanced_security_events (request_id);
CREATE INDEX IF NOT EXISTS idx_advanced_security_events_user_id
    ON __LMM_APP_SCHEMA__.advanced_security_events (user_id);
CREATE INDEX IF NOT EXISTS idx_advanced_security_events_username
    ON __LMM_APP_SCHEMA__.advanced_security_events (username);
CREATE INDEX IF NOT EXISTS idx_advanced_security_events_token_id
    ON __LMM_APP_SCHEMA__.advanced_security_events (token_id);
CREATE INDEX IF NOT EXISTS idx_advanced_security_events_channel_id
    ON __LMM_APP_SCHEMA__.advanced_security_events (channel_id);
CREATE INDEX IF NOT EXISTS idx_advanced_security_events_model_name
    ON __LMM_APP_SCHEMA__.advanced_security_events (model_name);
CREATE INDEX IF NOT EXISTS idx_advanced_security_events_group
    ON __LMM_APP_SCHEMA__.advanced_security_events ("group");
CREATE INDEX IF NOT EXISTS idx_advanced_security_events_decision
    ON __LMM_APP_SCHEMA__.advanced_security_events (decision);
CREATE INDEX IF NOT EXISTS idx_advanced_security_events_rule_id
    ON __LMM_APP_SCHEMA__.advanced_security_events (rule_id);
CREATE INDEX IF NOT EXISTS idx_advanced_security_events_category
    ON __LMM_APP_SCHEMA__.advanced_security_events (category);
CREATE INDEX IF NOT EXISTS idx_advanced_security_events_layer
    ON __LMM_APP_SCHEMA__.advanced_security_events (layer);
CREATE INDEX IF NOT EXISTS idx_advanced_security_events_severity
    ON __LMM_APP_SCHEMA__.advanced_security_events (severity);

CREATE TABLE IF NOT EXISTS __LMM_APP_SCHEMA__.personal_access_ips (
    user_id BIGINT PRIMARY KEY,
    ip VARCHAR(45) NOT NULL,
    created_at BIGINT,
    updated_at BIGINT
);

CREATE INDEX IF NOT EXISTS idx_personal_access_ips_ip
    ON __LMM_APP_SCHEMA__.personal_access_ips (ip);
