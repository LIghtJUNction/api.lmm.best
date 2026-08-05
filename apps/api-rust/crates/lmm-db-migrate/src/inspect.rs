//! Offline-only SQLite inspection with exact catalog drift detection.

use std::{
    collections::BTreeSet,
    ffi::OsString,
    fs::{self, File},
    io::Read,
    path::{Path, PathBuf},
};

use rusqlite::{Connection, OpenFlags, OptionalExtension};
use serde::Serialize;

use crate::{
    MigrationError,
    manifest::{Manifest, SqliteIndex, Table},
};

/// Non-sensitive inspection evidence. It intentionally contains no row values.
#[derive(Debug, Serialize)]
pub struct Inspection {
    pub sqlite_header_valid: bool,
    pub quick_check: String,
    pub tables: Vec<TableInspection>,
    pub drift: Vec<String>,
}

/// Table metadata and count without any row content.
#[derive(Debug, Serialize)]
pub struct TableInspection {
    pub name: String,
    pub row_count: u64,
    pub columns: Vec<SqliteColumn>,
    pub indexes: Vec<SqliteIndex>,
}

/// Exact source-column metadata returned by `PRAGMA table_xinfo`.
#[derive(Debug, PartialEq, Eq, Serialize)]
pub struct SqliteColumn {
    pub name: String,
    pub sqlite_type: String,
    pub sqlite_not_null: bool,
    pub sqlite_default: Option<String>,
    pub pk_position: u32,
}

/// Opens a canonical regular SQLite file through an immutable read-only URI.
///
/// Existing `-wal`, `-journal`, or `-shm` sidecars are always rejected. This
/// command deliberately has no live-database override.
pub fn inspect_sqlite(path: &Path, manifest: &Manifest) -> Result<Inspection, MigrationError> {
    let canonical = validate_offline_source(path)?;
    let mut header = [0_u8; 16];
    File::open(&canonical)?.read_exact(&mut header)?;
    let sqlite_header_valid = &header == b"SQLite format 3\0";
    if !sqlite_header_valid {
        return Err(MigrationError::Manifest(
            "source does not have a valid SQLite header".into(),
        ));
    }

    let uri = sqlite_uri(&canonical)?;
    let connection = Connection::open_with_flags(
        uri,
        OpenFlags::SQLITE_OPEN_READ_ONLY
            | OpenFlags::SQLITE_OPEN_URI
            | OpenFlags::SQLITE_OPEN_NO_MUTEX,
    )?;
    connection.execute_batch("PRAGMA query_only = ON")?;
    let query_only: i64 = connection.query_row("PRAGMA query_only", [], |row| row.get(0))?;
    if query_only != 1 {
        return Err(MigrationError::Manifest(
            "SQLite query_only mode was not established".into(),
        ));
    }
    let quick_check: String = connection.query_row("PRAGMA quick_check", [], |row| row.get(0))?;
    if quick_check != "ok" {
        return Err(MigrationError::Manifest(format!(
            "SQLite quick_check returned {quick_check:?}"
        )));
    }

    let actual_tables = table_names(&connection)?;
    let expected_tables: BTreeSet<_> = manifest
        .tables
        .iter()
        .map(|table| table.name.clone())
        .collect();
    let mut drift = Vec::new();
    for missing in expected_tables.difference(&actual_tables) {
        drift.push(format!("missing table: {missing}"));
    }
    for unexpected in actual_tables.difference(&expected_tables) {
        drift.push(format!("unexpected table: {unexpected}"));
    }

    let mut tables = Vec::with_capacity(manifest.tables.len());
    for expected in &manifest.tables {
        if !actual_tables.contains(&expected.name) {
            continue;
        }
        let actual = inspect_table(&connection, &expected.name)?;
        compare_source_contract(expected, &actual, &mut drift);
        tables.push(actual);
    }
    validate_sidecars_absent(&canonical)?;

    Ok(Inspection {
        sqlite_header_valid,
        quick_check,
        tables,
        drift,
    })
}

fn validate_offline_source(path: &Path) -> Result<PathBuf, MigrationError> {
    let metadata = fs::symlink_metadata(path)?;
    if metadata.file_type().is_symlink() || !metadata.file_type().is_file() {
        return Err(MigrationError::Manifest(
            "SQLite source must be a regular file, not a symlink or special file".into(),
        ));
    }
    let canonical = fs::canonicalize(path)?;
    validate_sidecars_absent(&canonical)?;
    Ok(canonical)
}

fn validate_sidecars_absent(path: &Path) -> Result<(), MigrationError> {
    for suffix in ["-wal", "-journal", "-shm"] {
        let mut sidecar: OsString = path.as_os_str().to_owned();
        sidecar.push(suffix);
        if fs::symlink_metadata(Path::new(&sidecar)).is_ok() {
            return Err(MigrationError::Manifest(format!(
                "SQLite sidecar exists; refusing potentially live source: {suffix}"
            )));
        }
    }
    Ok(())
}

