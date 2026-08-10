# LMM deployment safety contract

## Authorization and identity

- Default to `local`.
- Require explicit current-turn authorization for `test` or `production`.
- Verify the expected SSH alias, static hostname, role marker, service name,
  installed package identity, current backend artifact, and frontend symlink.
- Treat host or role disagreement as a stop condition.
- Preserve the repository's one-branch, one-worktree, one-diff rules. A deploy
  request does not authorize Git repair, branch switching, commit, or push.

## Workspace and build contract

- Create one deployment ID matching `[A-Za-z0-9][A-Za-z0-9._-]{0,127}`.
- Use marker-owned persistent storage, never `/tmp` or `/var/tmp`.
- Place `TMPDIR`, Go build cache, Go module cache, Cargo target output, Bun
  cache, package staging, manifests, and logs under that deployment directory.
- The controller workspace is
  `${XDG_STATE_HOME:-$HOME/.local/state}/lmm-api/deploy-work/<deployment-id>`;
  do not leave build or package bytes in the repository or in `/tmp`.
- Build once. Record and verify the same artifact SHA-256 at every promotion
  boundary.
- Never overwrite an existing immutable release with different bytes.

### Production resource gates

The production root filesystem is 20 GiB and the service cgroup is bounded by
`MemoryHigh=320M`, `MemoryMax=384M`, and `MemorySwapMax=256M`. Before a
mutation, during every build/backup transfer, and throughout the watchdog
window, record `df -h /`, `df -i /`, `free -h`, `vmstat 1 5`, the service
`NRestarts`/memory counters, PostgreSQL readiness, Valkey readiness, and native
CLI `/api/status` plus `/api/livez` probes.

- Green: root and inode use `<70%`, `MemAvailable >=30%`, swap `<10%`, CPU
  `<70%` for 5 minutes, and at least 4 GiB free before a production package.
- Warning: root/inode use `70-80%`, `MemAvailable 20-30%`, swap `10-25%`, or
  CPU `70-85%`; serialize heavy work and prune only measured terminal work.
- Stop: root/inode `>=80%`, root free space below the known package plus three
  backup copies and 1 GiB headroom, `MemAvailable <20%`, swap `>25%` with
  churn, CPU `>85%` for 5 minutes, repeated restart/OOM, or a required probe
  timeout. At `>=90%` storage use, treat the host as an emergency and clean
  storage before touching application state.

Do not clear swap, journals, caches, or the database to make a metric green.
Do not kill unrelated processes. A failed resource or health check is an
incident signal and must be recorded before any retry.

## Database detection

- Inspect configuration without sourcing it and without printing values.
- Classify only SQLite, PostgreSQL, or MySQL from recognized configuration
  keys and safe value prefixes.
- Fail when multiple engines are present, when the deployer and live engine
  disagree, or when the engine is unknown for a database-changing release.
- Never put a DSN in command output, a manifest, `SWAP.md`, or a process title.

## Local acceptance preview override

For this repository's local acceptance preview, SQLite is unconditionally
forbidden, including fallback, autodetection, and default behavior. Require a
fresh marker-owned local PostgreSQL database and role plus a fresh isolated
marker-owned Valkey instance, both initialized with zero production or
business data. Do not use production DSNs, snapshots, or cache dumps. Bind
both to loopback or Unix sockets only; do not reuse an existing database,
schema, role, cache namespace, or port. Verify database and cache identities
before startup. Missing or ambiguous configuration, an unexpected engine, a
nonempty target, or inability to verify identity is an immediate `STOP`, never
a fallback. This override applies only to local acceptance previews; generic
engine detection above remains applicable to other deployment roles.

## Backup copies

Before mutation, require:

| Role | Required verified copies |
| --- | --- |
| local | controller |
| test | target, controller |
| production | target, controller, off-host |

The production controller copy lives at
`$HOME/backup/lmm-api/<verified-host>/<deployment-id>`. The off-host copy lives
on ArchCzy under a fixed root or in explicitly configured object storage.

