//! Deterministic conversion and hashing shared by copy and verification phases.

use chrono::{DateTime, NaiveDateTime, SecondsFormat, Utc};
use serde_json::Value;

use crate::MigrationError;

/// A typed canonical value. Type tags prevent cross-type hash collisions.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum CanonicalValue {
    Null,
    Bool(bool),
    Integer(i64),
    Decimal(String),
    Text(String),
    Json(String),
    Timestamp(String),
    Bytes(Vec<u8>),
}

impl CanonicalValue {
    fn tag(&self) -> u8 {
        match self {
            Self::Null => 0,
            Self::Bool(_) => 1,
            Self::Integer(_) => 2,
            Self::Decimal(_) => 3,
            Self::Text(_) => 4,
            Self::Json(_) => 5,
            Self::Timestamp(_) => 6,
            Self::Bytes(_) => 7,
        }
    }

    fn bytes(&self) -> std::borrow::Cow<'_, [u8]> {
        match self {
            Self::Null => std::borrow::Cow::Borrowed(&[]),
            Self::Bool(false) => std::borrow::Cow::Borrowed(b"0"),
            Self::Bool(true) => std::borrow::Cow::Borrowed(b"1"),
            Self::Integer(value) => std::borrow::Cow::Owned(value.to_be_bytes().to_vec()),
            Self::Decimal(value)
            | Self::Text(value)
            | Self::Json(value)
            | Self::Timestamp(value) => std::borrow::Cow::Borrowed(value.as_bytes()),
            Self::Bytes(value) => std::borrow::Cow::Borrowed(value),
        }
    }
}

/// Converts a SQLite numeric boolean, rejecting truthy values other than 0/1.
pub fn canonical_bool(value: Option<i64>) -> Result<CanonicalValue, MigrationError> {
    match value {
        None => Ok(CanonicalValue::Null),
        Some(0) => Ok(CanonicalValue::Bool(false)),
        Some(1) => Ok(CanonicalValue::Bool(true)),
        Some(other) => Err(MigrationError::Canonical(format!(
            "boolean integer must be 0 or 1, got {other}"
        ))),
    }
}

/// Parses JSON and emits compact, recursively key-sorted UTF-8.
pub fn canonical_json(value: Option<&str>) -> Result<CanonicalValue, MigrationError> {
    let Some(value) = value else {
        return Ok(CanonicalValue::Null);
    };
    let parsed: Value = serde_json::from_str(value)?;
    let sorted = sort_json(parsed);
    Ok(CanonicalValue::Json(serde_json::to_string(&sorted)?))
}

fn sort_json(value: Value) -> Value {
    match value {
        Value::Array(values) => Value::Array(values.into_iter().map(sort_json).collect()),
        Value::Object(values) => {
            let mut pairs: Vec<_> = values.into_iter().collect();
            pairs.sort_unstable_by(|left, right| left.0.cmp(&right.0));
            Value::Object(
                pairs
                    .into_iter()
                    .map(|(key, value)| (key, sort_json(value)))
                    .collect(),
            )
        }
        scalar => scalar,
    }
}

/// Parses supported GORM timestamp forms and emits UTC RFC 3339 with microseconds.
pub fn canonical_timestamp(value: Option<&str>) -> Result<CanonicalValue, MigrationError> {
    let Some(value) = value else {
        return Ok(CanonicalValue::Null);
    };
    let parsed = DateTime::parse_from_rfc3339(value)
        .map(|timestamp| timestamp.with_timezone(&Utc))
        .ok()
        .or_else(|| {
            DateTime::parse_from_str(value, "%Y-%m-%d %H:%M:%S%.f%:z")
                .map(|timestamp| timestamp.with_timezone(&Utc))
                .ok()
        })
        .or_else(|| {
            NaiveDateTime::parse_from_str(value, "%Y-%m-%d %H:%M:%S%.f")
                .map(|timestamp| timestamp.and_utc())
                .ok()
        })
        .ok_or_else(|| MigrationError::Canonical(format!("invalid GORM timestamp {value:?}")))?;
    Ok(CanonicalValue::Timestamp(
        parsed.to_rfc3339_opts(SecondsFormat::Micros, true),
    ))
}

/// Validates and normalizes a fixed-scale decimal without binary floating point.
pub fn canonical_decimal(
    value: Option<&str>,
    precision: usize,
    scale: usize,
) -> Result<CanonicalValue, MigrationError> {
    let Some(value) = value else {
        return Ok(CanonicalValue::Null);
    };
    let (negative, unsigned) = value
        .strip_prefix('-')
        .map_or((false, value), |rest| (true, rest));
    let (whole, fraction) = unsigned.split_once('.').unwrap_or((unsigned, ""));
    if whole.is_empty()
        || !whole.bytes().all(|byte| byte.is_ascii_digit())
        || !fraction.bytes().all(|byte| byte.is_ascii_digit())
        || fraction.len() > scale
    {
        return Err(MigrationError::Canonical(format!(
            "invalid decimal({precision},{scale}) value {value:?}"
        )));
    }
    let significant_whole = whole.trim_start_matches('0');
    if significant_whole.len() > precision.saturating_sub(scale) {
        return Err(MigrationError::Canonical(format!(
            "decimal({precision},{scale}) overflow for {value:?}"
        )));
    }
    let whole = if significant_whole.is_empty() {
        "0"
    } else {
        significant_whole
    };
    let mut normalized = String::with_capacity(value.len() + scale);
    if negative && (whole != "0" || fraction.bytes().any(|byte| byte != b'0')) {
        normalized.push('-');
    }
    normalized.push_str(whole);
    if scale > 0 {
        normalized.push('.');
        normalized.push_str(fraction);
        normalized.extend(std::iter::repeat_n('0', scale - fraction.len()));
    }
    Ok(CanonicalValue::Decimal(normalized))
}

