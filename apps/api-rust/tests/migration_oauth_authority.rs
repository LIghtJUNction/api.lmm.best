//! Cross-layer contract checks for the first-party OAuth authority.
//!
//! Stateful grant, replay, and API Key behavior is covered by the module tests
//! and the real PostgreSQL/Valkey listener gate. This test keeps route, schema,
//! and Nginx ownership from drifting independently.

use lmm_api_rs::migration_routes::oauth_authority::{OAuthAuthorityState, router};

const AUTHORITY_SOURCE: &str = include_str!("../src/migration_routes/oauth_authority.rs");
const AUTHORITY_MIGRATION: &str = include_str!("../migrations/0004_oauth_authority.sql");
const NGINX_LOCATIONS: &str = include_str!("../../../deploy/nginx/lmm-api-locations.conf");

#[test]
fn oauth_authority_router_is_a_single_composable_surface() {
    let build = |state: OAuthAuthorityState| router(state);
    assert_eq!(std::mem::size_of_val(&build), 0);
}

#[test]
fn oauth_protocol_and_resource_routes_share_one_authority_module() {
    for path in [
        "/.well-known/oauth-authorization-server",
        "/oauth/authorize",
        "/oauth/device/code",
        "/oauth/token",
        "/oauth/revoke",
        "/api/oauth/authorization/{request}",
        "/api/oauth/device",
        "/api/oauth/bootstrap/keys",
        "/api/oauth/bootstrap/keys/{id}/reveal",
    ] {
        assert!(
            AUTHORITY_SOURCE.contains(path),
            "missing OAuth authority route: {path}"
        );
    }
}

#[test]
fn oauth_schema_is_hmac_only_and_tracks_refresh_families() {
    for column in [
        "device_code_hash",
        "user_code_hash",
        "token_hash",
        "family_id",
        "consumed_at",
        "revoked_at",
    ] {
        assert!(
            AUTHORITY_MIGRATION.contains(column),
            "missing OAuth schema column: {column}"
        );
    }
    for forbidden in [
        "device_code TEXT",
        "user_code TEXT",
        "access_token TEXT",
        "refresh_token TEXT",
    ] {
        assert!(
            !AUTHORITY_MIGRATION.contains(forbidden),
            "OAuth schema must not persist raw secret column: {forbidden}"
        );
    }
}

#[test]
fn nginx_splits_protocol_endpoints_from_browser_pages() {
    for path in [
        "/.well-known/oauth-authorization-server",
        "/oauth/authorize",
        "/oauth/device/code",
        "/oauth/token",
        "/oauth/revoke",
    ] {
        assert!(
            NGINX_LOCATIONS.contains(&format!("location = {path}")),
            "protocol endpoint must be an exact backend location: {path}"
        );
    }
    assert!(NGINX_LOCATIONS.contains("location ^~ /oauth/ { try_files /index.html =404;"));
    assert!(!NGINX_LOCATIONS.contains("location = /oauth/consent {"));
    assert!(!NGINX_LOCATIONS.contains("location = /oauth/device {"));
}
