---
name: review-open-source-bounty
description: >-
  Verify and settle api.lmm.best open-source bounty submissions using real
  repository, GitHub, CI, deployment, test, and MCP evidence. Use when the user
  asks to review, accept, approve, pay, reject, close, rate, merge, or dispute
  a bounty challenge or its linked Issue or pull request. Enforces current-state
  reads, truthful 1-5 ratings, exact approval or rejection previews, explicit
  confirmation, and synchronized MCP and GitHub outcomes.
---

# Review Open-source Bounty

Decide whether submitted work satisfies the publisher's contract, then settle
it transparently without fabricating evidence or letting GitHub and escrow
state drift apart.

## Operating Contract

- Use the `open_source_bounty_operator` prompt and the
  `open_source_bounties.*` tools from `https://api.lmm.best/mcp`.
- Use Streamable HTTP and the server-negotiated protocol version.
- Load bearer credentials from a secret source. Never print, commit, embed, or
  persist a personal MCP token.
- The publisher reviews completed work directly. An administrator intervenes
  only after either party opens a dispute.
- Read the current challenge, project, ratings, escrow, and GitHub state before
  changing anything.
- Never fabricate defects, Issues, pull requests, authorship, CI status, tests,
  deployments, benchmarks, review findings, dispute evidence, tips, or ratings.

## Review Workflow

### 1. Establish identity and state

1. Load the operator prompt and identify the authenticated account's role.
2. Read the bounty project and the exact challenge by its real ID.
3. Record the state, publisher, contributor, gross price, public fee, locked net
   reward, submission note, Issue URL, pull request URL, and existing ratings.
4. Read open disputes. If this challenge is disputed, treat it as frozen and do
   not approve, reject, merge, refund, or transfer escrow through an ordinary
   review path.
5. If the challenge has no submitted result, do not invent one or force a
   publisher review action that the state machine does not support.

### 2. Inspect the actual submission

Inspect every submitted artifact rather than trusting its title or completion
note:

- confirm Issue and pull request URLs belong to the claimed repository and
  describe the same work;
- inspect the full diff, commits, authorship, base branch, mergeability, CI
  checks, review threads, requested changes, and current open/closed state;
- compare the implementation against the bounty's acceptance criteria,
  exclusions, target platform, and promised scope;
- run proportionate tests locally and record exact commands and results;
- use designated infrastructure only when the user has authorized it, and
  identify the tested commit and environment;
- distinguish contributor-delivered work from changes authored or merged by
  the publisher or another contributor.

An Issue-only submission can be valid when the bounty explicitly rewards ideas
or reports. A code bounty normally requires the promised implementation and
tests. Apply the published rules, not an assumed universal requirement.

### 3. Apply repository-specific gates

For a Rust migration intended for this project's production path, approval
requires all of the following:

- deployment of the submitted commit to the designated Linux test server;
- successful smoke and integration tests on Linux;
- behavioral parity evidence against the Go implementation for affected
  routes, authentication, responses, errors, and persistence behavior;
- relevant performance evidence showing the migration does not regress the
  intended production workload;
- no unresolved correctness or security finding.

Do not accept Windows-only adaptation as satisfying a Linux-server migration.
If deployment or parity evidence is unavailable, report the review as
incomplete rather than claiming success.

### 4. Reach an evidence-based decision

Classify each criterion as passed, failed, or not verified and cite the real
evidence. A useful rating scale is:

- `5`: fully satisfies the contract with exemplary quality and evidence;
- `4`: fully satisfies it with only minor, non-blocking shortcomings;
- `3`: meets the stated acceptance threshold;
- `2`: meaningful effort, but incomplete, out of scope, or materially flawed;
- `1`: unusable or fundamentally contrary to the contract.

Choose the truthful score supported by the review; never adjust it to justify
a desired payment outcome. Write a concise public evaluation describing scope,
tests, findings, and the reason for approval or rejection.

### 5. Preview settlement and obtain confirmation

Invoke the intended approval or rejection action once to obtain the server's
`input_required` preview. Show the exact action plus:

- challenge, project, publisher, contributor/recipient, and public score;
- gross listed price, net reward, public fee, and escrow/balance impact;
- submitted URLs and completion note;
- concrete review evidence and public evaluation;
- whether the action pays, retains, refunds, or otherwise changes locked funds,
  exactly as the server reports.

Do not confirm approval, payment, rejection, closing/refunding, tipping,
rating, dispute opening/resolution, draft deletion, or withdrawal until the
user explicitly confirms that exact preview. Tips are non-refundable and
separate from escrow. If the preview changes, request confirmation again.

### 6. Settle and synchronize GitHub

After explicit confirmation, complete the MCP elicitation flow using the same
payload, then reread the challenge, project, ledger/escrow, ratings, and
disputes.

Synchronize GitHub with the verified outcome:

- Always leave a clear public comment on every affected Issue and pull request
  before closing it. State the decision, factual evidence, tests performed, and
  any remaining blocker. Do this even when a related thread already contains a
  similar explanation.
- For approval, merge only after required checks and tests pass and the diff is
  the reviewed commit. Then comment on and close the linked Issue when the work
  is complete.
- For rejection, comment with the specific failed scope or acceptance criteria,
  then close the pull request and linked Issue with the appropriate reason.
- Never close unrelated work merely because it was mentioned during the audit.
- Reread GitHub after mutation and verify the intended Issue/PR state.

Report the final MCP state, GitHub state, score, public evaluation, payment or
non-payment, fee and escrow effects, merge commit if any, and the tests actually
run. If MCP and GitHub disagree, stop and reconcile the discrepancy explicitly.

## Disputes and Mutual Ratings

If the publisher and contributor disagree, open a dispute only with the real
challenge ID and real evidence, after showing the server preview and receiving
explicit confirmation. An open dispute freezes ordinary settlement until a
third-party administrator records a conclusion and, when justified, transfers
the locked reward from escrow.

After review, the contributor may truthfully rate the publisher/verifier. Both
sides can see mutual ratings and historical averages. Never submit a rating on
someone else's behalf or infer a score the rater did not choose.
