-- Run through the platform migration owner before either application starts.
-- Expand/contract releases update this row only after N and N-1 are verified.
CREATE TABLE IF NOT EXISTS lmm_schema_contract (
    singleton BOOLEAN PRIMARY KEY DEFAULT TRUE CHECK (singleton),
    min_reader_version BIGINT NOT NULL,
    max_reader_version BIGINT NOT NULL,
    CHECK (min_reader_version > 0),
    CHECK (max_reader_version >= min_reader_version)
);

INSERT INTO lmm_schema_contract (singleton, min_reader_version, max_reader_version)
VALUES (TRUE, 1, 1)
ON CONFLICT (singleton) DO NOTHING;

