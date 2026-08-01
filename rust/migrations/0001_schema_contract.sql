-- Installed only by lmm-db-migrate after application data and catalog verification.
-- The migrator replaces this token with a quoted, validated application schema.
CREATE TABLE IF NOT EXISTS __LMM_APP_SCHEMA__.lmm_schema_contract (
    singleton BOOLEAN PRIMARY KEY DEFAULT TRUE CHECK (singleton),
    contract_id BIGINT NOT NULL CHECK (contract_id > 0),
    contract_sha256 TEXT NOT NULL CHECK (contract_sha256 ~ '^[0-9a-f]{64}$'),
    min_reader_version BIGINT NOT NULL CHECK (min_reader_version > 0),
    max_reader_version BIGINT NOT NULL,
    min_writer_version BIGINT NOT NULL CHECK (min_writer_version > 0),
    max_writer_version BIGINT NOT NULL,
    CHECK (max_reader_version >= min_reader_version),
    CHECK (max_writer_version >= min_writer_version)
);

CREATE TABLE IF NOT EXISTS __LMM_APP_SCHEMA__.lmm_schema_release_ledger (
    release_id TEXT PRIMARY KEY CHECK (release_id ~ '^[A-Za-z0-9._+-]{1,128}$'),
    release_sha256 TEXT NOT NULL CHECK (release_sha256 ~ '^[0-9a-f]{64}$'),
    contract_id BIGINT NOT NULL CHECK (contract_id > 0),
    contract_sha256 TEXT NOT NULL CHECK (contract_sha256 ~ '^[0-9a-f]{64}$'),
    min_reader_version BIGINT NOT NULL CHECK (min_reader_version > 0),
    max_reader_version BIGINT NOT NULL,
    min_writer_version BIGINT NOT NULL CHECK (min_writer_version > 0),
    max_writer_version BIGINT NOT NULL,
    component_hashes JSONB NOT NULL CHECK (
        pg_catalog.jsonb_typeof(component_hashes) = 'object'
        AND component_hashes <> '{}'::jsonb
    ),
    installed_at TIMESTAMPTZ NOT NULL DEFAULT pg_catalog.transaction_timestamp(),
    CHECK (max_reader_version >= min_reader_version),
    CHECK (max_writer_version >= min_writer_version)
);
