# LMM deployment path map

The installed package has one public operator entry point: `/usr/bin/lmm-api`.
Use `lmm-api deploy ...` for deployment phases and `lmm-api serve` for the
systemd service. Do not document or invoke a source-tree deployment helper or
a second public CLI.

## Controller and package inputs

| Purpose | Current path or entry point |
| --- | --- |
| Go artifact | `apps/api-go/out/lmm-api` |
| Rust artifacts | `apps/api-rust/target/release/lmm-api-rs`, `lmm-db-migrate` |
| Frontend build | `apps/web/dist` |
| Local split-package builder | `packaging/local/lmm-api-split/build-local-package.sh` |
| Local package output | `packaging/local/lmm-api-split/out` by default |
| Persistent controller work | `${XDG_STATE_HOME:-$HOME/.local/state}/lmm-api/deploy-work/<deployment-id>` |
| Durable controller backups | `$HOME/backup/lmm-api/<verified-host>/<deployment-id>` |

The local split package installs frontend files at
`/usr/share/lmm-api/frontend-dist`. Deployment publishes immutable frontend
releases through the installed CLI transaction.

## Shared installed package layout

| Purpose | Current path |
| --- | --- |
| Launcher and public CLI | `/usr/bin/lmm-api` |
| Go backend | `/usr/lib/lmm-api/backends/go/lmm-api` |
| Rust backend and migrator | `/usr/lib/lmm-api/backends/rs/` |
| Backend selection | `/etc/lmm-api/backend.conf` |
| Application environment | `/etc/lmm-api/lmm-api.env` |
| systemd unit | `/usr/lib/systemd/system/lmm-api.service` |
| Runtime state | `/var/lib/lmm-api` via `StateDirectory=lmm-api` |
| Service port | `3000` |

The AUR matrix consists of one core package (`lmm-api-bin` or `lmm-api-git`)
and a Go and/or Rust provider package. Package installation does not
authorize starting, restarting, enabling, or switching a service. The service
unit invokes exactly `/usr/bin/lmm-api serve`.

## Production transaction

| Purpose | Current path or entry point |
| --- | --- |
| Controller entry point | `/usr/bin/lmm-api deploy production ...` |
| Target activator | Immutable payload under the marker-owned deployment workspace |
| Default SSH alias | `ArchDmit` |
| Required static hostname | `arch-dmit` |
| Target work root | `/var/lib/lmm-api-go/deploy-work/<deployment-id>` (the service-managed path resolves under `/var/lib/private/lmm-api-go`) |
| Target backup root | `/var/lib/lmm-api-go/deploy-backups/<deployment-id>` (the service-managed path resolves under `/var/lib/private/lmm-api-go`) |
| Off-host backup root | `/home/arch/.local/state/lmm-api-production-backups/<deployment-id>` on `ArchCzy` |
| Frontend release root | `/srv/lmm-api-frontend` |
| Frontend releases | `/srv/lmm-api-frontend/releases/<version>` |
| Active frontend | `/srv/lmm-api-frontend/current` |
| Backend service | `lmm-api.service` |

The supported phases are `preflight`, `inspect`, `build`, `package`,
`backup`, `watchdog`, `switch`, `confirm`, `rollback`, and `cleanup`. The
default is read-only preflight. Remote mutation requires explicit execution,
verified role/host identity, and current-turn authorization.

The transaction is marker-owned and persistent. Before a switch it requires
the role-appropriate target/controller/off-host backup set, checksum
verification, encrypted secret-bearing controller and off-host archives, and
a persistent ten-minute watchdog armed before switching. A switch ends in
`AWAITING_CONFIRMATION`; only exact-release identity checks and explicit
confirmation produce `CONFIRMED`. Automatic rollback never restores a
database.

## Existing database backups

`deploy/backup/backup-sqlite-to-archczy.sh` creates an online SQLite backup in
a temporary directory and publishes a checksum pair to
`/var/backups/lmm-api/sqlite/<instance>` on ArchCzy. It does not create a
controller copy. Inspect live configuration and fail closed on any disagreement
between the configured engine and the selected backup/deployment path.

The SQLite-to-PostgreSQL cutover remains a separate, explicitly authorized
maintenance operation. Do not infer production migration or Rust activation
from the presence of its scripts or artifacts.

## Rust internal-probe blue/green

| Purpose | Current path |
| --- | --- |
| Immutable releases | `/opt/lmm-api-rs/releases/<revision>` |
| Slot links | `/opt/lmm-api-rs/slots/{blue,green}/current` |
| Configuration | `/etc/lmm-api-rs` |
| Durable incoming artifacts | `/var/lib/lmm-api-rs/artifacts` |
| Deployment audit | `/var/log/lmm-api-rs/deployments/<transaction>` |
| Blue/green ports | `3100`, `3101` |
| Entrypoint | `deploy/backend-rust/deploy-lmm-api-rs.sh` |

This mechanism owns internal probes only, not production business traffic.

## Workspace and backup lifecycle

The controller workspace is a transaction workspace, not durable backup
storage. Keep its marker and terminal status for audit, but remove exact
`staging`, `tmp`, and cache children after `CONFIRMED` or `ROLLED_BACK` and
after the controller, target, and off-host copies have passed checksum and
decryption verification. Production target workspaces follow the same rule;
the target backup root and off-host root are durable and must not be removed
by workspace cleanup. Private directories are `0700`, manifests/status and
encrypted archives are `0600`, and no secret-bearing plaintext may leave the
target. Never use `/tmp`, `/var/tmp`, an unresolved glob, or a broad root as a
deployment or cleanup target.

On the small production root filesystem, stop new builds at 80% used (90% is
an emergency) and keep at least 4 GiB free before a package/backup
transaction. A terminal workspace older than 24 hours may be pruned oldest
first only after its durable copies and checksums are verified; retain the
active release, latest-known-good snapshot, and any unconfirmed transaction.

## Other retained deployment state

| Component | Backup or state root |
| --- | --- |
| nginx split installer | `/var/lib/lmm-api-nginx-deploy/backups` |
| fallback nginx installer | `/var/lib/lmm-api-rs-fallback-nginx/backups` |
| dedicated Valkey installer | `/var/lib/valkey-lmm-api-deploy/backups` |
| database cutover | `/var/lib/lmm-api-cutover`, `/var/log/lmm-api-cutover` |

These older mechanisms have independent retention. Do not broaden cleanup to
`/tmp`, backup roots, release roots, or another deployment's workspace.

## Temporary-path findings

Future deployment work must redirect task-specific caches, staging, manifests,
and logs into the marker-owned persistent work directory. Never use `/tmp` or
`/var/tmp` for deployment artifacts or cleanup targets, and never perform a
broad temporary-directory deletion.
