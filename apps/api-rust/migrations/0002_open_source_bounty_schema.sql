-- Contract 2 forward migration for the Go-owned open-source bounty domain.
--
-- This artifact is intentionally separate from the frozen contract-1 baseline.  It is applied
-- only by the forward migrator after contract 1 is already installed.  Every identifier is
-- qualified through the migrator's schema token; the artifact never writes to PostgreSQL's
-- public schema and never drops or rewrites existing bounty data.

CREATE TABLE IF NOT EXISTS __LMM_APP_SCHEMA__.open_source_bounty_projects (
    id BIGSERIAL PRIMARY KEY,
    owner_user_id BIGINT NOT NULL,
    repository_url VARCHAR(512) NOT NULL,
    title VARCHAR(120) NOT NULL,
    description TEXT NOT NULL,
    rules TEXT NOT NULL,
    reward_quota BIGINT NOT NULL DEFAULT 0,
    net_reward_quota BIGINT NOT NULL DEFAULT 0,
    reward_slots BIGINT NOT NULL DEFAULT 0,
    escrow_quota BIGINT NOT NULL DEFAULT 0,
    platform_fee_rate_bps BIGINT NOT NULL DEFAULT 0,
    platform_fee_quota BIGINT NOT NULL DEFAULT 0,
    status VARCHAR(20) NOT NULL DEFAULT 'draft',
    created_at BIGINT NOT NULL,
    updated_at BIGINT NOT NULL,
    published_at BIGINT NOT NULL DEFAULT 0,
    closed_at BIGINT NOT NULL DEFAULT 0
);

CREATE TABLE IF NOT EXISTS __LMM_APP_SCHEMA__.open_source_bounty_challenges (
    id BIGSERIAL PRIMARY KEY,
    project_id BIGINT NOT NULL,
    participant_user_id BIGINT NOT NULL,
    github_handle VARCHAR(100) NOT NULL,
    status VARCHAR(20) NOT NULL,
    issue_url VARCHAR(512) NOT NULL DEFAULT '',
    pull_request_url VARCHAR(512) NOT NULL DEFAULT '',
    submission_note TEXT NOT NULL DEFAULT '',
    review_note TEXT NOT NULL DEFAULT '',
    reward_quota BIGINT NOT NULL DEFAULT 0,
    tip_quota BIGINT NOT NULL DEFAULT 0,
    owner_rating_score BIGINT NOT NULL DEFAULT 0,
    owner_rating_comment VARCHAR(1000) NOT NULL DEFAULT '',
    owner_rated_at BIGINT NOT NULL DEFAULT 0,
    contributor_rating_score BIGINT NOT NULL DEFAULT 0,
    contributor_rating_comment VARCHAR(1000) NOT NULL DEFAULT '',
    contributor_rated_at BIGINT NOT NULL DEFAULT 0,
    owner_rating_overturned BOOLEAN NOT NULL DEFAULT FALSE,
    accepted_at BIGINT NOT NULL,
    submitted_at BIGINT NOT NULL DEFAULT 0,
    reviewed_at BIGINT NOT NULL DEFAULT 0,
    rejected_at BIGINT NOT NULL DEFAULT 0,
    paid_at BIGINT NOT NULL DEFAULT 0,
    created_at BIGINT NOT NULL,
    updated_at BIGINT NOT NULL
);

CREATE TABLE IF NOT EXISTS __LMM_APP_SCHEMA__.open_source_bounty_ledgers (
    id BIGSERIAL PRIMARY KEY,
    project_id BIGINT NOT NULL,
    challenge_id BIGINT NOT NULL DEFAULT 0,
    user_id BIGINT NOT NULL,
    counterparty_user_id BIGINT NOT NULL DEFAULT 0,
    kind VARCHAR(32) NOT NULL,
    quota BIGINT NOT NULL,
    note VARCHAR(500) NOT NULL DEFAULT '',
    reward_payout_key VARCHAR(64),
    recipient_read_at BIGINT NOT NULL DEFAULT 0,
    thanked_at BIGINT NOT NULL DEFAULT 0,
    created_at BIGINT NOT NULL
);

