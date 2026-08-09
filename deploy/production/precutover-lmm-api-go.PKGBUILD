# Reconstructs the exact pre-cutover Go provider payload for one bounded
# rollback. The new installation never exposes this provider layout.

pkgname=lmm-api-go
pkgver="${LMM_PRECUTOVER_PKGVER:?}"
pkgrel="${LMM_PRECUTOVER_PKGREL:?}"
pkgdesc='LMM API Go pre-cutover payload for release-scoped rollback'
arch=('x86_64')
license=('AGPL-3.0-only')
options=('!strip')
source=('go-root.tar')
sha256sums=('SKIP')

package() {
  cp -a -- "${srcdir}/root/." "${pkgdir}/"
}
