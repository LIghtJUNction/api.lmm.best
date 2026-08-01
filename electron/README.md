# Electron embedded backend retirement

The Electron embedded-backend distribution is retired. It is not a supported deployment target and no release workflow publishes Electron installers.

The production backend is `lmm-api-rs`. It requires both of these externally managed services:

- PostgreSQL, configured through `DATABASE_URL`.
- Valkey, configured through `VALKEY_URL`.

It also requires the remaining Rust runtime settings, including `LMM_RS_LISTEN_ADDR`, `LMM_RS_SLOT`, and `LMM_SCHEMA_CONTRACT`. Use the Rust release bundle or the container deployment, then access the deployed web endpoint with a supported browser.

## Fail-closed behavior

`./build.sh` and every `npm run build*` command exit unsuccessfully. `main.js` only displays the retirement notice and exits. They never start a legacy backend, create a SQLite database, connect to Redis, or imply that PostgreSQL and Valkey are bundled locally.

The old desktop architecture depended on a backend that embedded the production web assets and owned a local SQLite database. The Rust service intentionally uses external PostgreSQL and Valkey, and the current Rust HTTP surface does not provide an equivalent safe self-contained desktop contract. Packaging remains disabled until a separately designed desktop architecture establishes those dependency, migration, upgrade, backup, and credential-management guarantees.
