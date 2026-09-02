#!/usr/bin/env bash
set -euo pipefail

project_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
build_dir="${FILESAIL_BUILD_DIR:-$project_dir/build-appimage}"
appdir="${FILESAIL_APPDIR:-$build_dir/AppDir}"
output_dir="${FILESAIL_OUTPUT_DIR:-$project_dir/dist}"
tools_dir="${FILESAIL_APPIMAGE_TOOLS_DIR:-$build_dir/appimage-tools}"

case "$(uname -m)" in
    x86_64) appimage_arch=x86_64 ;;
    aarch64|arm64) appimage_arch=aarch64 ;;
    *) printf 'Unsupported AppImage architecture: %s\n' "$(uname -m)" >&2; exit 1 ;;
esac

version="$("$project_dir/scripts/read-version.sh")"
output_file="$output_dir/FileSail-${version}-${appimage_arch}.AppImage"

linuxdeploy_url="https://github.com/linuxdeploy/linuxdeploy/releases/download/continuous/linuxdeploy-${appimage_arch}.AppImage"
qt_plugin_url="https://github.com/linuxdeploy/linuxdeploy-plugin-qt/releases/download/continuous/linuxdeploy-plugin-qt-${appimage_arch}.AppImage"
appimagetool_url="https://github.com/AppImage/appimagetool/releases/download/continuous/appimagetool-${appimage_arch}.AppImage"

download_tool() {
    local destination="$1"
    local url="$2"

    if [[ -x "$destination" ]]; then
        return
    fi
    mkdir -p -- "$(dirname -- "$destination")"
    if ! command -v curl >/dev/null 2>&1; then
        printf '%s\n' 'curl is required to download AppImage packaging tools.' >&2
        exit 1
    fi
    printf 'Downloading %s\n' "$url"
    curl --fail --location --retry 3 --output "$destination.tmp" "$url"
    mv -- "$destination.tmp" "$destination"
    chmod +x -- "$destination"
}

if [[ -n "${FILESAIL_LINUXDEPLOY:-}" ]]; then
    linuxdeploy="$FILESAIL_LINUXDEPLOY"
else
    linuxdeploy="$tools_dir/linuxdeploy-${appimage_arch}.AppImage"
    download_tool "$linuxdeploy" "$linuxdeploy_url"
fi
if [[ -n "${FILESAIL_QT_PLUGIN:-}" ]]; then
    qt_plugin="$FILESAIL_QT_PLUGIN"
else
    qt_plugin="$tools_dir/linuxdeploy-plugin-qt-${appimage_arch}.AppImage"
    download_tool "$qt_plugin" "$qt_plugin_url"
fi
if [[ -n "${FILESAIL_APPIMAGETOOL:-}" ]]; then
    appimagetool="$FILESAIL_APPIMAGETOOL"
else
    appimagetool="$tools_dir/appimagetool-${appimage_arch}.AppImage"
    download_tool "$appimagetool" "$appimagetool_url"
fi
for tool in "$linuxdeploy" "$qt_plugin" "$appimagetool"; do
    if [[ ! -x "$tool" ]]; then
        printf 'AppImage packaging tool is not executable: %s\n' "$tool" >&2
        exit 1
    fi
done

qs_path="${FILESAIL_QS_PATH:-}"
if [[ -z "$qs_path" ]]; then
    qs_path="$(command -v qs || command -v quickshell || true)"
fi
if [[ -z "$qs_path" || ! -x "$qs_path" ]]; then
    printf '%s\n' 'Quickshell was not found. Install qs/quickshell or set FILESAIL_QS_PATH.' >&2
    exit 1
fi
qs_path="$(readlink -f -- "$qs_path")"
qs_qml_dir="${FILESAIL_QS_QML_DIR:-}"

qmake_path="${FILESAIL_QMAKE:-}"
if [[ -z "$qmake_path" ]]; then
    qmake_path="$(command -v qmake6 || command -v qmake || true)"
fi
if [[ -z "$qmake_path" || ! -x "$qmake_path" ]]; then
    printf '%s\n' 'qmake6/qmake was not found. Install Qt development tools or set FILESAIL_QMAKE.' >&2
    exit 1
fi
qmake_path="$(readlink -f -- "$qmake_path")"
qt_qml_dir="$("$qmake_path" -query QT_INSTALL_QML)"
if [[ ! -d "$qt_qml_dir" ]]; then
    printf 'Qt QML directory not found: %s\n' "$qt_qml_dir" >&2
    exit 1
fi
if [[ -z "$qs_qml_dir" ]]; then
    qs_qml_dir="$(dirname -- "$qs_path")/../lib/qt6/qml"
fi
if [[ ! -d "$qs_qml_dir/Quickshell" ]]; then
    qs_qml_dir="$qt_qml_dir"
