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

Install `deploy/nginx/http-map.conf` in nginx's `http` context and include `deploy/nginx/lmm-api-locations.conf` inside the existing TLS server. Validate with `nginx -t` before reloading nginx. The template sends every known backend route family to port 3000, preserves WebSocket/SSE behavior, serves the shared `/static` asset store with immutable caching, and makes entry points revalidate. Missing static or root-public assets return 404 instead of SPA HTML. The production `/terms` and `/privacy` semantics are preserved as exact aliases to `/var/www/api.lmm.best/legal/terms.html` and `privacy.html`; nginx serves both as UTF-8 HTML with `X-Content-Type-Options: nosniff`, independently of a frontend release.

Run `make check-frontend-split` whenever routers or deployment files change. Adding a new top-level backend router family requires updating the nginx split and its check in the same change.

## Backend today: autonomous, bounded interruption

Production currently uses one Go process and SQLite. A backend package upgrade must remain a single-instance, autonomous systemd transaction with a deployment lock, offline database backup, health validation, persistent audit output, and complete package rollback. The transaction continues without the initiating shell or API connection, but restarting the only process creates a bounded interruption. It is not a zero-downtime or blue/green deployment.

Do not run old and new backend binaries concurrently against the SQLite database. Two writers, startup migrations, and background jobs make that unsafe; copying SQLite for each process would instead create divergent state.

## PostgreSQL migration prerequisite

True backend blue/green deployment is a later phase and requires a reviewed migration from SQLite to PostgreSQL first. The migration plan must cover backup and restore, row/count and application-level validation, maintenance boundaries, rollback criteria, and production-specific configuration. No generic migration command should be run against production without that plan.

After PostgreSQL is established, backend blue/green still requires explicit liveness/readiness endpoints, expand/contract migrations compatible with N and N-1, singleton ownership for background jobs, shared runtime state, authenticated canaries, atomic nginx upstream switching, and graceful draining/reconnection of SSE and WebSocket clients. nginx must not automatically retry non-idempotent requests.
