# AUR packages

Each backend ships its own provider binary. The Go package also provides the
canonical `lmm-api` command as a symlink to `lmm-api-go`, so systemd can use a
stable service contract while the provider remains replaceable.

| Backend | Stable source | Prebuilt release | Build from Git | Installed command |
| --- | --- | --- | --- | --- |
| Go | `lmm-api-go` | `lmm-api-go-bin` | `lmm-api-go-git` | `/usr/bin/lmm-api` → `lmm-api-go` |
| Rust | — | `lmm-api-rs-bin` | `lmm-api-rs-git` | `/usr/bin/lmm-api-rs` |

The Go packages also install the built frontend, `lmm-api.service`, and the
private `/etc/lmm-api-go/lmm-api-go.env` configuration file. The service runs
`/usr/bin/lmm-api serve` through the provider symlink.

Install the canonical source package with `paru -S lmm-api-go`. Use
`lmm-api-go-bin` only when a matching signed GitHub release exists, or
`lmm-api-go-git` when explicitly following the moving `main` branch.

The Rust packages remain separate until the Rust backend satisfies the same
native CLI and production route contract. A Rust cutover must atomically
replace the provider symlink and pass the route gate first.

Run `bash packaging/aur/test-matrix.sh` after changing a `PKGBUILD`, and
regenerate each tracked `.SRCINFO` with `makepkg --printsrcinfo > .SRCINFO`.
