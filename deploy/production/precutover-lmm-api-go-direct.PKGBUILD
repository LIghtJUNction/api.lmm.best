# Reconstructs the exact direct lmm-api-go package payload for one bounded
# rollback. Production configuration values are restored from the separately
# verified configuration archive, so the package carries only an empty backup
# file at that path.

pkgname=lmm-api-go
pkgver="${LMM_PRECUTOVER_PKGVER:?}"
pkgrel="${LMM_PRECUTOVER_PKGREL:?}"
pkgdesc='LMM API direct Go payload for release-scoped rollback'
arch=('x86_64')
license=('AGPL-3.0-only')
depends=('ca-certificates' 'systemd' 'tzdata')
optdepends=(
  'postgresql: production database'
  'valkey: cache, rate limiting, and login sessions'
)
conflicts=('lmm-api' 'lmm-api-bin' 'lmm-api-git' 'lmm-api-go-bin' 'lmm-api-go-git')
backup=('etc/lmm-api-go/lmm-api-go.env')
options=('!strip')
source=('go-root.tar')
sha256sums=('SKIP')

package() {
  cp -a -- "${srcdir}/root/." "${pkgdir}/"
}
