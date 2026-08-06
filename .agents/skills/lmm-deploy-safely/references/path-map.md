# LMM deployment path map

Treat this as a map of current, separate mechanisms. It is not a claim that the
paths already form one unified deployment system.

## Controller and local package inputs

| Purpose | Current path or entry point |
| --- | --- |
| Go artifact | `apps/api-go/out/lmm-api` |
| Rust artifacts | `apps/api-rust/target/release/lmm-api-rs`, `lmm-db-migrate` |
| Frontend build | `apps/web/dist` |
| Local split-package builder | `packaging/local/lmm-api-split/build-local-package.sh` |
| Local package output | `packaging/local/lmm-api-split/out` by default |
| Persistent controller work | `${XDG_STATE_HOME:-$HOME/.local/state}/lmm-api/deploy-work` |
| Required controller backups | `$HOME/backup/lmm-api/<verified-host>/<deployment-id>` |

The local split package installs frontend files at
`/usr/share/lmm-api/frontend-dist`, but no current installer publishes that
directory into the nginx release root automatically.

## Shared installed package layout

| Purpose | Current path |
| --- | --- |
| Launcher | `/usr/bin/lmm-api` |
| Backend selector | `/usr/bin/lmm-api-select` |
| Go backend | `/usr/lib/lmm-api/backends/go/lmm-api` |
| Rust backend and migrator | `/usr/lib/lmm-api/backends/rs/` |
| Backend selection | `/etc/lmm-api/backend.conf` |
| Application environment | `/etc/lmm-api/lmm-api.env` |
| systemd unit | `/usr/lib/systemd/system/lmm-api.service` |
| Runtime state | `/var/lib/lmm-api` via `StateDirectory=lmm-api` |
| Service port | `3000` |

The AUR matrix consists of one core package (`lmm-api-bin` or `lmm-api-git`)
and a Go and/or Rust provider package. Package installation does not authorize
starting, restarting, enabling, or switching a service.

## Go production transaction

| Purpose | Current path or behavior |
| --- | --- |
| Controller entry point | `deploy/production/deploy-go.sh` |
| Target activator | `deploy/production/activate-go-release.sh` |
| Default SSH alias | `ArchDmit` |
| Required static hostname | `arch-dmit` |
| Target work root required by this skill | `/var/lib/lmm-api/deploy-work` |
| Existing target staging | `/var/lib/lmm-api/deploy-staging/<version>` |
| Existing target snapshots | `/var/lib/lmm-api/deploy-backups/<UTC>-<version>` |
| Frontend release root | `/srv/lmm-api-frontend` |
| Frontend releases | `/srv/lmm-api-frontend/releases/<version>` |
| Active frontend | `/srv/lmm-api-frontend/current` |
| Frontend publisher | `deploy/frontend-release.sh` |
| Backend service | `lmm-api.service` |

The current production controller uses `/tmp/lmm-api-production.*` and deletes
the locally downloaded rollback package on exit. The target snapshot includes
the old binary, configuration, package metadata, frontend identity, and a
PostgreSQL dump, but no controller or off-host copy is produced. The current
transaction also lacks a persistent ten-minute rollback watchdog and manual
confirmation state.

## Existing database backups

`deploy/backup/backup-sqlite-to-archczy.sh` creates an online SQLite backup in a
temporary directory, verifies it, and publishes a checksum pair to:

`/var/backups/lmm-api/sqlite/<instance>` on ArchCzy.

The default instance is `production`, and retention is three valid snapshots.
It does not create a controller copy. Its documentation describes SQLite as
production authority, while the Go production activator requires `SQL_DSN` and
`pg_dump`. Inspect the live configuration and fail on disagreement.

## Rust deployment layouts

### Internal-probe blue/green

| Purpose | Current path |
| --- | --- |
| Immutable releases | `/opt/lmm-api-rs/releases/<revision>` |
| Slot links | `/opt/lmm-api-rs/slots/{blue,green}/current` |
| Configuration | `/etc/lmm-api-rs` |
| Durable incoming artifacts | `/var/lib/lmm-api-rs/artifacts` |
| Deployment audit | `/var/log/lmm-api-rs/deployments/<transaction>` |
| Blue/green ports | `3100`, `3101` |
| Entrypoint | `deploy/backend-rust/deploy-lmm-api-rs.sh` |

This mechanism currently owns internal probes only, not production business
traffic.

### Isolated test instance

| Purpose | Current path |
| --- | --- |
| Release root | `/opt/lmm-api-rs-single` |
| Configuration | `/etc/lmm-api-rs-single` |
| State | `/var/lib/lmm-api-rs-single` |
| Unit | `lmm-api-rs-single.service` |
| Port | `3100` |

## Other retained deployment state

| Component | Backup or state root |
| --- | --- |
| nginx split installer | `/var/lib/lmm-api-nginx-deploy/backups` |
| fallback nginx installer | `/var/lib/lmm-api-rs-fallback-nginx/backups` |
| dedicated Valkey installer | `/var/lib/valkey-lmm-api-deploy/backups` |
| database cutover | `/var/lib/lmm-api-cutover`, `/var/log/lmm-api-cutover` |

The frontend keeps three HTML releases by default, while cumulative immutable
assets are not garbage-collected. Existing Go staging, Go snapshots, Rust
releases/artifacts/audits, nginx backups, and Valkey backups have no common
retention coordinator.

## Temporary-path findings

Most current scripts use `mktemp` with cleanup traps, but production build and
package scripts, backup scripts, several tests, and sanitized-import helpers
still default to `/tmp`. The Valkey deployer hard-codes
`/tmp/valkey-lmm-api.*`. Do not broaden cleanup to `/tmp`; future deployment
work must redirect task-specific caches and staging into the marker-owned
persistent work directory.
