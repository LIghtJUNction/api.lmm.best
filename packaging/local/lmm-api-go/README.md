# Local `lmm-api-go` package

This builder packages one already-frozen Go backend binary together with the
built frontend. It writes only inside an explicit marker-owned deployment
workspace and creates a single `lmm-api-go` package. No launcher, provider
selector, compatibility alias, or Rust payload is included.

```bash
bash packaging/local/lmm-api-go/build-local-package.sh \
  --workspace /absolute/marker-owned/workspace \
  --binary /absolute/path/to/lmm-api-go \
  --frontend /absolute/path/to/apps/web/dist
```
