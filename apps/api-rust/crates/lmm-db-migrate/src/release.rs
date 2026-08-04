//! Validated release and schema-contract identities used by migration transactions.

use std::{collections::BTreeMap, fmt, num::NonZeroU64, str::FromStr};

use serde::Serialize;
use thiserror::Error;

/// Complete set of immutable artifacts that every release ledger entry must bind.
///
/// Unknown names are rejected as well as missing names so an operator cannot accidentally create
/// an incomplete or ambiguous release identity.
pub const MANDATORY_COMPONENT_NAMES: &[&str] = &[
    "api-server-binary",
    "api-server-revision",
    "db-migrator-binary",
    "postgresql-baseline",
    "table-manifest",
    "postgres-catalog-exporter",
    "platform-contract-sql",
    "migration-provenance",
    "legacy-route-oracle",
];

/// Invalid release metadata that must be rejected before PostgreSQL is mutated.
#[derive(Debug, Error, PartialEq, Eq)]
pub enum ReleaseBindingError {
    /// An identifier is empty, too long, or contains unsafe characters.
    #[error("{field} is not a valid identifier")]
    InvalidIdentifier {
        /// Stable field name suitable for a non-sensitive audit message.
        field: &'static str,
    },
    /// A SHA-256 digest is not exactly 64 lowercase hexadecimal characters.
    #[error("{field} must be a lowercase SHA-256 digest")]
    InvalidSha256 {
        /// Stable field name suitable for a non-sensitive audit message.
        field: &'static str,
    },
    /// A compatibility version is zero or cannot be represented by PostgreSQL `BIGINT`.
    #[error("{field} must be in 1..=i64::MAX")]
    InvalidVersion {
        /// Stable field name suitable for a non-sensitive audit message.
        field: &'static str,
    },
    /// A compatibility range has its upper bound below its lower bound.
    #[error("{field} compatibility range is inverted")]
    InvertedRange {
        /// Stable field name suitable for a non-sensitive audit message.
        field: &'static str,
    },
    /// A release binding omitted an immutable component required by the release contract.
    #[error("release binding is missing mandatory component {component}")]
    MissingComponent {
        /// Stable mandatory component name.
        component: &'static str,
    },
    /// A release binding supplied a component outside the closed mandatory set.
    #[error("release binding contains an unknown component")]
    UnknownComponent,
    /// Two component arguments use the same component identifier.
    #[error("duplicate component identifier")]
    DuplicateComponent,
    /// A component argument does not use the required `name=sha256` format.
    #[error("component hash must use name=sha256")]
    InvalidComponentArgument,
}

/// Positive schema or compatibility version representable by PostgreSQL `BIGINT`.
#[derive(Clone, Copy, Debug, Eq, Ord, PartialEq, PartialOrd, Serialize)]
#[serde(transparent)]
pub struct Version(NonZeroU64);

impl Version {
    /// Creates a validated positive version.
    ///
    /// # Errors
    ///
    /// Returns [`ReleaseBindingError::InvalidVersion`] for zero or values above `i64::MAX`.
    pub fn new(value: u64, field: &'static str) -> Result<Self, ReleaseBindingError> {
        let value = NonZeroU64::new(value)
            .filter(|value| value.get() <= i64::MAX as u64)
            .ok_or(ReleaseBindingError::InvalidVersion { field })?;
        Ok(Self(value))
    }

    /// Returns the version as the PostgreSQL representation used by the ledger.
    #[must_use]
    pub fn as_i64(self) -> i64 {
        self.0.get() as i64
    }
}

impl FromStr for Version {
    type Err = ReleaseBindingError;

    fn from_str(value: &str) -> Result<Self, Self::Err> {
        Self::new(
            value
                .parse()
                .map_err(|_| ReleaseBindingError::InvalidVersion { field: "version" })?,
            "version",
        )
    }
}

/// Inclusive compatibility interval for readers or writers.
#[derive(Clone, Copy, Debug, Eq, PartialEq, Serialize)]
pub struct CompatibilityRange {
    minimum: Version,
    maximum: Version,
}

