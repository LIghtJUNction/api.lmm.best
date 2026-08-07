# AUR package matrix

The public packages are split into a shared core and one selectable backend:

| Component | Prebuilt release | Build from Git |
| --- | --- | --- |
| Shared launcher, service, configuration, and frontend | `lmm-api-bin` | `lmm-api-git` |
| Go backend | `lmm-api-go-bin` | `lmm-api-go-git` |
| Rust backend and migrator | `lmm-api-rs-bin` | `lmm-api-rs-git` |

Install exactly one core package and at least one backend package. Both core
packages provide the virtual `lmm-api` dependency. Backend variants provide
`lmm-api-go` or `lmm-api-rs`, and the `-bin`/`-git` variants of the same
component conflict with one another.

The default backend selection is `auto`: Go is preferred when installed,
otherwise Rust is used. Use `lmm-api select auto|go|rs|status` to inspect or
persist the backend choice. Deployment and serving are subcommands of the
single `/usr/bin/lmm-api` CLI (`lmm-api deploy ...` and `lmm-api serve`).

Run `bash packaging/aur/test-matrix.sh` after changing any `PKGBUILD`, and
regenerate each `.SRCINFO` with `makepkg --printsrcinfo > .SRCINFO`.
