# Sanitized fallback test schema

`create-sanitized-test-schema.sh` creates a new versioned `lmm_test_*` schema
inside a separately pre-created `lmm_test_*` database, authenticated as a
dedicated non-superuser `lmm_test_*` role that owns that database. It refuses `public`, the verified
production snapshot namespace, and every existing schema. It does not connect
to SQLite, read another PostgreSQL schema, or copy business data.

Set `LMM_RS_TEST_INSTANCE=1` and pass `DATABASE_URL` only through the
environment. Supply the exact packaged manifest, baseline, catalog SQL,
contract migration, provenance, route oracle, two binaries, revision, and a
root-owned release-metadata JSON. The metadata binds all nine immutable ledger
components; the script re-hashes every file-backed component before creating
the schema and requires `contract_sha256` itself to equal the contract SQL
file hash. It installs the empty 34-table catalog, one contract and one
release-ledger entry, and six non-sensitive display/login options. It asserts
29 expected ID-owned sequences (supporting PostgreSQL `a` and identity `i`
dependencies) and rejects unexpected option keys.

The result deliberately has no users or `setups` row. Start Rust on loopback,
call `POST /api/setup` once with a newly generated test password over that
protected local path, then verify `/readyz` before enabling the fallback nginx
site. Use a separate empty Valkey instance and freshly generated session and
crypto secrets; never reuse production `common.env`.

## Optional signed login-fixture import

For dashboard parity testing where an operator needs to sign in as a selected
test account, use `import-sanitized-auth-snapshot.sh` **only after** this
empty-schema command has completed. It does not read a source database, SQL
dump, or production `DATABASE_URL`: its only source is a mode-`0600`, offline
TSV conforming to [sanitized-auth-snapshot-v1.tsv.schema](sanitized-auth-snapshot-v1.tsv.schema), plus a separate
mode-`0600` SHA-256 digest, detached OpenSSL signature, and strictly sorted
mode-`0600` user-ID allowlist. Verification requires an operator PEM public
key and fails closed if OpenSSL is unavailable or verification fails. Run it
as root on the test host; `DATABASE_URL` must authenticate as the dedicated,
non-privileged `lmm_test_*` role that owns the dedicated `lmm_test_*` database.

```bash
LMM_RS_TEST_INSTANCE=1 DATABASE_URL="$TEST_DATABASE_URL" \
  ./import-sanitized-auth-snapshot.sh \
  --schema lmm_test_runtime_v1 \
  --expected-database lmm_test_runtime \
  --expected-role lmm_test_runtime \
  --snapshot /root/lmm-test-fixtures/auth.tsv \
  --sha256 /root/lmm-test-fixtures/auth.tsv.sha256 \
  --signature /root/lmm-test-fixtures/auth.tsv.sig \
  --public-key /etc/lmm-api-rs-single/auth-snapshot-public.pem \
  --allow-user-ids /root/lmm-test-fixtures/allow-user-ids.txt
```

The importer only writes selected `users` columns required for password login
and a synthetic `setups` record. It sets every imported email to
`user-<id>@invalid.test`, clears PAT/access tokens, external IDs, Stripe IDs,
remarks, settings, and affiliation links, and asserts that 2FA/passkeys,
OAuth bindings, sessions, tokens, payments, logs, tasks, channels, and custom
providers are still empty. It applies test-only safe options that disable
registration, OAuth, Turnstile, payment configuration, and providers, then
sets the user and setup sequences. It never prints a password verifier,
digest, URL, signature, or secret.

The fallback release accepts only the directly built Arch package. Keep the
sanitized fixture assets and the package on the isolated test machine; no
release JSON, copied binary, revision argument, or production configuration is
accepted by the activation command.

```bash
PACKAGE=/srv/lmm-test-artifacts/lmm-api-rs-bin-0.1.0.r0123456789ab-1-x86_64.pkg.tar.zst
PACKAGE_SHA256=replace_with_the_sha256sum_of_that_exact_package

LMM_RS_TEST_INSTANCE=1 \
  /usr/lib/lmm-api-rs/deploy/deploy-lmm-api-rs-single-instance.sh \
  --package "$PACKAGE" --package-sha256 "$PACKAGE_SHA256" --activate
```

The installed package supplies `payload.sha256` and `source-manifest`; the
activation script rejects the package unless its installed binary, migrator,
revision, and manifests all verify. It only probes `127.0.0.1:3100` directly
and never changes nginx.