fn sqlite_uri(path: &Path) -> Result<String, MigrationError> {
    let path = path.to_str().ok_or_else(|| {
        MigrationError::Manifest("SQLite canonical path is not valid UTF-8".into())
    })?;
    let mut encoded = String::with_capacity(path.len());
    for byte in path.bytes() {
        if byte.is_ascii_alphanumeric() || matches!(byte, b'/' | b'-' | b'_' | b'.' | b'~') {
            encoded.push(char::from(byte));
        } else {
            encoded.push_str(&format!("%{byte:02X}"));
        }
    }
    Ok(format!("file:{encoded}?mode=ro&immutable=1"))
}

fn compare_source_contract(expected: &Table, actual: &TableInspection, drift: &mut Vec<String>) {
    let expected_columns: Vec<_> = expected
        .columns
        .iter()
        .map(|column| SqliteColumn {
            name: column.name.clone(),
            sqlite_type: column.sqlite_type.clone(),
            sqlite_not_null: column.sqlite_not_null,
            sqlite_default: column.sqlite_default.clone(),
            pk_position: column.pk_position,
        })
        .collect();
    if actual.columns != expected_columns {
        drift.push(format!(
            "column/type/null/default/primary-key drift: {}",
            expected.name
        ));
    }
    let mut indexes = actual.indexes.clone();
    indexes.sort();
    let mut expected_indexes = expected.sqlite_indexes.clone();
    expected_indexes.sort();
    if indexes != expected_indexes {
        drift.push(format!("index shape drift: {}", expected.name));
    }
}

fn table_names(connection: &Connection) -> Result<BTreeSet<String>, rusqlite::Error> {
    let mut statement = connection.prepare(
        "SELECT name FROM sqlite_schema WHERE type='table' AND name NOT LIKE 'sqlite_%' ORDER BY name",
    )?;
    statement.query_map([], |row| row.get(0))?.collect()
}

fn inspect_table(connection: &Connection, name: &str) -> Result<TableInspection, MigrationError> {
    let quoted = quote_identifier(name);
    let row_count: i64 =
        connection.query_row(&format!("SELECT count(*) FROM {quoted}"), [], |row| {
            row.get(0)
        })?;
    let row_count = u64::try_from(row_count)
        .map_err(|_| MigrationError::Manifest(format!("negative row count for {name}")))?;

    let mut column_statement = connection.prepare(&format!("PRAGMA table_xinfo({quoted})"))?;
    let columns = column_statement
        .query_map([], |row| {
            Ok(SqliteColumn {
                name: row.get(1)?,
                sqlite_type: row.get::<_, String>(2)?.to_lowercase(),
                sqlite_not_null: row.get::<_, u8>(3)? != 0,
                sqlite_default: row.get(4)?,
                pk_position: row.get(5)?,
            })
        })?
        .collect::<Result<Vec<_>, _>>()?;

    let mut index_statement = connection.prepare(&format!("PRAGMA index_list({quoted})"))?;
    let index_headers = index_statement
        .query_map([], |row| {
            Ok((row.get::<_, String>(1)?, row.get::<_, u8>(2)? != 0))
        })?
        .collect::<Result<Vec<_>, _>>()?;
    let mut indexes = Vec::with_capacity(index_headers.len());
    for (index_name, unique) in index_headers {
        let index_quoted = quote_identifier(&index_name);
        let mut keys_statement =
            connection.prepare(&format!("PRAGMA index_xinfo({index_quoted})"))?;
        let columns = keys_statement
            .query_map([], |row| {
                Ok((row.get::<_, Option<String>>(2)?, row.get::<_, u8>(5)? != 0))
            })?
            .filter_map(|result| match result {
                Ok((Some(column), true)) => Some(Ok(column)),
                Ok(_) => None,
                Err(error) => Some(Err(error)),
            })
            .collect::<Result<Vec<_>, _>>()?;
        let sql: Option<String> = connection
            .query_row(
                "SELECT sql FROM sqlite_schema WHERE type='index' AND name=?1",
                [&index_name],
                |row| row.get(0),
            )
            .optional()?
            .flatten();
        let predicate = sql.and_then(|sql| {
            let uppercase = sql.to_uppercase();
            uppercase
                .find(" WHERE ")
                .map(|position| sql[position + 7..].trim().to_owned())
        });
        indexes.push(SqliteIndex {
            name: index_name,
            unique,
            columns,
            predicate,
        });
    }

    Ok(TableInspection {
        name: name.to_owned(),
        row_count,
        columns,
        indexes,
    })
}

fn quote_identifier(identifier: &str) -> String {
    format!("\"{}\"", identifier.replace('"', "\"\""))
}

#[cfg(all(test, unix))]
mod tests {
    use super::*;

    #[cfg(unix)]
    #[test]
    fn inspect_should_reject_symlink_source_and_each_sidecar() {
        use std::os::unix::fs::symlink;

        let directory = tempfile::tempdir().unwrap();
        let source = directory.path().join("source.db");
        Connection::open(&source).unwrap().close().unwrap();
        let link = directory.path().join("source-link.db");
        symlink(&source, &link).unwrap();
        assert!(validate_offline_source(&link).is_err());
        for suffix in ["-wal", "-journal", "-shm"] {
            let sidecar = directory.path().join(format!("source.db{suffix}"));
            File::create(&sidecar).unwrap();
            assert!(validate_offline_source(&source).is_err());
            fs::remove_file(sidecar).unwrap();
        }
    }
}
