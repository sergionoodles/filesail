pkgname=filesail
pkgver="$(bash "$startdir/scripts/read-version.sh")"
pkgrel=1
pkgdesc='Quickshell-native file manager'
arch=('x86_64')
url='https://github.com/sergionoodles/filesail'
license=('MIT')
depends=('hicolor-icon-theme' 'libarchive' 'qt6-base' 'quickshell' 'udisks2' 'xdg-utils')
makedepends=('cmake' 'git' 'pkgconf')
checkdepends=('jq')
# This follows main until the first release tag exists. Pin this to a release
# tag or commit before publishing a stable AUR revision.
source=('filesail-checkout::git+https://github.com/sergionoodles/filesail.git#branch=main')
sha256sums=('SKIP')

# Keep makepkg's source cache, build tree, package staging tree, logs, and
# generated package archives together in a local, git-ignored directory.
BUILDDIR="$startdir/dist"
SRCDEST="$BUILDDIR"
PKGDEST="$BUILDDIR"
SRCPKGDEST="$BUILDDIR"
LOGDEST="$BUILDDIR"

build() {
    cmake -S "$srcdir/filesail-checkout" -B "$srcdir/filesail-build" \
        -DCMAKE_BUILD_TYPE=None \
        -DCMAKE_INSTALL_PREFIX=/usr
    cmake --build "$srcdir/filesail-build" --parallel
}

check() {
    ctest --test-dir "$srcdir/filesail-build" --output-on-failure
}

package() {
    DESTDIR="$pkgdir" cmake --install "$srcdir/filesail-build"

    # The optional Noctalia 5 plugin is packaged separately; this package keeps
    # only the standalone host's app-theme bridge.
}
