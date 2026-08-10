---
name: lmm-deploy-safely
description: Safely inspect, stage, back up, deploy, update, confirm, roll back, or clean up this LMM repository across the local Arch workstation, isolated test hosts, and production. Use for local installation, production updates, AUR or paru packaging, systemd service changes, backup verification, release promotion, rollback timers, or deployment cleanup. Defaults to local-only work and requires explicit current-turn authorization plus exact host and role verification for test or production mutations.
---

# LMM Safe Deployment

Apply one controlled deployment transaction. Do not infer production authority
from an earlier turn, a generic request to “update,” or access to an SSH host.
The installed package exposes one public operator CLI, `/usr/bin/lmm-api`:
use `lmm-api deploy ...` for deployment phases and `lmm-api serve` for the
systemd service. Do not invoke a source-tree deployment helper or document a
second public deploy command.

## Read the deployment map

Read [references/path-map.md](references/path-map.md) before choosing a build,
package, service, frontend, database, or rollback path. Read
[references/safety-contract.md](references/safety-contract.md) before any
mutation, backup, retention, confirmation, rollback, or cleanup operation.

Use the canonical installed CLI transaction and its immutable package payloads.
The transaction requires role-appropriate backup copies, encrypted
secret-bearing controller and off-host archives, checksum verification, a
persistent ten-minute watchdog armed before switching, and explicit exact-
release confirmation. Refuse a production deployment until these mechanisms
exist and pass their offline contract tests.

## Classify authority

Choose exactly one role:

- `local`: the shared Arch workstation. This is the default.
- `test`: an isolated non-production host. Require explicit authorization for
  the current turn and verify the exact expected hostname and test marker.
- `production`: `api.lmm.best` on the explicitly approved production host.
  Require explicit authorization for the current turn, the expected SSH alias,
  the static hostname, the service role, and the exact release identity.

Stop on an ambiguous host, role, database engine, current release, dirty or
unexpected repository state, missing backup copy, unverified checksum, active
deployment lock, or unconfirmed previous deployment.

## Create persistent deployment work

Never use `/tmp` or `/var/tmp` for artifacts, caches, package staging, database
dumps, or release state.

Use [scripts/create-workspace.sh](scripts/create-workspace.sh) to create one
marker-owned deployment directory:

- controller default:
  `${XDG_STATE_HOME:-$HOME/.local/state}/lmm-api/deploy-work`
- target default: `/var/lib/lmm-api/deploy-work`

Export the emitted task-specific `TMPDIR`, `GOCACHE`, `GOMODCACHE`,
`CARGO_TARGET_DIR`, and `BUN_INSTALL_CACHE_DIR` values for every build or
package command. Do not reuse another deployment ID's caches or staging.

## Strict local acceptance preview

For this repository's local acceptance preview, SQLite is unconditionally
forbidden, including fallback, autodetection, and default behavior. Require a
fresh marker-owned local PostgreSQL database and role plus a fresh isolated
marker-owned Valkey instance. Start both with zero production or business data;
never use production DSNs, snapshots, or cache dumps. Bind them to loopback or
Unix sockets only, do not reuse an existing database, schema, role, cache
namespace, or port, and verify each identity before startup. Missing or
ambiguous PostgreSQL/Valkey configuration, an unexpected engine, a nonempty
target, or an unverifiable identity is a `STOP` condition. This strict rule
overrides the generic engine-detection guidance below for local acceptance
previews.

## Observe local host health proportionally

Before heavy local validation or preview work, observe host health on a
best-effort, proportional basis. Treat PSI, blocked tasks, swap use or churn,
available RAM, load, zram, and similar metrics as context only: never impose a
fixed numerical readiness threshold, and never stop solely because one metric
is high.

Serialize heavy work, start only the minimum required components, and monitor
the responsiveness of required commands and services while proceeding on a
degraded-but-functional machine. Stop only for concrete imminent or actual
failure: relevant recent OOM-killer or kernel storage errors, insufficient disk
for known artifacts, a required-port bind failure after verifying ownership and
conflicts, ambiguous PostgreSQL or Valkey identity, an uncontrolled deployment,
or sustained resource exhaustion that actually makes a required command or
service fail or become unresponsive.

Report the evidence and preserve partial state. Do not clear swap or caches, or
kill user applications, merely to satisfy a metric. This policy does not weaken
the SQLite prohibition; fresh marker-owned PostgreSQL and Valkey requirements;
production backup, rollback, and identity controls; workspace ownership; or
heavy-work serialization.

## Inspect without exposing secrets

Run [scripts/inspect-state.sh](scripts/inspect-state.sh) before planning a
mutation. It reports sanitized key/value or JSON state and never sources an
environment file or prints a DSN.

Reconcile the reported database engine with the chosen deployer and backup
method. Fail closed when SQLite, PostgreSQL, MySQL, or configuration evidence
disagrees. Do not select an engine from stale prose documentation.

