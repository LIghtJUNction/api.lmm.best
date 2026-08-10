# LMM deployment safety contract

## Authorization and identity

- Default to `local`.
- Require explicit current-turn authorization for `test` or `production`.
- Verify the expected SSH alias, static hostname, role marker, service name,
  installed package identity, current backend artifact, frontend symlink, and
  installed CLI protocol/service entry point.
- Treat host or role disagreement as a stop condition.
- Preserve the repository's one-branch, one-worktree, one-diff rules. A deploy
  request does not authorize Git repair, branch switching, commit, or push.

## Workspace and build contract

- Create one deployment ID matching `[A-Za-z0-9][A-Za-z0-9._-]{0,127}`.
- Use marker-owned persistent storage, never `/tmp` or `/var/tmp`.
- Place `TMPDIR`, Go build cache, Go module cache, Cargo target output, Bun
  cache, package staging, manifests, and logs under that deployment directory.
- Build once. Record and verify the same artifact SHA-256 at every promotion
  boundary.
- Never overwrite an existing immutable release with different bytes.

## Database detection

- Inspect configuration without sourcing it and without printing values.
- Classify only SQLite, PostgreSQL, or MySQL from recognized configuration
  keys and safe value prefixes.
- Fail when multiple engines are present, when the deployer and live engine
  disagree, or when the engine is unknown for a database-changing release.
- Never put a DSN in command output, a manifest, `SWAP.md`, or a process title.
- Treat the running service environment and active listeners as current
  evidence; historical prose or a previous cutover result is not enough.
- If the live process uses PostgreSQL but the current `PG_WRITE_BOUNDARY`,
  cutover journal, or post-cutover verification is missing or failed, stop and
  reconcile through the coordinator before migration, backend selection, or
  rollback. Do not silently classify that state as a fresh SQLite migration.

## Legacy CLI safety

- Before invoking `/usr/bin/lmm-api` on a target, verify its package owner,
  protocol/revision, supported `deploy production` transaction, and the
  systemd `ExecStart` contract (`/usr/bin/lmm-api serve`).
- A legacy binary may start the backend for an unknown command. `status`,
  `deploy`, `--help`, and no-argument calls are not read-only until the
  protocol is proven.
- For a legacy target, inspect with `systemctl show`, `readlink`, sanitized
  process-environment scheme classification, and explicit health probes only.
  Upgrade the core package through a guarded transaction before using deploy
  phases. Preserve and report any artifact created by an unsafe probe; remove
  it only after exact ownership and scope are confirmed.

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

## Rust ownership gate

- The Rust blue/green slots own internal GET/HEAD probes only until the route
  gate and independent business differential evidence approve production
  ownership.
- `migration-gate.tsv` must pass source-mode validation before packaging and
  activation-mode validation before a Rust switch. Reject inconsistent
  `legacy-go`/mounted rows, unresolved routes, unverified auth/quota/billing or
  streaming behavior, and any route without independent approval.
- PostgreSQL and dedicated Valkey identity, shared rate-limit/session state,
  background-job singleton behavior, and SSE/WebSocket drain/reconnect are
  required evidence; a mounted slot, active symlink, or `/readyz` response is
  not production proof.

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

## Minimum validation before production enablement

- Skill validation and shell syntax checks pass.
- Offline tests cover safe IDs and paths, host mismatch, database disagreement,
  backup corruption, missing copies, encrypted off-host artifacts, timer
  arming, exact-release confirmation, expiry rollback, reboot recovery, and
  scoped cleanup.
- Existing production contract tests require dual backups, watchdog state, and
  `AWAITING_CONFIRMATION`.
- A fresh runtime audit reconciles any historical PostgreSQL cutover result and
  proves the active schema, Valkey endpoint, and forward-only boundary.
- Frontend-only publication is proven compatible with the current Go API before
  it is promoted independently of Rust.
- A local deployment of the identical artifact passes application and frontend
  checks before any test or production promotion.
- Authenticated canaries and representative business requests pass in addition
  to generic health checks; browser, SSE, and WebSocket behavior is reviewed
  when affected by the release.
- An independent Reviewer approves the deployment behavior and residual risk.
