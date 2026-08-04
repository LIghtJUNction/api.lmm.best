# Identity 2FA route contract

- `GET /api/user/2fa/status` returns enabled, lock, and unused recovery-code state.
- `POST /api/user/2fa/setup` replaces only a pending factor, produces a Base32 TOTP secret and four recovery codes, and persists only bcrypt recovery-code hashes.
- Enabling, disabling, or regenerating recovery codes increments `users.auth_version` in the same PostgreSQL transaction and publishes both existing Valkey version-fence keys.
- Disable accepts TOTP or a single-use recovery code. Regeneration requires TOTP. Invalid attempts advance the existing five-attempt lockout state.
- The parent router must install `Extension<Identity2FAActor>` after authentication and supply `SecuritySessionRotator`; this module intentionally does not duplicate bearer-token parsing or session-cookie issuance.
