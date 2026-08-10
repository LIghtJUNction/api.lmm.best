# Local `lmm-api-go` package

The Go backend binary owns the local build and packaging workflow. It builds the
frontend, produces the static backend binary, validates both artifacts, and
creates a single `lmm-api-go` Arch package inside an explicit marker-owned
workspace. No launcher, provider selector, compatibility alias, Rust payload,
or deployment shell script is involved.

```bash
apps/api-go/out/lmm-api-go deploy build \
  --repo /absolute/path/to/api.lmm.best \
  --workspace /absolute/marker-owned/workspace
```
