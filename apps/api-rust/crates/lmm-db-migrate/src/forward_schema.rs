//! Forward-only schema checks for mounted Rust business routes.
//!
//! Contract 1 intentionally remains the frozen 34-table SQLite baseline.  The Go-owned bounty
//! tables are an expand step and become required only once a release advances to contract 2.

use postgres::Transaction;

use crate::MigrationError;

/// The first schema contract that requires the bounty expand step.
pub const BOUNTY_SCHEMA_CONTRACT_ID: i64 = 2;

#[derive(Clone, Copy)]
struct ColumnRequirement {
    name: &'static str,
    data_type: &'static str,
    character_maximum_length: Option<i32>,
    nullable: bool,
}

const fn column(
    name: &'static str,
    data_type: &'static str,
    character_maximum_length: Option<i32>,
) -> ColumnRequirement {
    ColumnRequirement {
        name,
        data_type,
        character_maximum_length,
        nullable: false,
    }
}

const fn nullable_column(
    name: &'static str,
    data_type: &'static str,
    character_maximum_length: Option<i32>,
) -> ColumnRequirement {
    ColumnRequirement {
        name,
        data_type,
        character_maximum_length,
        nullable: true,
    }
}

const PROJECT_COLUMNS: &[ColumnRequirement] = &[
    column("id", "bigint", None),
    column("owner_user_id", "bigint", None),
    column("repository_url", "character varying", Some(512)),
    column("title", "character varying", Some(120)),
    column("description", "text", None),
    column("rules", "text", None),
    column("reward_quota", "bigint", None),
    column("net_reward_quota", "bigint", None),
    column("reward_slots", "bigint", None),
    column("escrow_quota", "bigint", None),
    column("platform_fee_rate_bps", "bigint", None),
    column("platform_fee_quota", "bigint", None),
    column("status", "character varying", Some(20)),
    column("created_at", "bigint", None),
    column("updated_at", "bigint", None),
    column("published_at", "bigint", None),
    column("closed_at", "bigint", None),
];

const CHALLENGE_COLUMNS: &[ColumnRequirement] = &[
    column("id", "bigint", None),
    column("project_id", "bigint", None),
    column("participant_user_id", "bigint", None),
    column("github_handle", "character varying", Some(100)),
    column("status", "character varying", Some(20)),
    column("issue_url", "character varying", Some(512)),
    column("pull_request_url", "character varying", Some(512)),
    column("submission_note", "text", None),
    column("review_note", "text", None),
    column("reward_quota", "bigint", None),
    column("tip_quota", "bigint", None),
    column("owner_rating_score", "bigint", None),
    column("owner_rating_comment", "character varying", Some(1000)),
    column("owner_rated_at", "bigint", None),
    column("contributor_rating_score", "bigint", None),
    column(
        "contributor_rating_comment",
        "character varying",
        Some(1000),
    ),
    column("contributor_rated_at", "bigint", None),
    column("owner_rating_overturned", "boolean", None),
    column("accepted_at", "bigint", None),
    column("submitted_at", "bigint", None),
    column("reviewed_at", "bigint", None),
    column("rejected_at", "bigint", None),
    column("paid_at", "bigint", None),
    column("created_at", "bigint", None),
    column("updated_at", "bigint", None),
];

const LEDGER_COLUMNS: &[ColumnRequirement] = &[
    column("id", "bigint", None),
    column("project_id", "bigint", None),
    column("challenge_id", "bigint", None),
    column("user_id", "bigint", None),
    column("counterparty_user_id", "bigint", None),
    column("kind", "character varying", Some(32)),
    column("quota", "bigint", None),
    column("note", "character varying", Some(500)),
    nullable_column("reward_payout_key", "character varying", Some(64)),
    column("recipient_read_at", "bigint", None),
    column("thanked_at", "bigint", None),
    column("created_at", "bigint", None),
];

const DISPUTE_COLUMNS: &[ColumnRequirement] = &[
    column("id", "bigint", None),
    column("challenge_id", "bigint", None),
    column("project_id", "bigint", None),
    column("opened_by_user_id", "bigint", None),
    column("against_user_id", "bigint", None),
    column("case_key", "character varying", Some(96)),
    nullable_column("open_key", "character varying", Some(64)),
    column("reason", "character varying", Some(64)),
    column("statement", "text", None),
    column("project_title_snapshot", "character varying", Some(120)),
    column("repository_url_snapshot", "character varying", Some(512)),
    column("project_rules_snapshot", "text", None),
    column("project_escrow_quota_snapshot", "bigint", None),
    column("challenge_status_snapshot", "character varying", Some(20)),
    column("issue_url_snapshot", "character varying", Some(512)),
    column("pull_request_url_snapshot", "character varying", Some(512)),
    column("submission_note_snapshot", "text", None),
    column("review_note_snapshot", "text", None),
    column("reward_quota_snapshot", "bigint", None),
    column("tip_quota_snapshot", "bigint", None),
    column("owner_rating_score_snapshot", "bigint", None),
    column(
        "owner_rating_comment_snapshot",
        "character varying",
        Some(1000),
    ),
    column("contributor_rating_score_snapshot", "bigint", None),
    column(
        "contributor_rating_comment_snapshot",
        "character varying",
        Some(1000),
    ),
    column("status", "character varying", Some(32)),
    column("resolution", "text", None),
    column("resolved_by_user_id", "bigint", None),
    column("created_at", "bigint", None),
    column("updated_at", "bigint", None),
    column("resolved_at", "bigint", None),
];