CREATE TABLE IF NOT EXISTS __LMM_APP_SCHEMA__.open_source_bounty_disputes (
    id BIGSERIAL PRIMARY KEY,
    challenge_id BIGINT NOT NULL,
    project_id BIGINT NOT NULL,
    opened_by_user_id BIGINT NOT NULL,
    against_user_id BIGINT NOT NULL,
    case_key VARCHAR(96) NOT NULL,
    open_key VARCHAR(64),
    reason VARCHAR(64) NOT NULL,
    statement TEXT NOT NULL,
    project_title_snapshot VARCHAR(120) NOT NULL,
    repository_url_snapshot VARCHAR(512) NOT NULL,
    project_rules_snapshot TEXT NOT NULL,
    project_escrow_quota_snapshot BIGINT NOT NULL,
    challenge_status_snapshot VARCHAR(20) NOT NULL,
    issue_url_snapshot VARCHAR(512) NOT NULL DEFAULT '',
    pull_request_url_snapshot VARCHAR(512) NOT NULL DEFAULT '',
    submission_note_snapshot TEXT NOT NULL DEFAULT '',
    review_note_snapshot TEXT NOT NULL DEFAULT '',
    reward_quota_snapshot BIGINT NOT NULL,
    tip_quota_snapshot BIGINT NOT NULL DEFAULT 0,
    owner_rating_score_snapshot BIGINT NOT NULL DEFAULT 0,
    owner_rating_comment_snapshot VARCHAR(1000) NOT NULL DEFAULT '',
    contributor_rating_score_snapshot BIGINT NOT NULL DEFAULT 0,
    contributor_rating_comment_snapshot VARCHAR(1000) NOT NULL DEFAULT '',
    status VARCHAR(32) NOT NULL,
    resolution TEXT NOT NULL DEFAULT '',
    resolved_by_user_id BIGINT NOT NULL DEFAULT 0,
    created_at BIGINT NOT NULL,
    updated_at BIGINT NOT NULL,
    resolved_at BIGINT NOT NULL DEFAULT 0
);

CREATE TABLE IF NOT EXISTS __LMM_APP_SCHEMA__.open_source_bounty_mcp_tokens (
    id BIGSERIAL PRIMARY KEY,
    user_id BIGINT NOT NULL,
    token_hash CHAR(64) NOT NULL,
    token_hint VARCHAR(24) NOT NULL,
    created_at BIGINT NOT NULL,
    updated_at BIGINT NOT NULL,
    last_used_at BIGINT NOT NULL DEFAULT 0
);

CREATE TABLE IF NOT EXISTS __LMM_APP_SCHEMA__.open_source_bounty_mcp_confirmations (
    id VARCHAR(80) PRIMARY KEY,
    user_id BIGINT NOT NULL,
    tool_name VARCHAR(128) NOT NULL,
    payload_hash CHAR(64) NOT NULL,
    expires_at BIGINT NOT NULL,
    consumed_at BIGINT NOT NULL DEFAULT 0,
    created_at BIGINT NOT NULL
);

CREATE TABLE IF NOT EXISTS __LMM_APP_SCHEMA__.open_source_bounty_mcp_operations (
    id VARCHAR(80) PRIMARY KEY,
    user_id BIGINT NOT NULL,
    tool_name VARCHAR(128) NOT NULL,
    payload_hash CHAR(64) NOT NULL,
    result_json TEXT NOT NULL,
    created_at BIGINT NOT NULL
);

CREATE TABLE IF NOT EXISTS __LMM_APP_SCHEMA__.open_source_bounty_rest_operations (
    id BIGSERIAL PRIMARY KEY,
    user_id BIGINT NOT NULL,
    operation VARCHAR(64) NOT NULL,
    idempotency_key_hash CHAR(64) NOT NULL,
    payload_hash CHAR(64) NOT NULL,
    result_json TEXT NOT NULL DEFAULT '',
    created_at BIGINT NOT NULL,
    completed_at BIGINT NOT NULL DEFAULT 0
);