fi
qt_plugins_dir="$("$qmake_path" -query QT_INSTALL_PLUGINS)"
wayland_platform_plugins=""
for plugin in libqwayland-egl.so libqwayland-generic.so libqwayland.so; do
    if [[ -f "$qt_plugins_dir/platforms/$plugin" ]]; then
        wayland_platform_plugins="${wayland_platform_plugins:+$wayland_platform_plugins;}$plugin"
    fi
done
if [[ -z "$wayland_platform_plugins" ]]; then
    printf 'Qt Wayland platform plugin not found under: %s/platforms\n' "$qt_plugins_dir" >&2
    exit 1
fi
qt_plugin_source_dir="$build_dir/qt-plugins"
rm -rf -- "$qt_plugin_source_dir"
mkdir -p -- "$qt_plugin_source_dir/platforms" "$qt_plugin_source_dir/imageformats"
for plugin in libqxcb.so libqwayland-egl.so libqwayland-generic.so libqwayland.so; do
    if [[ -f "$qt_plugins_dir/platforms/$plugin" ]]; then
        cp -a -- "$qt_plugins_dir/platforms/$plugin" "$qt_plugin_source_dir/platforms/"
    fi
done
for plugin in libqgif.so libqico.so libqjpeg.so libqsvg.so libqwebp.so; do
    if [[ -f "$qt_plugins_dir/imageformats/$plugin" ]]; then
        cp -a -- "$qt_plugins_dir/imageformats/$plugin" "$qt_plugin_source_dir/imageformats/"
    fi
done
qmake_wrapper="$build_dir/qmake-wrapper"
install -Dm755 -- "$project_dir/packaging/appimage/qmake-wrapper" "$qmake_wrapper"
qml_sources_dir="$build_dir/qml-sources"
rm -rf -- "$qml_sources_dir"
mkdir -p -- "$qml_sources_dir/integrations/noctalia"
cp -a -- "$project_dir/qml" "$qml_sources_dir/"
cp -a -- "$project_dir/shell.qml" "$qml_sources_dir/"
cp -a -- "$project_dir/integrations/noctalia/NoctaliaConfigThemeProvider.qml" \
    "$qml_sources_dir/integrations/noctalia/"

rm -rf -- "$appdir"
mkdir -p -- "$appdir" "$output_dir"

cmake -S "$project_dir" -B "$build_dir" \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_INSTALL_PREFIX=/usr
cmake --build "$build_dir" --parallel
ctest --test-dir "$build_dir" --output-on-failure
DESTDIR="$appdir" cmake --install "$build_dir"

# The AppImage is the standalone host. Keep the Noctalia-only panel adapter out
# of its QML scan; it imports qs.Commons and qs.Services.UI from Noctalia.
rm -f -- \
    "$appdir/usr/share/filesail/integrations/noctalia/BarWidget.qml" \
    "$appdir/usr/share/filesail/integrations/noctalia/Panel.qml" \
    "$appdir/usr/share/filesail/integrations/noctalia/NoctaliaThemeProvider.qml"

# The standalone launcher uses the bundled runtime when APPDIR is set. The
# Quickshell modules are statically linked into qs, but their qmldir/QML files
# are still needed for imports such as Quickshell.Io and Quickshell.Widgets.
install -Dm755 -- "$qs_path" "$appdir/usr/bin/qs"
mkdir -p -- "$appdir/usr/qml"
cp -a -- "$qs_qml_dir/Quickshell" "$appdir/usr/qml/"
install -Dm644 -- "$project_dir/packaging/appimage/qt.conf" "$appdir/usr/bin/qt.conf"
install -Dm755 -- "$project_dir/packaging/appimage/AppRun" "$appdir/AppRun"

rm -f -- "$output_file"
(
    export APPIMAGE_EXTRACT_AND_RUN=1
    export FILESAIL_REAL_QMAKE="$qmake_path"
    export FILESAIL_QT_PLUGIN_SOURCE="$qt_plugin_source_dir"
    export QMAKE="$qmake_wrapper"
    export PATH="$(dirname -- "$qt_plugin"):$PATH"
    export QML_SOURCES_PATHS="$qml_sources_dir"
    export QML_MODULES_PATHS="$appdir/usr/qml:$qt_qml_dir:$qs_qml_dir"
    export EXTRA_PLATFORM_PLUGINS="$wayland_platform_plugins"
    export NO_STRIP=1
    "$linuxdeploy" \
        --appdir "$appdir" \
        --executable "$appdir/usr/bin/qs" \
        --executable "$appdir/usr/bin/filesail-backend" \
        --plugin qt
    ln -sfn -- usr/share/applications/dev.filesail.FileSail.desktop \
        "$appdir/dev.filesail.FileSail.desktop"
    ln -sfn -- usr/share/icons/hicolor/1200x1200/apps/filesail.png "$appdir/filesail.png"
    ARCH="$appimage_arch" "$appimagetool" "$appdir" "$output_file"
)

chmod +x -- "$output_file"
printf 'Built %s\n' "$output_file"
