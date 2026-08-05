# LMM API split Arch packages

- `lmm-api` owns the shared launcher, service, and configuration.
- `lmm-api-go` is the stable production backend built from `apps/api-go`.
- `lmm-api-rs` is an optional, coinstallable preview built from `apps/api-rust`.

The packaged `/etc/lmm-api/backend.conf` selects `auto`, which prefers Go when
both backends are installed and otherwise uses Rust. An explicit `go` or `rs`
selection never silently falls back to the other backend.

Rust still requires a dedicated `lmm_preview_*` schema. Local packaging
consumes existing artifacts from `apps/api-go/out`,
`apps/api-rust/target/release`, and `apps/web/dist`; it does not install
packages or contact a server.
