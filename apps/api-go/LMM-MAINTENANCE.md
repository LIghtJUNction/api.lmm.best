# LMM API Go source maintenance

`apps/api-go/` is the maintained Go service tree. It combines:

- the `QuantumNous/new-api` upstream subtree, initially imported from commit
  `66ee6b8f9889050ffef1f863a4314ce4a0516fb9`;
- the former frozen LMM API Go snapshot from commit
  `5418ce6b6d45ed69167b0aad53f2f595e5bc8de9`;
- the channel-aware top-up pricing, signed ePay callback checks, and open-source
  bounty implementation maintained directly as ordinary Go source and tests.

The hotfix is now ordinary Go source and tests, so it is reviewed and merged
alongside upstream changes. The original freeze manifests are retained under
`.legacy-archive/` for provenance checks.

The shared frontend lives in `apps/web/`. `apps/api-go/web/` belongs to
the upstream subtree and is kept so subtree pulls retain the complete upstream
history and layout. Production Go builds receive the verified shared frontend
through the root `just build` workflow.

## Pull upstream changes

Start from a clean worktree on a dedicated branch:

```sh
git switch -c chore/sync-new-api-YYYYMMDD
bash apps/api-go/sync-upstream.sh main
```

The sync script registers `https://github.com/QuantumNous/new-api.git` as the
`new-api-upstream` remote when needed, fetches the requested ref, and performs
a squash subtree merge into `apps/api-go/`. Resolve conflicts in favor of current LMM
API behavior where local payment, branding, or migration compatibility differs
from upstream. Then update the recorded provenance and verify:

```sh
bash apps/api-go/verify-channel-pricing-hotfix.sh
(
  cd apps/api-go
  go test ./...
)
```

## Build and package

The root build assembles the shared frontend into the Go embed tree, then
produces the static Go binary and default Arch package:

```sh
just build
just package-go
```

Package details remain in `apps/api-go/packaging/README.md` and the root
`packaging/aur/lmm-api/` definition.