Each copy contains `manifest.env`, `SHA256SUMS`, a nonempty application archive,
frontend archive, configuration archive, and database backup. The manifest
records:

- format and deployment ID;
- copy role, deployment role, and verified host;
- release ID, artifact SHA-256, and Git revision;
- database engine;
- service state and frontend release identity;
- archive paths, sizes, modes, and UTC timestamps.

The target may retain a root-only plaintext configuration snapshot. Controller
and off-host configuration or database archives must be encrypted before
transfer. Checksums cover the encrypted bytes that were actually transferred.

Default retention is five target, ten controller, and thirty off-host copies.
Prune only after confirmation or verified rollback. Never remove the active
release, an unconfirmed deployment, the latest known-good backup, or a copy
whose remaining peers have not been verified.

Canonical roots are fixed:

- controller workspace: `${XDG_STATE_HOME:-$HOME/.local/state}/lmm-api/deploy-work/<deployment-id>`;
- durable controller copy: `$HOME/backup/lmm-api/<verified-host>/<deployment-id>`;
- production target workspace: `/var/lib/lmm-api-go/deploy-work/<deployment-id>`
  (resolved private state is below `/var/lib/private/lmm-api-go`);
- production target backup: `/var/lib/lmm-api-go/deploy-backups/<deployment-id>`;
- off-host copy: `/home/arch/.local/state/lmm-api-production-backups/<deployment-id>`
  on `ArchCzy`.

Only the exact workspace's `staging`, `tmp`, and cache children are disposable.
After terminal state, retain its marker/status audit record and the three
durable copies; remove staging by exact path. Never recursively clean a backup
root, release root, home/root, `/tmp`, `/var/tmp`, an unresolved variable, or a
glob. A terminal workspace older than 24 hours may be pruned oldest first only
after checksum/decryption verification and only while the storage gate remains
green.

## Rollback watchdog

- Install a persistent systemd watchdog before the first switch.
- Store a root-only, checksum-verified guard containing the exact deployment,
  old/new backend identities, old/new frontend identities, rollback artifacts,
  status, and deadline.
- Arm the watchdog before switching application or frontend state.
- After successful identity and health probes, set a ten-minute deadline and
  return `AWAITING_CONFIRMATION`.
- Manual confirmation must name the exact deployment and re-verify backend
  checksum/version, frontend symlink, relevant services, and health identity.
- Confirmation writes `CONFIRMED` durably before stopping and disabling the
  timer.
- Expiry restores the prior application package, frontend link, and approved
  configuration snapshot, verifies health, writes `ROLLED_BACK`, and preserves
  evidence for review.
- Automatic rollback never restores a database. Block the release unless its
  migrations are compatible with both N and N-1 during the confirmation
  window.

## Cleanup

- Clean only the exact deployment workspace carrying the expected marker and
  matching deployment ID.
- Require a durable `CONFIRMED` or `ROLLED_BACK` final state.
- Reject `/`, home roots, workspace roots, `/tmp`, `/var/tmp`, backup roots,
  release roots, unresolved variables, tildes, globs, symlinks, and paths not
  owned by the marker.
- Preview cleanup before execution.
- Never implement “clear tmp” as a broad directory deletion. Identify and
  remove only stale, inactive, marker-owned LMM deployment workspaces.
- Re-run disk/inode/RAM/swap, service state, PostgreSQL/Valkey readiness, and
  native CLI status/livez checks after cleanup; record exact paths removed and
  the remaining free-space margin.

## Minimum validation before production enablement

- Skill validation and shell syntax checks pass.
- Offline tests cover safe IDs and paths, host mismatch, database disagreement,
  backup corruption, missing copies, encrypted off-host artifacts, timer
  arming, exact-release confirmation, expiry rollback, reboot recovery, and
  scoped cleanup.
- Existing production contract tests require dual backups, watchdog state, and
  `AWAITING_CONFIRMATION`.
- A local deployment of the identical artifact passes application and frontend
  checks before any test or production promotion.
- An independent Reviewer approves the deployment behavior and residual risk.