impl CompatibilityRange {
    /// Creates an inclusive compatibility interval.
    ///
    /// # Errors
    ///
    /// Returns [`ReleaseBindingError::InvertedRange`] when `maximum < minimum`.
    pub fn new(
        minimum: Version,
        maximum: Version,
        field: &'static str,
    ) -> Result<Self, ReleaseBindingError> {
        if maximum < minimum {
            return Err(ReleaseBindingError::InvertedRange { field });
        }
        Ok(Self { minimum, maximum })
    }

    /// Returns the inclusive lower bound.
    #[must_use]
    pub const fn minimum(self) -> Version {
        self.minimum
    }

    /// Returns the inclusive upper bound.
    #[must_use]
    pub const fn maximum(self) -> Version {
        self.maximum
    }
}

/// Lowercase hexadecimal SHA-256 digest.
#[derive(Clone, Debug, Eq, Ord, PartialEq, PartialOrd, Serialize)]
#[serde(transparent)]
pub struct Sha256Digest(String);

impl Sha256Digest {
    /// Parses a digest while associating failures with a stable field name.
    ///
    /// # Errors
    ///
    /// Returns [`ReleaseBindingError::InvalidSha256`] unless the input is exactly 64 lowercase
    /// hexadecimal characters.
    pub fn parse(value: &str, field: &'static str) -> Result<Self, ReleaseBindingError> {
        if value.len() != 64
            || !value
                .bytes()
                .all(|byte| byte.is_ascii_digit() || (b'a'..=b'f').contains(&byte))
        {
            return Err(ReleaseBindingError::InvalidSha256 { field });
        }
        Ok(Self(value.to_owned()))
    }

    /// Returns the canonical lowercase hexadecimal representation.
    #[must_use]
    pub fn as_str(&self) -> &str {
        &self.0
    }
}

impl fmt::Display for Sha256Digest {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter.write_str(&self.0)
    }
}

impl FromStr for Sha256Digest {
    type Err = ReleaseBindingError;

    fn from_str(value: &str) -> Result<Self, Self::Err> {
        Self::parse(value, "sha256")
    }
}

/// Stable release identifier.
#[derive(Clone, Debug, Eq, PartialEq, Serialize)]
#[serde(transparent)]
pub struct ReleaseId(String);

impl ReleaseId {
    /// Returns the validated identifier.
    #[must_use]
    pub fn as_str(&self) -> &str {
        &self.0
    }
}

impl FromStr for ReleaseId {
    type Err = ReleaseBindingError;

    fn from_str(value: &str) -> Result<Self, Self::Err> {
        if !valid_identifier(value, 128) {
            return Err(ReleaseBindingError::InvalidIdentifier {
                field: "release_id",
            });
        }
        Ok(Self(value.to_owned()))
    }
}

/// One immutable release component and its content digest.
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct ComponentHash {
    name: String,
    sha256: Sha256Digest,
}

impl ComponentHash {
    /// Returns the stable component name.
    #[must_use]
    pub fn name(&self) -> &str {
        &self.name
    }

    /// Returns the component content digest.
    #[must_use]
    pub const fn sha256(&self) -> &Sha256Digest {
        &self.sha256
    }
}

impl FromStr for ComponentHash {
    type Err = ReleaseBindingError;

    fn from_str(value: &str) -> Result<Self, Self::Err> {
        let (name, sha256) = value
            .split_once('=')
            .ok_or(ReleaseBindingError::InvalidComponentArgument)?;
        if !valid_identifier(name, 64) {
            return Err(ReleaseBindingError::InvalidIdentifier {
                field: "component_name",
            });
        }
        Ok(Self {
            name: name.to_owned(),
            sha256: Sha256Digest::parse(sha256, "component_sha256")?,
        })
    }
}

/// Immutable schema, compatibility, release, and component identity installed by a migration.
#[derive(Clone, Debug, Eq, PartialEq, Serialize)]
pub struct ReleaseBinding {
    contract_id: Version,
    contract_sha256: Sha256Digest,
    readers: CompatibilityRange,
    writers: CompatibilityRange,
    release_id: ReleaseId,
    release_sha256: Sha256Digest,
    components: BTreeMap<String, Sha256Digest>,
}