CREATE INDEX IF NOT EXISTS idx_open_source_bounty_projects_owner_user_id
    ON __LMM_APP_SCHEMA__.open_source_bounty_projects (owner_user_id);
CREATE INDEX IF NOT EXISTS idx_open_source_bounty_projects_repository_url
    ON __LMM_APP_SCHEMA__.open_source_bounty_projects (repository_url);
CREATE INDEX IF NOT EXISTS idx_open_source_bounty_projects_status
    ON __LMM_APP_SCHEMA__.open_source_bounty_projects (status);
CREATE INDEX IF NOT EXISTS idx_open_source_bounty_projects_published_at
    ON __LMM_APP_SCHEMA__.open_source_bounty_projects (published_at);

CREATE INDEX IF NOT EXISTS idx_open_source_bounty_challenges_project_id
    ON __LMM_APP_SCHEMA__.open_source_bounty_challenges (project_id);
CREATE INDEX IF NOT EXISTS idx_open_source_bounty_challenges_participant_user_id
    ON __LMM_APP_SCHEMA__.open_source_bounty_challenges (participant_user_id);
CREATE INDEX IF NOT EXISTS idx_open_source_bounty_project_participant
    ON __LMM_APP_SCHEMA__.open_source_bounty_challenges (project_id, participant_user_id);
CREATE INDEX IF NOT EXISTS idx_open_source_bounty_challenges_status
    ON __LMM_APP_SCHEMA__.open_source_bounty_challenges (status);
CREATE INDEX IF NOT EXISTS idx_open_source_bounty_challenges_pull_request_url
    ON __LMM_APP_SCHEMA__.open_source_bounty_challenges (pull_request_url);
CREATE INDEX IF NOT EXISTS idx_open_source_bounty_challenges_owner_rating_overturned
    ON __LMM_APP_SCHEMA__.open_source_bounty_challenges (owner_rating_overturned);
CREATE INDEX IF NOT EXISTS idx_open_source_bounty_challenges_rejected_at
    ON __LMM_APP_SCHEMA__.open_source_bounty_challenges (rejected_at);

CREATE INDEX IF NOT EXISTS idx_open_source_bounty_ledgers_project_id
    ON __LMM_APP_SCHEMA__.open_source_bounty_ledgers (project_id);
CREATE INDEX IF NOT EXISTS idx_open_source_bounty_ledgers_challenge_id
    ON __LMM_APP_SCHEMA__.open_source_bounty_ledgers (challenge_id);
CREATE INDEX IF NOT EXISTS idx_open_source_bounty_ledgers_user_id
    ON __LMM_APP_SCHEMA__.open_source_bounty_ledgers (user_id);
CREATE INDEX IF NOT EXISTS idx_open_source_bounty_ledgers_counterparty_user_id
    ON __LMM_APP_SCHEMA__.open_source_bounty_ledgers (counterparty_user_id);
CREATE INDEX IF NOT EXISTS idx_open_source_bounty_ledgers_kind
    ON __LMM_APP_SCHEMA__.open_source_bounty_ledgers (kind);
CREATE UNIQUE INDEX IF NOT EXISTS uni_open_source_bounty_ledgers_reward_payout_key
    ON __LMM_APP_SCHEMA__.open_source_bounty_ledgers (reward_payout_key);
CREATE INDEX IF NOT EXISTS idx_open_source_bounty_ledgers_recipient_read_at
    ON __LMM_APP_SCHEMA__.open_source_bounty_ledgers (recipient_read_at);
CREATE INDEX IF NOT EXISTS idx_open_source_bounty_ledgers_thanked_at
    ON __LMM_APP_SCHEMA__.open_source_bounty_ledgers (thanked_at);
CREATE INDEX IF NOT EXISTS idx_open_source_bounty_ledgers_created_at
    ON __LMM_APP_SCHEMA__.open_source_bounty_ledgers (created_at);

CREATE INDEX IF NOT EXISTS idx_open_source_bounty_disputes_challenge_id
    ON __LMM_APP_SCHEMA__.open_source_bounty_disputes (challenge_id);
