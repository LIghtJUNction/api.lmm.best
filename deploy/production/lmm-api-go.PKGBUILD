# Maintainer: LMM API maintainers

pkgname=lmm-api-go
pkgver="${LMM_API_PKGVER:?LMM_API_PKGVER is required}"
pkgrel=1
pkgdesc='LMM API stable Go backend'
arch=('x86_64')
url='https://github.com/LIghtJUNction/api.lmm.best'
license=('AGPL-3.0-only')
depends=('lmm-api>=0.1.0')
provides=("lmm-api-go-backend=${pkgver}" "new-api=${pkgver}")
conflicts=('new-api' 'new-api-git')
options=('!strip')
source=('lmm-api')
sha256sums=('SKIP')

package() {
  install -Dm0755 "$srcdir/lmm-api" \
    "$pkgdir/usr/lib/lmm-api/backends/go/lmm-api"
}
