# Isolated Rust single-instance test host

This path is only for the separately approved `fallback.lmm.best` test host.
It does not authorize routing, deployment, or configuration changes on
`api.lmm.best`.

The Arch package supplies two binaries, a frontend distribution, migration
rehearsal inputs, and the following explicit assets:

- `lmm-api-rs-single.service`, using `/opt/lmm-api-rs-single` and
  `/etc/lmm-api-rs-single` rather than the blue/green production-candidate
  paths;
- a test-only deploy script that requires `LMM_RS_TEST_INSTANCE=1` and only
  restarts the service with explicit `--activate`;
- the `fallback.lmm.best` nginx template, which is never installed or reloaded
  by package installation or the deploy script. Its accompanying
  `lmm-api-http-map.conf` and `lmm-api-mime.types` are installed beside the
  template and must be copied into nginx's `http` and server include paths by
  an explicit test-host operation;
- `test-instance.env.example` as the configuration entry for PostgreSQL and dedicated
  Valkey. Real DSNs and secrets must be created directly as mode-0600 test-host
  configuration and never committed or packaged. The test-only template also
  explicitly sets `PASSWORD_LOGIN_ENABLED=true`; the installer preserves an
  existing `common.env` but refuses to continue unless that exact setting is
  present, so an older file cannot silently disable dashboard password login.
- the reviewed dedicated-Valkey 6380 assets under
  `/usr/lib/lmm-api-rs/deploy/valkey`. This includes its loopback-only
  configuration, unit template, deployer, checker, and rollback test. Package
  installation does not invoke the deployer, enable or start the Valkey unit,
  or alter sysctl/tmpfiles state; those remain explicit test-host operations.

The fallback vhost intentionally sends dynamic requests to the single Rust
listener at `127.0.0.1:3100`. It is a test surface: incomplete route migration
must be treated as expected failures during parity testing, never as permission
to transfer `api.lmm.best` traffic.

Build after a clean checkpoint for a commit-bound artifact:

```bash
packaging/local/lmm-api-rs-fallback-bin/build-local-package.sh
```

For an explicitly labelled dirty test build, use a unique reviewed label:

```bash
packaging/local/lmm-api-rs-fallback-bin/build-local-package.sh \
  --revision test-<commit>-<scope>
```