CREATE INDEX IF NOT EXISTS idx_open_source_bounty_disputes_project_id
    ON __LMM_APP_SCHEMA__.open_source_bounty_disputes (project_id);
CREATE INDEX IF NOT EXISTS idx_open_source_bounty_disputes_opened_by_user_id
    ON __LMM_APP_SCHEMA__.open_source_bounty_disputes (opened_by_user_id);
CREATE INDEX IF NOT EXISTS idx_open_source_bounty_disputes_against_user_id
    ON __LMM_APP_SCHEMA__.open_source_bounty_disputes (against_user_id);
CREATE UNIQUE INDEX IF NOT EXISTS uni_open_source_bounty_disputes_case_key
    ON __LMM_APP_SCHEMA__.open_source_bounty_disputes (case_key);
CREATE UNIQUE INDEX IF NOT EXISTS uni_open_source_bounty_disputes_open_key
    ON __LMM_APP_SCHEMA__.open_source_bounty_disputes (open_key);
CREATE INDEX IF NOT EXISTS idx_open_source_bounty_disputes_status
    ON __LMM_APP_SCHEMA__.open_source_bounty_disputes (status);
CREATE INDEX IF NOT EXISTS idx_open_source_bounty_disputes_resolved_by_user_id
    ON __LMM_APP_SCHEMA__.open_source_bounty_disputes (resolved_by_user_id);
CREATE INDEX IF NOT EXISTS idx_open_source_bounty_disputes_created_at
    ON __LMM_APP_SCHEMA__.open_source_bounty_disputes (created_at);

CREATE UNIQUE INDEX IF NOT EXISTS uni_open_source_bounty_mcp_tokens_user_id
    ON __LMM_APP_SCHEMA__.open_source_bounty_mcp_tokens (user_id);
CREATE UNIQUE INDEX IF NOT EXISTS uni_open_source_bounty_mcp_tokens_token_hash
    ON __LMM_APP_SCHEMA__.open_source_bounty_mcp_tokens (token_hash);

CREATE INDEX IF NOT EXISTS idx_open_source_bounty_mcp_confirmations_user_id
    ON __LMM_APP_SCHEMA__.open_source_bounty_mcp_confirmations (user_id);
CREATE INDEX IF NOT EXISTS idx_open_source_bounty_mcp_confirmations_tool_name
    ON __LMM_APP_SCHEMA__.open_source_bounty_mcp_confirmations (tool_name);
CREATE INDEX IF NOT EXISTS idx_open_source_bounty_mcp_confirmations_expires_at
    ON __LMM_APP_SCHEMA__.open_source_bounty_mcp_confirmations (expires_at);
CREATE INDEX IF NOT EXISTS idx_open_source_bounty_mcp_confirmations_consumed_at
    ON __LMM_APP_SCHEMA__.open_source_bounty_mcp_confirmations (consumed_at);

CREATE INDEX IF NOT EXISTS idx_open_source_bounty_mcp_operations_user_id
    ON __LMM_APP_SCHEMA__.open_source_bounty_mcp_operations (user_id);
CREATE INDEX IF NOT EXISTS idx_open_source_bounty_mcp_operations_tool_name
    ON __LMM_APP_SCHEMA__.open_source_bounty_mcp_operations (tool_name);
CREATE INDEX IF NOT EXISTS idx_open_source_bounty_mcp_operations_created_at
    ON __LMM_APP_SCHEMA__.open_source_bounty_mcp_operations (created_at);

CREATE UNIQUE INDEX IF NOT EXISTS idx_open_source_bounty_rest_operation
    ON __LMM_APP_SCHEMA__.open_source_bounty_rest_operations
    (user_id, operation, idempotency_key_hash);
CREATE INDEX IF NOT EXISTS idx_open_source_bounty_rest_operations_created_at
    ON __LMM_APP_SCHEMA__.open_source_bounty_rest_operations (created_at);
CREATE INDEX IF NOT EXISTS idx_open_source_bounty_rest_operations_completed_at
    ON __LMM_APP_SCHEMA__.open_source_bounty_rest_operations (completed_at);
