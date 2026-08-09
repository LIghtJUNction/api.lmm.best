# AUR packages

Each backend is a self-contained binary and CLI. There is no shared launcher,
provider selector, compatibility alias, or unsuffixed `lmm-api` command.

| Backend | Stable source | Prebuilt release | Build from Git | Installed command |
| --- | --- | --- | --- | --- |
| Go | `lmm-api-go` | `lmm-api-go-bin` | `lmm-api-go-git` | `/usr/bin/lmm-api-go` |
| Rust | — | `lmm-api-rs-bin` | `lmm-api-rs-git` | `/usr/bin/lmm-api-rs` |

The Go packages also install the built frontend, `lmm-api-go.service`, and the
private `/etc/lmm-api-go/lmm-api-go.env` configuration file. The service runs
`lmm-api-go serve` directly.

Install the canonical source package with `paru -S lmm-api-go`. Use
`lmm-api-go-bin` only when a matching signed GitHub release exists, or
`lmm-api-go-git` when explicitly following the moving `main` branch.

The Rust packages remain separate until the Rust backend satisfies the same
native CLI and production route contract. They never stand behind a shell
dispatcher.

Run `bash packaging/aur/test-matrix.sh` after changing a `PKGBUILD`, and
regenerate each tracked `.SRCINFO` with `makepkg --printsrcinfo > .SRCINFO`.
