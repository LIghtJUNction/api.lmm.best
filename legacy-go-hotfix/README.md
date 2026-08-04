# Legacy Go channel-pricing hotfix

This hotfix bundle also includes `open-source-bounties.patch`, which adds the
production API and database models for the “开源悬赏” lifecycle. The same
authenticated balance rules apply to every publisher, including root users:

- drafts do not charge balance;
- publishing burns the chosen promotion quota and escrows every advertised
  reward slot from the publisher's own balance;
- contributors accept a challenge and submit matching GitHub Issue/PR links;
- the publisher approves or rejects the submission;
- approval transfers the escrowed reward directly to the contributor balance;
- closing is blocked while challenges are active, then refunds only unused
  escrow; promotion spend is non-refundable;
- no project is inserted or promoted by default.

The patch creates an append-only bounty ledger alongside project and challenge
state so every promotion spend, escrow funding, reward transfer, and refund is
auditable.

`open-source-bounties-mcp.patch` extends that lifecycle with the latest MCP
Streamable HTTP endpoint at `/mcp`, one revocable personal token per user,
multi-round-trip confirmations, administrator-configured task fees, partial-work
tips, mutual one-time ratings, and third-party dispute handling. Money-bearing
MCP confirmations bind the current project, fee, escrow, recipient, and balance
snapshot. Every confirmed mutation persists its operation result in the same
database transaction as the business change, including publication, review,
refund, tip, rating, dispute, draft deletion, and withdrawal. A retry after
response loss returns the completed operation instead of charging, paying,
rating, deleting, or freezing twice.

Rejecting a submission starts a seven-day appeal window that keeps its reward
slot and escrow reserved even before a dispute is filed. Opening a dispute
freezes an immutable snapshot of the published rules, reward,
Issue, pull request, encrypted review message, submission/review notes, tip, and
both ratings. An open case keeps its reward slot and escrow reserved and blocks
withdrawal or project close/refund. Administrator payment is allowed only for a
contributor claim against the matching project owner, in a submitted or rejected
state, after the administrator role and conflicts of interest are rechecked
inside the payout transaction. A project owner or challenge participant cannot
adjudicate that challenge even when they are an administrator.
The original rejection note and score remain visible as case evidence; an
overturned rejection score is excluded from ordinary contributor reputation.
Unique party-case, open-case, and reward-payout keys prevent the same party from
reopening a resolved case, allow only one pending case per challenge, and enforce
one reward transfer per challenge at the database boundary.

This directory is a self-contained, reproducible production hotfix for the Go
baseline `3e39995a092f960882db6bf455b371d32591dc47`. It deliberately does not
touch the active Rust or Web migration worktree.

`channel-pricing.patch` adds optional fields to each existing `PayMethods`
`map[string]string`; no database migration is required:

```json
[
  {"name":"支付宝","type":"alipay"},
  {
    "name":"LINUX DO Credit",
    "type":"epay",
    "settlement_unit":"LDC",
    "unit_price":"10"
  }
]
```

`settlement_unit` is metadata returned unchanged by `/api/user/topup/info` for
the UI. `unit_price` is the settlement currency per one platform display unit.
For example, `unit_price: "10"` makes one platform dollar cost 10 LDC before
group and amount-discount rules. Omit `unit_price` to retain the old global
`Price` behavior. `settlement_unit` and `unit_price` are an all-or-nothing
pair: both must be present. Unit labels must exactly match
`^[A-Za-z0-9._-]{1,16}$` (for example `LDC` or `.LDC-1`): no whitespace or
control characters. A missing partner, invalid label, malformed decimal, zero,
negative, exponential, or non-finite price fails closed.

The server quote used by both `/api/user/amount` and `/api/user/pay` is:

```text
platform amount × method unit_price (or global Price) × group ratio × amount discount
```

The result is rounded to two decimals before both the gateway request and the
pending order are created. Configured `unit_price` must be a strictly positive
decimal such as `10` or `0.14`. For compatibility, old clients that omit
`payment_method` when calling `/api/user/amount` retain the old global `Price`
quote. New clients which send a method use that method's configured quote.

`/api/user/topup/info` now contains `topup_group_ratio` for the authenticated
user. The field lets the UI present preset cards using the same group factor as
the server. A configured ratio of zero follows existing quote semantics and is
returned as `1`. If the current user group cannot be read, the endpoint fails
instead of returning a potentially incorrect quote.

The patch also verifies signed ePay callback `type` and `money` against the
pending order before crediting it. A mismatch returns `fail` and cannot alter
the stored payment method. A matching callback for an already completed order
is acknowledged without a second credit. Subscription payment handlers are
not modified.

## Verify from a clean baseline

Run from this repository:

```sh
bash legacy-go-hotfix/verify-channel-pricing-hotfix.sh
```

The runner creates a temporary source tree with `git archive`, performs an
`apply --check`, applies the patch, runs the targeted Go regression tests, and
builds the `controller` package. It leaves the current worktree untouched.

If an external web distribution must be included in the temporary build tree,
pass it explicitly:

```sh
bash legacy-go-hotfix/verify-channel-pricing-hotfix.sh --web-dist /path/to/web/dist
```

## Reproducible production binary

After the web distribution has passed its own checks, build the Go binary from
the same clean baseline without touching a server or reading any credentials:

```sh
bash legacy-go-hotfix/build-production-binary.sh --web-dist /path/to/verified/web/dist
```

The builder requires `--web-dist`, performs a clean `git archive`, checks and
applies all three patches in order, copies that distribution into the temporary source tree,
and runs the root build with `GOPROXY=off`, `CGO_ENABLED=0`, `-trimpath`,
`-buildvcs=false`, the production version `0.1.0.r32.g3e39995.bounty-mcp-dispute`, and
static linker flags.
Missing cached Go dependencies or a static-link failure fail explicitly instead
of downloading or falling back. On success it verifies `--version`, confirms
that `file` and `ldd` report no shared-library dependency, prints SHA-256, and
atomically replaces `legacy-go-hotfix/out/lmm-api` with mode `0755`.
