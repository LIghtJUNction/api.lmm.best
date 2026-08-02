# SQLite online backup to archczy

This is an inert deployment bundle for the current production SQLite database.
The job uses SQLite's online `.backup` API into a private `mktemp` directory,
requires `PRAGMA quick_check` to return `ok`, validates the zstd archive, then
ships an archive/checksum pair through a pinned SSH identity. Remote retention
only counts SHA-256-valid snapshots and retains exactly the newest three.

The remote destination is deliberately fixed to:

```
/var/backups/lmm-api/sqlite/<instance>
```

`<instance>` defaults to `production` and is restricted to one safe path
component. `/`, `/etc`, traversal, and arbitrary remote directories cannot be
configured. The script performs a pinned-SSH preflight before either SCP:
the fixed root and instance directory are created/verified as `root:root 0700`.
The dedicated remote backup account must therefore run the backup command as
root (for example through a narrowly constrained forced command or dedicated
root-only key). Archive files are mode `0600`; the instance directory is mode
`0700`. The checksum is the publication marker: the archive is atomically
renamed first and the checksum is renamed last. A failed transfer or validation
never runs retention and cannot remove the three last known-good snapshots.

`pgBackRest` is intentionally deferred. The business database is currently
SQLite; configure pgBackRest with `repo1-retention-full=3` only after
PostgreSQL has formally become the production database.

## Required configuration

Create `/etc/lmm-api/sqlite-backup.env` with mode `0600`:

```sh
SQLITE_BACKUP_SOURCE_DB=/var/lib/private/lmm-api/one-api.db
SQLITE_BACKUP_REMOTE_HOST=archczy
SQLITE_BACKUP_REMOTE_INSTANCE=production
```

The source database must be an explicit absolute path. No discovery or globbing
is performed.

Create dedicated, root-readable credentials (not `/root/.ssh`) with mode
`0600`:

```
/etc/lmm-api/credentials/archczy-backup.identity
/etc/lmm-api/credentials/archczy-backup.known_hosts
```

The identity must be a backup-only key accepted by `archczy`; its known-hosts
file must pin archczy's host key. `LoadCredential=` copies both into systemd's
per-service `CREDENTIALS_DIRECTORY`. The script explicitly supplies `-i`,
`UserKnownHostsFile`, `StrictHostKeyChecking=yes`, `IdentitiesOnly=yes`, and
`BatchMode=yes` to both `ssh` and `scp`, so it never falls back to
`/root/.ssh`.

Bootstrap the target directory once using the same restricted remote identity
before enabling the timer (the scheduled script repeats this check):

```sh
ssh -i /etc/lmm-api/credentials/archczy-backup.identity \
  -o UserKnownHostsFile=/etc/lmm-api/credentials/archczy-backup.known_hosts \
  -o StrictHostKeyChecking=yes -o IdentitiesOnly=yes -o BatchMode=yes archczy \
  'install -d -o root -g root -m 0700 /var/backups/lmm-api/sqlite/production'
```

Then verify on archczy: `stat -c '%U:%G:%a' /var/backups/lmm-api/sqlite/production`
must print `root:root:700`.

## Approved installation change

Do this only in an approved maintenance window; this repository task does not
install or enable it:

```sh
install -d -m 0755 /usr/local/lib/lmm-api /etc/lmm-api/credentials
install -m 0750 deploy/backup/backup-sqlite-to-archczy.sh /usr/local/lib/lmm-api/
install -m 0644 deploy/backup/lmm-api-sqlite-backup.service /etc/systemd/system/
install -m 0644 deploy/backup/lmm-api-sqlite-backup.timer /etc/systemd/system/
systemctl daemon-reload
systemctl enable --now lmm-api-sqlite-backup.timer
```

The timer runs daily at **03:30 Asia/Shanghai**. Before enabling, make one
approved manual run and verify that `archczy` has the expected safe instance
directory, pinned key access, and at most three valid archive/checksum pairs.

## Offline verification

```sh
bash deploy/backup/test-backup-sqlite-to-archczy.sh
```

The test uses temporary SQLite WAL databases and fake local `ssh`/`scp`; it
makes no network connection and never touches `/var/backups`.