/// Hashes a row with an unambiguous type-tag + big-endian-length encoding.
#[must_use]
pub fn row_hash(values: &[CanonicalValue]) -> blake3::Hash {
    let mut hasher = blake3::Hasher::new();
    hasher.update(b"lmm-db-row-v1\0");
    hasher.update(&(values.len() as u64).to_be_bytes());
    for value in values {
        let bytes = value.bytes();
        hasher.update(&[value.tag()]);
        hasher.update(&(bytes.len() as u64).to_be_bytes());
        hasher.update(&bytes);
    }
    hasher.finalize()
}

/// Hashes an ordered table as a versioned table/count/row-frame stream.
///
/// Callers must order rows lexicographically by every primary-key column in
/// declared primary-key position before invoking this function.
#[must_use]
pub fn table_hash<'a>(
    table: &str,
    rows: impl IntoIterator<Item = &'a [CanonicalValue]>,
) -> (u64, blake3::Hash) {
    let rows: Vec<_> = rows.into_iter().collect();
    let mut hasher = blake3::Hasher::new();
    hasher.update(b"lmm-db-table-v1\0");
    hasher.update(&(table.len() as u64).to_be_bytes());
    hasher.update(table.as_bytes());
    hasher.update(&(rows.len() as u64).to_be_bytes());
    for row in &rows {
        let hash = row_hash(row);
        hasher.update(&(hash.as_bytes().len() as u64).to_be_bytes());
        hasher.update(hash.as_bytes());
    }
    (rows.len() as u64, hasher.finalize())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn bool_should_reject_non_binary_integer() {
        assert!(canonical_bool(Some(2)).is_err());
    }

    #[test]
    fn json_should_sort_nested_object_keys() {
        assert_eq!(
            canonical_json(Some(r#"{"z":{"b":1,"a":2},"a":0}"#)).unwrap(),
            CanonicalValue::Json(r#"{"a":0,"z":{"a":2,"b":1}}"#.into())
        );
    }

    #[test]
    fn decimal_should_pad_to_declared_scale() {
        assert_eq!(
            canonical_decimal(Some("0012.3"), 10, 6).unwrap(),
            CanonicalValue::Decimal("12.300000".into())
        );
    }

    #[test]
    fn timestamp_should_normalize_offset_to_utc() {
        assert_eq!(
            canonical_timestamp(Some("2026-08-01T09:30:00+08:00")).unwrap(),
            CanonicalValue::Timestamp("2026-08-01T01:30:00.000000Z".into())
        );
    }

    #[test]
    fn row_hash_should_distinguish_null_empty_and_types() {
        let null = row_hash(&[CanonicalValue::Null]);
        let empty_text = row_hash(&[CanonicalValue::Text(String::new())]);
        let empty_bytes = row_hash(&[CanonicalValue::Bytes(Vec::new())]);
        assert_ne!(null, empty_text);
        assert_ne!(empty_text, empty_bytes);
    }

    #[test]
    fn row_hash_should_distinguish_field_boundaries() {
        let split = row_hash(&[
            CanonicalValue::Text("ab".into()),
            CanonicalValue::Text("c".into()),
        ]);
        let joined = row_hash(&[
            CanonicalValue::Text("a".into()),
            CanonicalValue::Text("bc".into()),
        ]);
        assert_ne!(split, joined);
    }

    #[test]
    fn row_hash_should_match_versioned_golden_vector() {
        let hash = row_hash(&[
            CanonicalValue::Null,
            CanonicalValue::Text(String::new()),
            CanonicalValue::Integer(42),
        ]);
        assert_eq!(
            hash.to_hex().as_str(),
            "fabef88f9a17b0f5531b0e20480164ca1f5513edecee703578ae73948aa16df3"
        );
    }

    #[test]
    fn table_hash_should_bind_domain_table_count_and_row_order() {
        let first = [CanonicalValue::Integer(1)];
        let second = [CanonicalValue::Integer(2)];
        let (_, forward) = table_hash("fixture", [&first[..], &second[..]]);
        let (_, reverse) = table_hash("fixture", [&second[..], &first[..]]);
        let (_, renamed) = table_hash("other", [&first[..], &second[..]]);
        let (_, shortened) = table_hash("fixture", [&first[..]]);

        assert_ne!(forward, reverse);
        assert_ne!(forward, renamed);
        assert_ne!(forward, shortened);
    }
}
