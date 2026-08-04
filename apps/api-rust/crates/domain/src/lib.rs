#![deny(missing_docs)]
//! Core domain types. Business behavior moves here route-by-route.
/// Schema contract version understood by this binary.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct SchemaContractVersion(pub i64);

/// Public, unauthenticated content exposed by the control-plane API.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum PublicContentKind {
    /// Operator-authored announcement content.
    Notice,
    /// Operator-authored about-page content.
    About,
    /// Operator-authored home-page content.
    HomePage,
}
