# Frontend and backend upgrades

The frontend and backend have different safety boundaries and are released independently.

## Frontend: zero-downtime static releases

Build `web/dist` in CI or a build workspace, then copy that immutable directory to the server. Publishing does not restart the Go service or nginx:

```bash
sudo deploy/frontend-release.sh publish \
  --source /path/to/dist \
  --release <git-sha>
```

The publisher validates `index.html` and its local asset references, copies into a same-filesystem staging directory, and atomically replaces `/srv/lmm-api-frontend/current`. Before switching, it copies `/static` files into the cumulative immutable store at `/srv/lmm-api-frontend/assets`, rejecting a same-name/different-content collision, then makes the versioned release read-only. This lets a browser holding the previous `index.html` continue lazy-loading its hashed chunks after a switch. It uses `flock` to serialize publishers and retains `N` HTML releases in total, always including the current release. Static assets are intentionally not garbage-collected in this phase; a future GC must preserve every asset referenced by every retained release. Preview actions with `--dry-run`; change HTML retention with `--keep N`.

Rollback is another atomic symlink replacement:

```bash
sudo deploy/frontend-release.sh rollback
# or select an exact retained release
sudo deploy/frontend-release.sh rollback --release <git-sha>
```

The site uses its own `/etc/nginx/lmm-api-mime.types`; it never creates or overwrites nginx's global `/etc/nginx/mime.types`. Publish all nginx inputs with the controlled transaction rather than copying them individually:

```bash
sudo deploy/nginx/install-nginx-split.sh install
```

The installer serializes with `flock`, reserves a unique non-overwritable backup, and manages `/etc/nginx/lmm-api-mime.types`, the HTTP `map`, the server locations, and `/etc/nginx/conf.d/new-api.conf`. Each candidate is installed as a root-owned `0644` same-directory temporary file and published with `mv -T`. Only after every file is in place does it run `nginx -t`, reload nginx, and verify the unit remains active. Any candidate failure restores the previous presence or exact content of every managed file with the same atomic replacement, then repeats syntax validation, reload, and service verification. Backups remain under `/var/lib/lmm-api-nginx-deploy/backups` for audit and manual recovery; never overwrite an existing backup. Existing symlinks, including dangling symlinks, are rejected before mutation.

The server-scoped template explicitly includes `/etc/nginx/lmm-api-mime.types`; do not remove it or rely on a global include, because production's `http` context otherwise defaults to `application/octet-stream` and browsers reject JavaScript modules served with that MIME type. The template sends every known backend route family to port 3000, preserves WebSocket/SSE behavior, serves the shared `/static` asset store with immutable caching, and makes entry points revalidate. Missing static or root-public assets return 404 instead of SPA HTML. The production `/terms` and `/privacy` semantics are preserved as exact aliases to `/var/www/api.lmm.best/legal/terms.html` and `privacy.html`; nginx serves both as UTF-8 HTML with `X-Content-Type-Options: nosniff`, independently of a frontend release.

Run `make check-frontend-split` whenever routers or deployment files change. Adding a new top-level backend router family requires updating the nginx split and its check in the same change.

## Go backend today: autonomous, bounded interruption

Production currently uses one Go process and SQLite. The 2026-08-01 gate snapshot has Go owning all 356 legacy routes; always read `rust/routes/migration-gate.tsv` rather than treating this prose as the current ownership source. A backend package upgrade must remain a single-instance, autonomous systemd transaction with a deployment lock, offline database backup, health validation, persistent audit output, and complete package rollback. The transaction continues without the initiating shell or API connection, but restarting the only process creates a bounded interruption. It is not a zero-downtime or blue/green deployment.

Do not run old and new backend binaries concurrently against the SQLite database. Two writers, startup migrations, and background jobs make that unsafe; copying SQLite for each process would instead create divergent state.

## Rust internal-probe blue/green foundation

The native Rust blue/green deployment foundation uses blue on `127.0.0.1:3100` and green on `127.0.0.1:3101`. Nginx ownership remains only loopback-restricted GET/HEAD liveness, readiness, and build probes. Releases, per-slot symlinks, nginx upstream publication, PREPARED/COMMITTED journals, crash reconciliation, and SIGTERM bounded drain are independent of the Go process. Root-router and candidate-module counts are deliberately not repeated here: the migration TSV is authoritative. Neither a mounted candidate nor a historical internal-probe rehearsal owns production traffic. See `docs/rust-blue-green.md` and the TSV for the current result.

This foundation is deliberately not a production API cutover. Production business routes still go to Go on port 3000, and SQLite remains authoritative. The Rust production-routing enable marker is a hard failure condition until every route passes independent differential gates and the PostgreSQL 18 cutover is approved.

## PostgreSQL production migration prerequisite

The verified SQLite-to-PostgreSQL copier and autonomous coordinator now exist,
but production has not been migrated. The coordinator stops the Go writer,
backs up and verifies SQLite, copies into a fresh versioned schema, durably
marks the forward-only boundary before publishing PG+Valkey configuration, and
runs public plus authenticated canaries. A strict journal, immutable candidate
hash, `--reconcile-only` path, and systemd boot gate make process death and
reboot idempotently recoverable without relying on the initiating shell. Before
the marker it restores the exact saved SQLite environment; marker or matching
candidate-hash evidence permits only forward PostgreSQL recovery. See
`docs/postgresql-cutover.md` for the exact state machine and remaining rehearsal
and approval gates.

That reliability is not zero downtime for the one-time database cutover.
Systemd detachment survives SSH/API control-channel loss, but the SQLite freeze
stops the sole Go process and disconnects active HTTP, SSE, and WebSocket
connections. Production stays prohibited until the isolated rehearsal passes
and an operator explicitly approves the maintenance window.

Before business traffic moves to Rust, route/auth/quota/billing/streaming parity, expand/contract migrations compatible with N and N-1, singleton ownership for background jobs, authenticated canaries, and graceful draining/reconnection of SSE and WebSocket clients remain mandatory. nginx must not automatically retry non-idempotent requests.
