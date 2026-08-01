# Frozen Go compatibility evidence

This directory makes the last Go backend revision independently auditable after
the working-tree Go sources are archived or removed.

- `go-provenance.json` pins the immutable Git commit/tree, archive selection,
  counts, byte totals, and aggregate hashes.
- `go-source-blobs.tsv` records every archived Go source or module input as
  path, Git mode, blob object, byte length, and SHA-256.
- `contract-assets.tsv` maps selected legacy runtime/test contracts to tracked
  Rust migration inputs under `rust/contracts/legacy` and
  `rust/fixtures/legacy-relayconvert`.

Run `rust/crates/lmm-db-migrate/scripts/verify-provenance.sh` from any checkout
that still has the pinned Git objects. The verifier reads source bytes from Git,
not from the working tree, so ignored backup files are never a build or release
dependency.

The copied assets are compatibility oracles, not generated Rust
implementations. Rust ports must preserve their observable behavior and should
add native Rust tests that consume these fixtures.
