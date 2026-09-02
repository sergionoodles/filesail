pkgname=filesail
pkgver=0.1.0
pkgrel=1
pkgdesc='Quickshell-native file manager'
arch=('x86_64')
url='https://github.com/sergionoodles/filesail'
license=('MIT')
depends=('hicolor-icon-theme' 'libarchive' 'qt6-base' 'quickshell' 'xdg-utils')
makedepends=('cmake' 'git' 'pkgconf')
checkdepends=('jq')
# This follows main until the first release tag exists. Pin this to a release
# tag or commit before publishing a stable AUR revision.
source=('filesail::git+https://github.com/sergionoodles/filesail.git#branch=main')
sha256sums=('SKIP')

build() {
    cmake -S "$srcdir/filesail" -B "$srcdir/filesail-build" \
        -DCMAKE_BUILD_TYPE=None \
        -DCMAKE_INSTALL_PREFIX=/usr
    cmake --build "$srcdir/filesail-build" --parallel
}

check() {
    ctest --test-dir "$srcdir/filesail-build" --output-on-failure
}

package() {
    DESTDIR="$pkgdir" cmake --install "$srcdir/filesail-build"

    # The standalone host needs the config-file theme provider, while the
    # Noctalia manifest and entry points belong to filesail-noctalia.
    rm -f \
        "$pkgdir/usr/share/filesail/manifest.json" \
        "$pkgdir/usr/share/filesail/integrations/noctalia/BarWidget.qml" \
        "$pkgdir/usr/share/filesail/integrations/noctalia/Panel.qml" \
        "$pkgdir/usr/share/filesail/integrations/noctalia/NoctaliaThemeProvider.qml"
}
