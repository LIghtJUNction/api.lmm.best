#![deny(missing_docs)]
//! Core domain types. Business behavior moves here route-by-route.
/// Schema contract version understood by this binary.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct SchemaContractVersion(pub i64);