impl ReleaseBinding {
    /// Creates a complete release binding, rejecting missing, unknown, or duplicate components.
    ///
    /// # Errors
    ///
    /// Returns [`ReleaseBindingError`] when component metadata is absent or ambiguous.
    pub fn new(
        contract_id: Version,
        contract_sha256: Sha256Digest,
        readers: CompatibilityRange,
        writers: CompatibilityRange,
        release_id: ReleaseId,
        release_sha256: Sha256Digest,
        components: impl IntoIterator<Item = ComponentHash>,
    ) -> Result<Self, ReleaseBindingError> {
        let mut indexed = BTreeMap::new();
        for component in components {
            if !MANDATORY_COMPONENT_NAMES.contains(&component.name.as_str()) {
                return Err(ReleaseBindingError::UnknownComponent);
            }
            if indexed.insert(component.name, component.sha256).is_some() {
                return Err(ReleaseBindingError::DuplicateComponent);
            }
        }
        for &component in MANDATORY_COMPONENT_NAMES {
            if !indexed.contains_key(component) {
                return Err(ReleaseBindingError::MissingComponent { component });
            }
        }
        Ok(Self {
            contract_id,
            contract_sha256,
            readers,
            writers,
            release_id,
            release_sha256,
            components: indexed,
        })
    }

    /// Returns the schema-contract version.
    #[must_use]
    pub const fn contract_id(&self) -> Version {
        self.contract_id
    }

    /// Returns the digest of the exact schema-contract SQL artifact.
    #[must_use]
    pub const fn contract_sha256(&self) -> &Sha256Digest {
        &self.contract_sha256
    }

    /// Returns the supported reader compatibility interval.
    #[must_use]
    pub const fn readers(&self) -> CompatibilityRange {
        self.readers
    }

    /// Returns the supported writer compatibility interval.
    #[must_use]
    pub const fn writers(&self) -> CompatibilityRange {
        self.writers
    }

    /// Returns the stable release identifier.
    #[must_use]
    pub const fn release_id(&self) -> &ReleaseId {
        &self.release_id
    }

    /// Returns the release artifact digest.
    #[must_use]
    pub const fn release_sha256(&self) -> &Sha256Digest {
        &self.release_sha256
    }

    /// Returns component hashes in canonical name order.
    #[must_use]
    pub const fn components(&self) -> &BTreeMap<String, Sha256Digest> {
        &self.components
    }

    /// Returns component hashes as a canonical JSON object for PostgreSQL `jsonb` storage.
    pub(crate) fn component_json(&self) -> serde_json::Value {
        serde_json::Value::Object(
            self.components
                .iter()
                .map(|(name, digest)| {
                    (
                        name.clone(),
                        serde_json::Value::String(digest.as_str().to_owned()),
                    )
                })
                .collect(),
        )
    }
}

fn valid_identifier(value: &str, maximum_length: usize) -> bool {
    !value.is_empty()
        && value.len() <= maximum_length
        && value
            .bytes()
            .all(|byte| byte.is_ascii_alphanumeric() || matches!(byte, b'.' | b'_' | b'+' | b'-'))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn sha256_should_reject_uppercase_and_wrong_length() {
        assert!(Sha256Digest::parse(&"a".repeat(64), "test").is_ok());
        assert!(Sha256Digest::parse(&"A".repeat(64), "test").is_err());
        assert!(Sha256Digest::parse(&"a".repeat(63), "test").is_err());
    }

    #[test]
    fn release_binding_should_reject_duplicate_components() {
        let component = format!("api-server-binary={}", "a".repeat(64));
        let result = ReleaseBinding::new(
            Version::new(1, "contract_id").expect("valid version"),
            Sha256Digest::parse(&"b".repeat(64), "contract").expect("valid hash"),
            CompatibilityRange::new(
                Version::new(1, "reader").expect("valid version"),
                Version::new(1, "reader").expect("valid version"),
                "reader",
            )
            .expect("valid range"),
            CompatibilityRange::new(
                Version::new(1, "writer").expect("valid version"),
                Version::new(1, "writer").expect("valid version"),
                "writer",
            )
            .expect("valid range"),
            "release-1".parse().expect("valid release"),
            Sha256Digest::parse(&"c".repeat(64), "release").expect("valid hash"),
            [
                component.parse().expect("valid component"),
                component.parse().expect("valid component"),
            ],
        );
        assert_eq!(result.unwrap_err(), ReleaseBindingError::DuplicateComponent);
    }
}
