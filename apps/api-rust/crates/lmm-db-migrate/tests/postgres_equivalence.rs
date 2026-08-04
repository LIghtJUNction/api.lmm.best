use std::{path::Path, process::Command};

use lmm_db_migrate::canonical::{
    CanonicalValue, canonical_bool, canonical_decimal, canonical_json, canonical_timestamp,
    table_hash,
};
use rusqlite::Connection;
use serde_json::Value;

const TABLE: &str = "migration_equivalence_fixture";

#[test]
#[ignore = "requires the native PostgreSQL cluster provided by rehearse-postgres.sh"]
fn sqlite_and_postgres_should_have_identical_canonical_table_hashes() {
    let socket = std::env::var("LMM_TEST_PG_SOCKET").expect("rehearsal socket is required");
    let port = std::env::var("LMM_TEST_PG_PORT").expect("rehearsal port is required");
    let database = std::env::var("LMM_TEST_PG_DATABASE").expect("rehearsal database is required");
    let directory = tempfile::tempdir().unwrap();
    let sqlite_path = directory.path().join("fixture.db");

    let sqlite_rows = sqlite_fixture(&sqlite_path);
    create_postgres_fixture(&socket, &port, &database);
    let postgres_rows = postgres_fixture_rows(&socket, &port, &database);

    let sqlite_evidence = table_hash(TABLE, sqlite_rows.iter().map(Vec::as_slice));
    let postgres_evidence = table_hash(TABLE, postgres_rows.iter().map(Vec::as_slice));

    assert_eq!(sqlite_evidence.0, 2);
    assert_eq!(sqlite_evidence, postgres_evidence);
    assert_eq!(
        sqlite_evidence.1.to_hex().as_str(),
        "ea352fd199b951db37fe86a389b4883736a8867483a715bbdf3c39cfe2471aee"
    );
    println!(
        "equivalence proof: table={TABLE} count={} blake3={}",
        sqlite_evidence.0, sqlite_evidence.1
    );
}

fn sqlite_fixture(path: &Path) -> Vec<Vec<CanonicalValue>> {
    let connection = Connection::open(path).unwrap();
    connection
        .execute_batch(
            r#"
            CREATE TABLE migration_equivalence_fixture (
                "group" TEXT NOT NULL,
                model TEXT NOT NULL,
                channel_id INTEGER NOT NULL,
                enabled NUMERIC,
                payload TEXT,
                occurred_at TEXT,
                amount TEXT,
                PRIMARY KEY ("group", model, channel_id)
            );
            INSERT INTO migration_equivalence_fixture VALUES
                ('beta', 'model-z', 9, 0, '{"list":[3,2,1],"a":0}',
                 '2026-08-01 01:30:00.123456', '-0.500000'),
                ('alpha', 'model-a', 2, 1, '{"z":{"b":1,"a":2},"a":0}',
                 '2026-08-01T09:30:00+08:00', '0012.3');
            "#,
        )
        .unwrap();

    let mut statement = connection
        .prepare(
            r#"SELECT "group", model, channel_id, enabled, payload, occurred_at, amount
               FROM migration_equivalence_fixture
               ORDER BY "group", model, channel_id"#,
        )
        .unwrap();
    statement
        .query_map([], |row| {
            Ok(vec![
                CanonicalValue::Text(row.get(0)?),
                CanonicalValue::Text(row.get(1)?),
                CanonicalValue::Integer(row.get(2)?),
                canonical_bool(row.get(3)?).unwrap(),
                canonical_json(row.get::<_, Option<String>>(4)?.as_deref()).unwrap(),
                canonical_timestamp(row.get::<_, Option<String>>(5)?.as_deref()).unwrap(),
                canonical_decimal(row.get::<_, Option<String>>(6)?.as_deref(), 10, 6).unwrap(),
            ])
        })
        .unwrap()
        .collect::<Result<Vec<_>, _>>()
        .unwrap()
}

fn create_postgres_fixture(socket: &str, port: &str, database: &str) {
    let sql = r#"
        CREATE TABLE migration_equivalence_fixture (
            "group" text NOT NULL,
            model text NOT NULL,
            channel_id bigint NOT NULL,
            enabled boolean,
            payload jsonb,
            occurred_at timestamp with time zone,
            amount numeric(10,6),
            PRIMARY KEY ("group", model, channel_id)
        );
        INSERT INTO migration_equivalence_fixture VALUES
            ('beta', 'model-z', 9, false, '{"a":0,"list":[3,2,1]}',
             '2026-08-01T01:30:00.123456Z', '-0.500000'),
            ('alpha', 'model-a', 2, true, '{"a":0,"z":{"a":2,"b":1}}',
             '2026-08-01T01:30:00Z', '12.300000');
    "#;
    run_psql(socket, port, database, &["-c", sql]);
}

fn postgres_fixture_rows(socket: &str, port: &str, database: &str) -> Vec<Vec<CanonicalValue>> {
    let query = r#"
        SELECT json_build_array(
            "group", model, channel_id, enabled,
            payload, to_char(occurred_at AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS.US"Z"'),
            amount::text
        )
        FROM migration_equivalence_fixture
        ORDER BY "group", model, channel_id
    "#;
    let output = run_psql(socket, port, database, &["-At", "-c", query]);
    output
        .lines()
        .filter(|line| !line.is_empty())
        .map(|line| {
            let values: Vec<Value> = serde_json::from_str(line).unwrap();
            vec![
                CanonicalValue::Text(json_string(&values[0])),
                CanonicalValue::Text(json_string(&values[1])),
                CanonicalValue::Integer(values[2].as_i64().unwrap()),
                CanonicalValue::Bool(values[3].as_bool().unwrap()),
                canonical_json(Some(&values[4].to_string())).unwrap(),
                canonical_timestamp(Some(&json_string(&values[5]))).unwrap(),
                canonical_decimal(Some(&json_string(&values[6])), 10, 6).unwrap(),
            ]
        })
        .collect()
}

fn json_string(value: &Value) -> String {
    value.as_str().unwrap().to_owned()
}

fn run_psql(socket: &str, port: &str, database: &str, arguments: &[&str]) -> String {
    let output = Command::new("psql")
        .args(["-X", "-v", "ON_ERROR_STOP=1", "-h", socket, "-p", port])
        .args(["-U", "postgres", "-d", database])
        .args(arguments)
        .output()
        .unwrap();
    assert!(
        output.status.success(),
        "psql failed: {}",
        String::from_utf8_lossy(&output.stderr)
    );
    String::from_utf8(output.stdout).unwrap()
}
