# Channel core migration oracle

Covered legacy surface: list, search, detail, add, update, delete, batch
delete, disabled deletion, copy, model lists, ability repair, multi-key
operations, and individual/batch status changes. Success and business failure
use the legacy HTTP-200 `{success,message,data?}` envelope, apart from the
captured unauthenticated 401 JSON contract. Writes commit PostgreSQL first and
then increment `lmm:channels:generation` in Valkey; a cache-bump failure is
returned to the caller for operator repair.

The core boundary validates provider configuration that is persisted by these
CRUD routes: JSON settings, New API base URLs, Vertex deployment regions, and
Codex credential objects. It does not own provider I/O. Provider test, balance,
model-discovery, Codex refresh, and upstream-model-update routes belong to the
separate channel-advanced slice.

Frozen compatibility details covered by unit/oracle tests include unknown
status values meaning "all", literal group matching with escaped SQL LIKE
metacharacters, type counts calculated before the requested type filter,
operation-only status updates, fail-closed authorization for sensitive or
unknown update fields, and action-specific multi-key error messages. PostgreSQL
row/advisory locks serialize multi-key mutations across Rust processes.

Two deliberate production hardenings are frozen as Rust-side differences. The
sensitive-write check is conservative on field presence (before any database
read), while the Go handler compares old and new values after loading the row.
Also, this slice exposes flat channel pagination; the legacy process-global
tag-mode presentation flag requires host configuration outside this module.
Tag mutation itself is fully owned by the channel-ops slice.

The real PostgreSQL/Valkey integration suite is deliberately ignored by normal
unit-test execution and requires both `LMM_CHANNEL_TEST_DATABASE_URL` and
`LMM_CHANNEL_TEST_VALKEY_URL`. Run the two channel integration binaries with
`-- --ignored --test-threads=1` against a disposable PostgreSQL 18 database and
dedicated Valkey instance. It never contacts a provider upstream.
