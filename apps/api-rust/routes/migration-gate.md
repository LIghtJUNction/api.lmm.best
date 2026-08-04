# Migration evidence gate

`migration-gate.tsv` is a route-for-route audit boundary. It has the same 356
method/path keys as the frozen legacy inventory, records exactly 20 mounted
Rust root routes, and does not transfer production ownership: every row must
retain `production_owner=go`.

The current fail-closed ledger records 20 source-present and mounted routes,
with zero compile, differential, approval, or production-ownership credit.
Eight mounts are explicitly `blocked-sol-stop`; the other twelve are
`mounted-unverified`. The blocked routes are exactly:

```text
GET /api/status
POST /api/user/auth/logout
POST /api/user/auth/refresh
POST /api/user/login
GET /api/user/self
GET /v1/models
GET /v1beta/models
GET /v1beta/openai/models
```

The checker derives a route decision from its row fields, rather than from a
list of special auth or models paths. The mounted decision states are:

| Gate state | Required fields | Meaning |
| --- | --- | --- |
| `candidate-pending-independent-approval` | `present`, `unverified`, `mounted`, `unverified`, `pending-independent-approval` | Pending: implementation is observed but has no verification credit. |
| `blocked-sol-stop` | `present`, `unverified`, `mounted`, `blocked-sol-stop`, `not-applicable` | Blocked: an explicit stop prevents every migration credit. |
| `verified-approved` | `present`, `verified`, `mounted`, `verified`, `approved` | Reserved approved state: all five proofs must be present, but no current row has this state. |

`mounted-unverified` is an observed mount that has neither a pending approval
nor verification credit. `legacy-go` is an absent, unmounted Go-owned route.
The nine API-token routes are the only mounted modules from `migration_routes`;
their Axum `{id}` segments are matched exactly to ledger `:id` segments. The
other candidate modules remain forbidden from the root router.

For `verified-approved`, the `evidence` field must be semicolon-separated
named references with all of these non-empty keys:

```text
source=<router-or-source-proof>;compile=<compile-proof>;mount=<mount-proof>;differential=<differential-proof>;approval=<approval-record>
```

The four file-backed references must resolve inside the repository. A reference
may append `@sha256:<64-lowercase-hex>`; when present, the checker verifies the
current file digest so the approved harness cannot drift silently.

The checker permits pending, blocked, and approved rows only through these
explicit field combinations. It rejects a state/field mismatch, missing named
proof, a Rust production owner, a changed root-mount inventory, or incomplete
route coverage.
