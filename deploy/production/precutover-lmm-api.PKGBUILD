# Reconstructs the exact pre-cutover core payload for one bounded rollback.
# It is not a public package definition and must only consume a captured root.

pkgname=lmm-api
pkgver="${LMM_PRECUTOVER_PKGVER:?}"
pkgrel="${LMM_PRECUTOVER_PKGREL:?}"
pkgdesc='LMM API pre-cutover core payload for release-scoped rollback'
arch=('x86_64')
license=('AGPL-3.0-only')
depends=('bash' 'coreutils' 'systemd')
backup=('etc/lmm-api/backend.conf' 'etc/lmm-api/lmm-api.env')
options=('!strip')
source=('core-root.tar')
sha256sums=('SKIP')

package() {
  cp -a -- "${srcdir}/root/." "${pkgdir}/"
}