const MCP_TOKEN_COLUMNS: &[ColumnRequirement] = &[
    column("id", "bigint", None),
    column("user_id", "bigint", None),
    column("token_hash", "character", Some(64)),
    column("token_hint", "character varying", Some(24)),
    column("created_at", "bigint", None),
    column("updated_at", "bigint", None),
    column("last_used_at", "bigint", None),
];

const MCP_CONFIRMATION_COLUMNS: &[ColumnRequirement] = &[
    column("id", "character varying", Some(80)),
    column("user_id", "bigint", None),
    column("tool_name", "character varying", Some(128)),
    column("payload_hash", "character", Some(64)),
    column("expires_at", "bigint", None),
    column("consumed_at", "bigint", None),
    column("created_at", "bigint", None),
];

const MCP_OPERATION_COLUMNS: &[ColumnRequirement] = &[
    column("id", "character varying", Some(80)),
    column("user_id", "bigint", None),
    column("tool_name", "character varying", Some(128)),
    column("payload_hash", "character", Some(64)),
    column("result_json", "text", None),
    column("created_at", "bigint", None),
];

const REST_OPERATION_COLUMNS: &[ColumnRequirement] = &[
    column("id", "bigint", None),
    column("user_id", "bigint", None),
    column("operation", "character varying", Some(64)),
    column("idempotency_key_hash", "character", Some(64)),
    column("payload_hash", "character", Some(64)),
    column("result_json", "text", None),
    column("created_at", "bigint", None),
    column("completed_at", "bigint", None),
];

const TABLES: &[(&str, &[ColumnRequirement])] = &[
    ("open_source_bounty_projects", PROJECT_COLUMNS),
    ("open_source_bounty_challenges", CHALLENGE_COLUMNS),
    ("open_source_bounty_ledgers", LEDGER_COLUMNS),
    ("open_source_bounty_disputes", DISPUTE_COLUMNS),
    ("open_source_bounty_mcp_tokens", MCP_TOKEN_COLUMNS),
    (
        "open_source_bounty_mcp_confirmations",
        MCP_CONFIRMATION_COLUMNS,
    ),
    ("open_source_bounty_mcp_operations", MCP_OPERATION_COLUMNS),
    ("open_source_bounty_rest_operations", REST_OPERATION_COLUMNS),
];

/// Verifies the table/column contract needed by the Rust bounty routes.
pub fn verify_open_source_bounty_schema(
    transaction: &mut Transaction<'_>,
    schema: &str,
) -> Result<(), MigrationError> {
    for &(table, columns) in TABLES {
        let table_exists: bool = transaction
            .query_one(
                "SELECT EXISTS (SELECT 1 FROM pg_catalog.pg_class c JOIN pg_catalog.pg_namespace n ON n.oid = c.relnamespace WHERE n.nspname = $1 AND c.relname = $2 AND c.relkind = 'r')",
                &[&schema, &table],
            )?
            .get(0);
        if !table_exists {
            return Err(MigrationError::Manifest(format!(
                "forward schema is missing table {table}"
            )));
        }
        for requirement in columns {
            let row = transaction.query_opt(
                "SELECT data_type, character_maximum_length, is_nullable FROM information_schema.columns WHERE table_schema = $1 AND table_name = $2 AND column_name = $3",
                &[&schema, &table, &requirement.name],
            )?.ok_or_else(|| {
                MigrationError::Manifest(format!(
                    "forward schema is missing column {table}.{}",
                    requirement.name
                ))
            })?;
            let data_type: String = row.get(0);
            let length: Option<i32> = row.get(1);
            let is_nullable: String = row.get(2);
            if data_type != requirement.data_type
                || length != requirement.character_maximum_length
                || (is_nullable == "YES") != requirement.nullable
            {
                return Err(MigrationError::Manifest(format!(
                    "forward schema column mismatch for {table}.{}",
                    requirement.name
                )));
            }
        }
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use std::fs;

    use super::*;

    #[test]
    fn contract_two_inventory_covers_every_mounted_bounty_table() {
        assert_eq!(TABLES.len(), 8);
        assert!(TABLES.iter().all(|(_, columns)| !columns.is_empty()));
        assert!(
            TABLES
                .iter()
                .flat_map(|(_, columns)| columns.iter())
                .any(|column| column.name == "reward_payout_key" && column.nullable)
        );
        assert!(
            TABLES
                .iter()
                .flat_map(|(_, columns)| columns.iter())
                .any(|column| column.name == "open_key" && column.nullable)
        );
    }

    #[test]
    fn contract_two_sql_is_schema_bound_and_lists_the_inventory() {
        let path = std::path::Path::new(env!("CARGO_MANIFEST_DIR"))
            .join("../../migrations/0002_open_source_bounty_schema.sql");
        let sql = fs::read_to_string(path).expect("read contract-2 migration");
        assert!(sql.contains("__LMM_APP_SCHEMA__"));
        assert!(!sql.contains("public."));
        for &(table, _) in TABLES {
            assert!(
                sql.contains(&format!("__LMM_APP_SCHEMA__.{table}")),
                "contract-2 SQL does not mention {table}"
            );
        }
    }
}
