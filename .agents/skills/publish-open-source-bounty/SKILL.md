---
name: publish-open-source-bounty
description: >-
  Safely draft, price, and publish open-source bounties through the
  api.lmm.best Open-source bounties MCP service. Use when the user wants to
  create or update a bounty draft, publish a bounty project, choose a gross
  price or number of fixes, inspect platform fees and escrow, or fund a
  listing from their balance. Enforces factual evidence, current-state reads,
  an exact financial preview, and explicit confirmation before publication.
---

# Publish Open-source Bounty

Publish a real, auditable peer-to-peer bounty without inventing work or moving
funds before the publisher understands the transaction.

## Operating Contract

- Use the `open_source_bounty_operator` prompt and the
  `open_source_bounties.*` tools from `https://api.lmm.best/mcp`.
- Use Streamable HTTP and negotiate a protocol version supported by the
  server. Do not hard-code a version the server did not negotiate.
- Obtain the bearer credential from a secret source. Never print it, write it
  to the repository, put it in generated skill content, or persist it in a
  script, log, transcript, or shell history.
- Treat a bounty as a transaction between the publisher and contributor. An
  administrator is not a routine reviewer and intervenes only in a dispute.
- Read current server state before every mutation. Never rely on an earlier
  conversation snapshot for balance, fees, project state, or ownership.
- Never fabricate a defect, GitHub Issue, pull request, test result, evidence,
  participant, rating, or expected outcome.

## Publishing Workflow

### 1. Load authoritative context

1. Load the `open_source_bounty_operator` prompt.
2. Identify the authenticated account and whether it is the enabled super
   administrator.
3. Read owned projects and any existing draft matching the request.
4. Read the current available balance, public platform-fee configuration, and
   relevant ledger state.
5. If the bounty refers to a repository defect or enhancement, inspect the
   real repository and linked Issue before drafting. Create external artifacts
   only when the user has authorized their creation.

Daily check-in rewards belong to the same balance and may fund a listing, but
never claim a check-in occurred without reading the ledger result.

### 2. Define a verifiable contract

Write a focused draft containing:

- the repository and exact problem or requested outcome;
- objective acceptance criteria and required evidence;
- allowed submission forms: a matching GitHub Issue URL, pull request URL, or
  both, plus an optional completion note;
- required tests, target platform, compatibility constraints, and exclusions;
- the number of payable fixes and gross listed price per fix;
- any deadline or review expectations supported by the service.

Keep each fix independently reviewable. Do not disguise unrelated work as one
submission. The public board ranks listings by gross price per fix, so report
that value exactly and do not optimize wording to manipulate ranking.

For Rust migrations in this repository, require deployment to the designated
Linux test server, behavioral parity with the Go implementation, relevant
integration tests, and performance evidence before acceptance. Windows-only
adaptation is not a production requirement unless the publisher explicitly
changes the target.

### 3. Create or update the draft

Use the matching draft tool, then immediately reread the draft. Compare every
server-returned field with the intended repository, scope, price, fix count,
and acceptance criteria. If anything differs, correct the draft before
requesting publication.

Draft creation is not publication. Do not describe escrow as locked until the
publish operation succeeds.

### 4. Preview the transaction

Invoke the publication action once to obtain its `input_required` preview.
Show the user the server's exact proposed action and all of the following:

- publisher and recipient/escrow destination;
- public score or rating field, if present;
- gross price per fix, fix count, and gross total debit;
- public platform fee;
- net contributor reward per fix and total net escrow;
- relevant evidence and acceptance criteria;
- current balance, resulting balance, and net balance decrease.

Publishing debits the gross total, credits the public fee to the enabled super
administrator, and locks the remaining net rewards in escrow. If the publisher
is also that super administrator, explicitly report both the gross debit and
fee credit; the account's net balance decrease is gross debit minus fee credit.
Use server-returned amounts rather than recomputing over rounding differences.

Do not publish until the user explicitly confirms this exact preview. A vague
earlier instruction to manage bounties is not confirmation of a later monetary
preview. If any value changes, discard the old confirmation and obtain a new
preview and confirmation.

### 5. Publish and verify

After explicit confirmation:

1. Complete the server's elicitation/confirmation flow without changing the
   confirmed payload.
2. Reread the project, balance, escrow/ledger entries, and public listing.
3. Verify the listing is published and the financial entries reconcile.
4. Report the project/challenge identifiers, gross debit, fee credit, net
   escrow, and resulting balance. If the authenticated user is the super
   administrator, also report the true net balance decrease.

Stop and report a mismatch instead of retrying a monetary mutation blindly.
Publication, withdrawal, draft deletion, closing/refunding, tipping, rating,
and dispute actions each require their own server preview and explicit user
confirmation. Tips are separate, non-refundable transactions and are never
implicitly included in a bounty price.
