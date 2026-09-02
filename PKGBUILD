pkgbase=filesail
pkgname=(filesail filesail-noctalia)
pkgver=0.1.0
pkgrel=1
pkgdesc='Quickshell-native file manager'
arch=('x86_64')
url='https://github.com/sergionoodles/filesail'
license=('MIT')
makedepends=('cmake' 'git' 'libarchive' 'pkgconf' 'qt6-base')
checkdepends=('jq')
# This follows main until the first release tag exists. Pin this to a release
# tag or commit before publishing a stable AUR revision.
source=('filesail::git+https://github.com/sergionoodles/filesail.git#branch=main')
sha256sums=('SKIP')

build() {
    cmake -S "$srcdir/filesail" -B "$srcdir/build" \
        -DCMAKE_BUILD_TYPE=None \
        -DCMAKE_INSTALL_PREFIX=/usr
    cmake --build "$srcdir/build" --parallel
}

check() {
    ctest --test-dir "$srcdir/build" --output-on-failure
}

package_filesail() {
    pkgdesc='Quickshell-native file manager'
    depends=('hicolor-icon-theme' 'libarchive' 'qt6-base' 'quickshell' 'xdg-utils')
    optdepends=('tumbler: thumbnail generation through the freedesktop thumbnail service')

    DESTDIR="$pkgdir" cmake --install "$srcdir/build"

    # The standalone host needs the config-file theme provider, while the
    # Noctalia-only entry points belong to filesail-noctalia.
    rm -f \
        "$pkgdir/usr/share/filesail/integrations/noctalia/BarWidget.qml" \
        "$pkgdir/usr/share/filesail/integrations/noctalia/Panel.qml" \
        "$pkgdir/usr/share/filesail/integrations/noctalia/NoctaliaThemeProvider.qml"
}

package_filesail-noctalia() {
    pkgdesc='Noctalia panel and bar integration for FileSail'
    depends=('filesail' 'noctalia-shell')

    local plugin_root="$pkgdir/usr/share/filesail/noctalia-plugin"
    install -d "$plugin_root/integrations/noctalia"

    install -Dm644 "$srcdir/filesail/manifest.json" \
        "$plugin_root/manifest.json"
    install -Dm644 "$srcdir/filesail/integrations/noctalia/BarWidget.qml" \
        "$plugin_root/integrations/noctalia/BarWidget.qml"
    install -Dm644 "$srcdir/filesail/integrations/noctalia/Panel.qml" \
        "$plugin_root/integrations/noctalia/Panel.qml"
    install -Dm644 "$srcdir/filesail/integrations/noctalia/NoctaliaThemeProvider.qml" \
        "$plugin_root/integrations/noctalia/NoctaliaThemeProvider.qml"

    # Panel.qml imports ../../qml and BarWidget.qml loads ../../logo.png. Keep
    # the plugin payload separate while sharing the filesail package's assets.
    ln -s ../qml "$plugin_root/qml"
    ln -s ../logo.png "$plugin_root/logo.png"

    install -Dm755 "$srcdir/filesail/scripts/install-noctalia-package.sh" \
        "$pkgdir/usr/bin/filesail-noctalia-install"
}
