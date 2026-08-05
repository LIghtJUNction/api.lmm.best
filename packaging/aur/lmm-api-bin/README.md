# `lmm-api-bin` AUR package

This package installs the prebuilt, static Go backend from a tagged GitHub
release. It supports Arch Linux `x86_64` and `aarch64` and does not invoke Go,
Bun, or any project compiler on the target host.

Each downloaded archive is checked against its published SHA-256 digest and
its keyless Sigstore bundle. Verification pins the repository, release
workflow, and exact tag before the binary is installed.

For a release, set `pkgver` in `PKGBUILD` to the version from the published
`v${pkgver}` tag, regenerate `.SRCINFO`, run `test-package.sh`, then publish
these two files to the `lmm-api-bin` AUR package repository:

```bash
makepkg --printsrcinfo > .SRCINFO
./test-package.sh
```

The GitHub release must be published first because AUR package sources must
already be downloadable when the AUR update lands.
