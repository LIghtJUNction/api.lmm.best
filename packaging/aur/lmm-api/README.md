# LMM API split Arch packages

- `lmm-api` owns the shared launcher, service, and configuration.
- `lmm-api-go` is the stable production backend built from `apps/api-go`.
- `lmm-api-rs` is an optional, coinstallable preview built from `apps/api-rust`.

The packaged `/etc/lmm-api/backend.conf` explicitly selects `go`. If the Go
package is missing the service fails; it never falls through to Rust. `auto`
is retained only for development/testing and prefers Go when both exist.

Rust must be selected explicitly and configured with a dedicated
`lmm_preview_*` schema. Local packaging consumes existing artifacts from
`apps/api-go/out`, `apps/api-rust/target/release`, and `apps/web/dist`; it does
not install packages or contact a server.
