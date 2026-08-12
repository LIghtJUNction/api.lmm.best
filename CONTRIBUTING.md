# Contributing to LMM Forge

Welcome to LMM Forge contribution. This file defines the expected process for
code, docs, and operational changes.

## Scope

This repository primarily accepts:

- Bounty workflow logic and delivery-tracking product behavior.
- Go backend compatibility and admin-facing behavior changes.
- Frontend workflow and governance UX changes.
- Security-hardening and operational reliability updates.

For third-party deployment/hosting issues, cloud pricing issues, or private fork
customization, please contact the corresponding owner instead of opening issues.

## Before opening an Issue

- Confirm the request is in this repository scope and not in third-party infra.
- Check existing issues to avoid duplicates.
- Remove API keys, cookies, DSN, passwords, and tokens from screenshots/logs.
- Prefer minimal reproducible details (exact endpoint, expected behavior, actual behavior).

Issue and PR templates in `.github/ISSUE_TEMPLATE` and `.github/PULL_REQUEST_TEMPLATE.md`
are required by maintainers during review.

## Development setup

```bash
just setup
just dev
```

For headless backend-only work:

```bash
just dev-go
# or
just dev-rust
```

## Quality gates

Before opening a PR, run at least:

- `just format`
- `just lint`
- `just test`

For production-facing changes:

- `just build`
- `just check`
- Any affected app-level test suite in `apps/api-go`, `apps/api-rust`, or `apps/web`.

If checks are skipped, list the reason clearly in PR description.

## PR expectations

### Mandatory PR checklist

- Scope is bounded to the stated objective.
- Behavior and compatibility impact are described clearly.
- Related docs are updated.
- Sensitive data is redacted in evidence, logs, and snapshots.
- Upstream relationship is explicitly stated when applicable.
- Release notes or changelog intent is updated if behavior is user-facing.

### Merge requirements

- Upstream fork attribution rules and notices remain intact (see `NOTICE` and `FORK.md`).
- No unrelated refactors, cosmetic-only formatting, or broad tree-wide edits.

## Communication

For all bug reports and feature requests, use GitHub templates.
For security vulnerabilities, use the procedure in [`SECURITY.md`](./SECURITY.md).

