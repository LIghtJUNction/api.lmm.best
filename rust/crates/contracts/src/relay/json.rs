//! Recursive JSON leaf used only where provider contracts deliberately allow
//! arbitrary tool schemas, arguments, metadata, or annotations.

use std::collections::BTreeMap;

use serde::{Deserialize, Serialize};

/// A typed recursive JSON value for explicitly extensible protocol fields.
///
/// Relay envelopes are never represented by this type; only fields whose API
/// contract is itself arbitrary JSON use it.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(untagged)]
pub enum JsonData {
    Null,
    Bool(bool),
    Number(serde_json::Number),
    String(String),
    Array(Vec<Self>),
    Object(BTreeMap<String, Self>),
}

impl JsonData {
    pub(crate) fn compact_string(&self) -> Result<String, serde_json::Error> {
        match self {
            Self::String(value) => Ok(value.clone()),
            value => serde_json::to_string(value),
        }
    }
}
