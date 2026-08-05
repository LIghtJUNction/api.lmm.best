# Dedicated Valkey for lmm-api

The target architecture uses a dedicated native Valkey instance for lmm-api. It is deliberately separate from the pre-existing `valkey.service` on `127.0.0.1:6379`; the deployment script refuses to proceed unless that listener exists and verifies that its unit state and PID did not change. Its presence does not mean production Go is already using it or that Rust traffic is enabled.

## Layout and resource policy

| Resource | Value |
| --- | --- |
| Unit | `valkey-lmm-api.service` |
| Listener | `127.0.0.1:6380` only |
| Configuration | `/etc/valkey/lmm-api.conf` (`0640 root:valkey`) |
| ACL | `/etc/valkey/lmm-api.acl` (`0640 root:valkey`) |
| Application environment | `/etc/lmm-api/valkey.env` (`0600 root:root`) |
| Persistent state | `/var/lib/valkey-lmm-api` |
| Cache memory | `64 MiB`, `noeviction` |
| Unit memory ceiling | `MemoryHigh=80M`, `MemoryMax=112M`, `MemorySwapMax=32M` |
| Persistence | AOF, `appendfsync everysec` |
| Kernel tuning | `vm.overcommit_memory=1`; THP `madvise` |

After the approved PostgreSQL 18 cutover, PostgreSQL is the sole persistent authority. Valkey accelerates shared sessions, revocation propagation, and rate limiting, and it holds security-sensitive revocation fences and rate-limit counters. The `noeviction` policy preserves that runtime security state under memory pressure; writes fail at the memory limit so security-sensitive callers can fail closed rather than silently resetting their state. Its AOF improves warm restarts but is not a database backup. The default user is disabled. The `lmm-api` ACL user may access keys and scripting but is denied Valkey's `@dangerous` command category. Protected mode and loopback binding provide independent network containment.

The project uses go-redis v8 and accepts the generated URL without modification:

```text
redis://lmm-api:<password>@127.0.0.1:6380/0
```

The password is a 256-bit random hexadecimal value. It is never printed by the deployer and exists only in the protected ACL and application environment files. Do not paste either file into logs or issue reports.

## Install and validate

Install the Arch `valkey` package first, then run from a reviewed repository checkout:

```bash
deploy/valkey/check-valkey-deployment.sh
sudo deploy/valkey/deploy-valkey-lmm-api.sh install
sudo deploy/valkey/deploy-valkey-lmm-api.sh health
```

`lmm-api-rs-bin` also carries these immutable inputs under
`/usr/lib/lmm-api-rs/deploy/valkey`, so a test host can validate the exact
packaged release before an explicit operation:

```bash
sudo /usr/lib/lmm-api-rs/deploy/valkey/check-valkey-deployment.sh
sudo /usr/lib/lmm-api-rs/deploy/valkey/deploy-valkey-lmm-api.sh install
```

Installing or upgrading the package only writes files below `/usr`; it never
invokes either command, enables or starts `valkey-lmm-api.service`, or changes
sysctl/tmpfiles state.

The install is idempotent: an existing generated credential is preserved, managed files are written via same-directory atomic rename, publishers are serialized with `flock`, systemd state directories are declarative, and every run atomically reserves a non-overwritable backup directory using a UTC timestamp, nanoseconds, and 64 bits of secure randomness. A failed install automatically restores those managed files, the exact prior active/enabled state of the dedicated unit, and the prior runtime kernel values. Restoration failures are reported separately from the original deployment failure; they are never silently swallowed. If the restored instance was active, the deployer repeats its authenticated health check. The script applies the checked-in sysctl/tmpfiles policy, requires `valkey-server --check-system` to pass, validates fixed security directives, starts the isolated unit, performs an authenticated PING, proves the application user cannot run `CONFIG`, and verifies both listener isolation and the untouched 6379 instance.

Valkey 9.1 does not expose a config-only parser. A configuration error therefore fails the isolated unit start; the existing 6379 service remains untouched and the retained backup provides recovery.

The kernel policy is global: `/etc/sysctl.d/70-valkey-lmm-api.conf` persists memory overcommit, while `/etc/tmpfiles.d/valkey-lmm-api.conf` writes `madvise` to the THP sysfs selector at boot. `madvise` avoids unconditional THP for Valkey without disabling THP for applications that explicitly request it. The transaction captures both previous runtime values with independently checked reads, validates their accepted domains, and atomically publishes the metadata before changing them. Rollback restores the previous files and writes the recorded runtime values back directly; it does not run `sysctl --system`, so unrelated sysctl configuration is never reapplied. Restore steps propagate status explicitly and stop at the first unsafe failure rather than relying on Bash `errexit`; a later successful command cannot hide an earlier error. Neither tuning operation restarts the existing instance on port 6379. Its PID, unit state, and listener are checked in an independent best-effort phase even when an earlier restore step fails; a primary restore error remains the transaction's reported status while any separate 6379 invariant failure is also logged.

## Connect lmm-api

Add this line to the lmm-api unit without copying the secret into the unit itself:

```ini
EnvironmentFile=/etc/lmm-api/valkey.env
```

Apply this only as part of the reviewed autonomous backend/database transaction. Restarting the sole Go process merely to attach Valkey would create an avoidable interruption. All concurrently active backend slots must use the same Valkey URL and `CRYPTO_SECRET`; otherwise they create separate rate-limit/session state.

As verified on 2026-08-01, the production Go environment does not yet define `REDIS_CONN_STRING`; its global API limiter is therefore process-local. Candidate Rust processes may use the dedicated 6380 instance only in isolation. Partial Go/Rust route ownership is blocked until the autonomous backend cutover attaches the serving backend to the same dedicated Valkey without relying on the initiating API/SSH connection. The same-date gate snapshot reports Go 356/356; use `apps/api-rust/tests/fixtures/routes/migration-gate.tsv` for the live ownership conclusion.

## Rollback

List retained backup identifiers, review the selected manifest, then restore it:

```bash
sudo ls -1 /var/lib/valkey-lmm-api-deploy/backups
sudo deploy/valkey/deploy-valkey-lmm-api.sh rollback 20260801T010203Z-123456789-a1b2c3d4e5f60708
```

Rollback stops the dedicated instance before atomically restoring each managed file and kernel-policy file to its previous presence or absence, restores the recorded runtime kernel values, reloads systemd, and restores the recorded active/enabled state exactly. Its recovery path intentionally does not require the current unit to be active or inactive, so a `failed`, `activating`, or otherwise unhealthy current instance cannot block rollback. Only the target backup's strictly validated state is restored. If the selected backup predates the dedicated unit, rollback stops it before removing the unit and its enablement link. It never changes or restarts `valkey.service`.