### Prove the installed CLI before invoking it

Production may still have an older provider binary at `/usr/bin/lmm-api`. Do
not assume that `status`, `deploy`, or even `--help` is read-only: a legacy
binary can interpret an unknown subcommand as a request to start the backend.
Before invoking any subcommand, inspect the package owner and version, the
systemd `ExecStart`, the launcher protocol/revision, and the current service
PID. The canonical service must execute `/usr/bin/lmm-api serve`; the canonical
operator entry point must expose the `deploy production` transaction.

If the target does not satisfy that protocol, classify it as a pre-transaction
legacy target. Use `systemctl show`, `readlink`, the running process identity,
sanitized `/proc/<MainPID>/environ` scheme classification, and explicit HTTP
probes for read-only inspection. Do not run ambiguous `lmm-api status`,
`lmm-api deploy`, or no-argument invocations on that target. Upgrade the core
package through a guarded transaction before using the new phases. If a bad
probe starts a short-lived process or creates a local database file, preserve
the evidence, verify the production service remained unchanged, and do not
delete the artifact without exact ownership and scope confirmation.

### Distinguish database runtime from historical cutover prose

The live service can already run Go against PostgreSQL and the dedicated
Valkey even when older documentation describes Go/SQLite. The process
environment, service identity, active database/cache listeners, and durable
cutover journal are the evidence hierarchy. A PostgreSQL runtime without a
current verified `PG_WRITE_BOUNDARY`, or with a failed post-cutover result, is
an unverified state: stop before migration, backend selection, or rollback and
reconcile it through the cutover coordinator. Never infer Rust readiness from
the presence of PostgreSQL, Valkey, Rust artifacts, or an old rehearsal.

## Build once and promote identical bytes

Build and validate once in the controller workspace. Record the Git commit,
release ID, package identity, and SHA-256 in the deployment manifest. Promote
the identical checksum-verified artifact to test and production. Never rebuild
on the target and never substitute a later artifact under the same release ID.

Use the repository's existing package and release mechanisms only for their
documented roles. AUR or paru work must preserve the split core/Go/Rust package
matrix and run its packaging checks before delivery.

Treat a dirty or changing worktree as a release blocker. Freeze the exact
revision and build manifest before creating the core package, Rust provider,
migrator, or frontend archive; do not promote a dist directory or binary that
was built from an unrecorded working-tree state.

The Rust blue/green mechanism owns internal liveness/readiness/build probes
only. It is not business-route ownership. Before a backend transaction is
allowed to target `rs`, the migration gate must validate in both source and
activation modes, every production route must be independently verified and
approved for Rust, and PostgreSQL, Valkey, authentication, quota, billing,
streaming, and drain/reconnect evidence must be current. A mounted candidate,
an active slot link, or a successful `/readyz` probe is insufficient.

## Require backups before mutation

Create and verify the role-specific copies described in the safety contract:

- local: controller copy;
- test: target rollback snapshot and controller copy;
- production: target rollback snapshot, controller copy under
  `$HOME/backup/lmm-api/<verified-host>/<deployment-id>`, and a verified
  off-host archive on ArchCzy or explicitly configured object storage.

Run [scripts/verify-backup-set.sh](scripts/verify-backup-set.sh). Do not mutate
the target unless it succeeds. Encrypt every archive that can contain secrets
before it leaves the target. Never print archive contents or secret values.

## Arm rollback before switching

Production and production-like test switches require a persistent systemd
watchdog armed before the application or frontend switch. The deadline is ten
minutes. A successful switch ends in `AWAITING_CONFIRMATION`, not `DEPLOYED`.

The watchdog restores only the verified application package, frontend release,
and configuration snapshot. It never restores the database automatically.
Block migrations unless both the new and previous application releases remain
compatible with the database for the whole confirmation window.

Manual confirmation must re-verify the exact backend artifact, frontend
symlink, service state, and health identity before disabling the timer. A
generic healthy response is insufficient.

## Retain and clean safely

Default retention is five target snapshots, ten controller copies, and thirty
off-host copies. Never remove the active release, an unconfirmed deployment,
or the latest known-good snapshot. Prune only after confirmation and successful
backup verification.

Use [scripts/cleanup-owned-workspace.sh](scripts/cleanup-owned-workspace.sh)
only for the exact marker-owned deployment directory after a durable
`CONFIRMED` or `ROLLED_BACK` state. Preview first. Never clean a broad temp
directory, backup root, release root, unresolved variable, glob, symlink, or
another deployment's workspace.

## Report the outcome

Report the role and verified host, release and artifact SHA-256, backup copy
locations and verification result, service/frontend health identity, rollback
timer and deadline, confirmation state, cleanup performed, and every skipped or
failed gate. Never imply production completion while confirmation is pending.
