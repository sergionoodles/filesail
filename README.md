# FileSail

FileSail is a Quickshell-native file manager designed for tiled Wayland
desktops. The first host targets Noctalia on Niri; the UI and backend are kept
portable for Omarchy/Hyprland. The standalone window follows the Noctalia
palette through Noctalia 5 app theming.

![FileSail screenshot](docs/screenshot.jpg)

The current MVP scaffold includes:

- details/list and icon-grid browsing;
- breadcrumbs, editable address (`Ctrl+L`), back/forward/up, and filtering;
- multi-selection, create folder, rename, copy, move, and Trash-by-default;
- XDG default-application opening;
- an optional preview pane for images, thumbnails, text, archives, and metadata;
- persistent display preferences in `~/.config/filesail/config.json`;
- a normal tiled window and a Noctalia 5 native slideout panel;
- a stateless `filesail-cli` for discovering and controlling live browser windows.

## Dependencies

FileSail runs on Linux under a Wayland compositor. The standalone host requires
Quickshell 0.3.1 or newer (`qs` or `quickshell`), a working D-Bus session, and
`xdg-utils` for opening files and folders with the desktop defaults. Thumbnail
previews require a thumbnailer service such as Tumbler, but FileSail can run
without one.

To build from source, install:

- CMake 3.24 or newer;
- a C++20 compiler;
- Qt 6.6 or newer with the Core, Concurrent, and DBus components, including the
  Qt Wayland platform plugin;
- `libarchive` and its development files;
- `pkg-config` (or an equivalent `pkgconf` implementation); and
- Quickshell.

The AppImage bundles FileSail, its backend, Qt, and the Quickshell runtime. It
still needs a Linux/Wayland desktop session and the host libraries required by
your compositor. `xdg-utils` is recommended for opening files from the
AppImage.

## Build the backend

```sh
cmake -S . -B build
cmake --build build
ctest --test-dir build --output-on-failure
```

To package the current checkout, including uncommitted changes, use:

```sh
./scripts/makepkg_local.sh --install
```

Without `--install`, the helper only builds the package. It uses a temporary
source snapshot and leaves the repository `PKGBUILD` unchanged.

## Install the standalone host

```sh
cmake --install build
```

This installs the `filesail` launcher, `filesail-cli`, backend, desktop entry,
QML tree, and Noctalia app-theme bridge using CMake's configured install prefix.
The checkout remains usable for Noctalia plugin development through
`scripts/install-noctalia.sh`.

The optional `org.freedesktop.FileManager1` integration is not included in the
standard package or AppImage. Arch users can opt in by building the separate
package in `integrations/dbus`; it depends on `filesail` and installs a user
service that can claim the session-bus name without replacing Nautilus files.
Enable it with:

```sh
systemctl --user enable --now filesail-filemanager1.service
```

Disable it with:

```sh
systemctl --user disable --now filesail-filemanager1.service
```

## Install from an Arch package

`PKGBUILD` builds the standalone package and declares its runtime dependencies:
`hicolor-icon-theme`, `libarchive`, `qt6-base`, `quickshell`, and `xdg-utils`.
Build and install it from the repository root with:

```sh
makepkg -si
```

The package build also uses CMake, Git, and `pkgconf`; `jq` is used by the
package checks. To add the Noctalia 5 bar integration after installing
FileSail, build the optional package in `integrations/noctalia`:

```sh
cd integrations/noctalia
makepkg -si
```

The Noctalia package depends on both `filesail` and Noctalia 5. Its plugin uses
API level 24, introduced with Noctalia 5.0.0-beta.9.

## Install the AppImage

Download the AppImage from a GitHub release or workflow artifact, make it
executable, and launch it:

```sh
chmod +x FileSail-*-x86_64.AppImage
./FileSail-*-x86_64.AppImage
```

AppImages are self-contained and do not need to be installed system-wide. The
filename uses the version in `VERSION` and the machine architecture.

## Build an AppImage

The AppImage bundles FileSail, its backend, and the Quickshell runtime used by
the standalone host. Install the source-build dependencies above, plus `curl`
to download the linuxdeploy tools on the first run.

```sh
./scripts/build-appimage.sh
./dist/FileSail-$(tr -d '\n' < VERSION)-x86_64.AppImage
```

Use `FILESAIL_QS_PATH` when the Quickshell executable is not named `qs` or
`quickshell`. `FILESAIL_BUILD_DIR`, `FILESAIL_APPDIR`, and
`FILESAIL_OUTPUT_DIR` can be used to relocate intermediate and output files.

Tagged pushes (`v*`) and manual runs build the same AppImage in GitHub Actions
and upload it as an artifact. Tagged pushes also attach it to the GitHub
release.

## Run as a tiled window

```sh
./scripts/run.sh
./scripts/run.sh ~/Downloads
```

The launcher activates the existing standalone host when one is running, so
separate compositor-managed windows share one Quickshell engine and backend.
Use `--new-instance` temporarily when testing an isolated duplicate host.

## Control FileSail from an agent or terminal

`filesail-cli` is a stateless JSON CLI for discovering and controlling live
standalone FileSail browser windows. It prints exactly one compact JSON
document to stdout, writes diagnostics to stderr, and exits nonzero when the
response has `"ok": false`.

Build it from the checkout and put the executable on the agent's `PATH`:

```sh
cmake -S . -B build
cmake --build build --target filesail-cli
export PATH="$PWD/build:$PATH"
```

For a persistent per-user install, copy it to `~/.local/bin` (and make sure
that directory is on the `PATH` inherited by your agent):

```sh
install -Dm755 build/filesail-cli "$HOME/.local/bin/filesail-cli"
export PATH="$HOME/.local/bin:$PATH"
```

Start FileSail with `./scripts/run.sh` or the installed `filesail` launcher,
then discover a window and keep using its returned opaque ID:

```sh
filesail-cli windows list
filesail-cli windows ensure
filesail-cli --window WINDOW_ID state
filesail-cli --window WINDOW_ID entries --limit 100
filesail-cli --window WINDOW_ID navigate --location downloads
filesail-cli --window WINDOW_ID select --path /absolute/path/to/report.pdf
filesail-cli --window WINDOW_ID preview show
```

`windows list` and `state` are useful read-only discovery calls. Use
`windows ensure` when one window should exist, or `windows create` when a new
window is always required. Omitting `--window` is safe only when exactly one
browser is eligible; otherwise the CLI returns `no_window` or
`ambiguous_target`. Named locations such as `downloads`, `documents`, and
`trash` use XDG resolution, while direct paths must be absolute.

Commands wait for their terminal result by default. For asynchronous work,
add `--no-wait`, save the returned request ID, and query it later:

```sh
filesail-cli --window WINDOW_ID --no-wait navigate --location downloads
filesail-cli result REQUEST_ID
```

Use `events --since SEQUENCE` to consume changes incrementally. Selection paths
must be absolute paths returned by `entries`; the CLI intentionally does not
launch files, run shell commands, permanently delete files, or expose general
filesystem mutations. See [the complete CLI contract](docs/control-cli.md)
for command schemas, targeting, cursors, events, and error handling.

### Install the agent skill

The repository includes the `filesail-control` skill, which teaches an agent
how to discover FileSail windows and use the CLI safely. Install it through
[skills.sh](https://skills.sh) with:

```sh
npx skills add sergionoodles/filesail --skill "filesail-control"
```

Run the command in the project or agent environment where the skill should be
available. The agent must also be able to resolve `filesail-cli` on its `PATH`
as shown above. Use `npx skills update` later to refresh installed skills.

To slow transfers down while evaluating the activity queue, set the optional
development-only delay before launching FileSail. The delay is applied after
each transfer chunk and is measured in milliseconds:

```sh
FILESAIL_DEV_TRANSFER_DELAY_MS=150 ./scripts/run.sh --new-instance
```

## Follow the Noctalia theme

Standalone FileSail automatically registers a Noctalia 5 user template on first
launch. Noctalia renders its resolved app palette to
`~/.config/filesail/theme.json`; open FileSail windows follow changes without a
restart, including wallpaper palettes and light/dark mode. Color transitions
respect Noctalia's animation setting. UI scaling follows its effective config,
including profiles and GUI overrides. Paths honor XDG and Noctalia home overrides.

The integration creates `~/.config/noctalia/filesail.toml` and
`~/.config/noctalia/templates/filesail.json`. Existing template registrations
are preserved. If your config uses `[include] autoload = false`, include
`filesail.toml` explicitly. For read-only configurations, declare the
`[theme.templates.user.filesail]` entry yourself with the bundled
`integrations/noctalia/theme-template.json` as `input_path` and
`$XDG_CONFIG_HOME/filesail/theme.json` as `output_path`.

Set `enabled = false` on that template to stop automatic generation. FileSail
keeps the last valid palette if Noctalia is unavailable or a write is incomplete.
Without a host palette, FileSail uses Qt's system palette.

The integration follows Noctalia's **app** mode (`theme.mode`). A separate
`theme.shell_mode` override affects only Noctalia's shell, as specified by its
[app-theming contract](https://docs.noctalia.dev/noctalia/theming/app-theming/).

The isolated `theme-smoke` CTest runs when Python 3 and Quickshell are available.
It can also be run directly with `python3 tests/theme-smoke.py /path/to/qs`.

## Install into Noctalia 5

```sh
./scripts/install-noctalia.sh
```

Enable `sergionoodles/filesail` under **Settings → Plugins**, then add its
`launcher` widget to the bar. Clicking it opens FileSail's native attached
browser panel. The panel supports breadcrumb navigation, search, refresh,
vertical scrolling with automatic incremental loading, opening files with the
desktop default application, opening the current folder in a full FileSail
window, and opening a terminal there. Noctalia 5 cannot embed third-party QML,
so the panel is rendered with Noctalia's native declarative UI while the full
manager remains the shared FileSail QML host.

The widget can also open FileSail, optionally at a path, through Noctalia IPC:

```sh
noctalia msg plugin sergionoodles/filesail:launcher focused open "$HOME/Downloads"
```

The `open` IPC event opens the native panel at the requested folder. Use the
`window` event when an external caller specifically needs a standalone FileSail
window.

To smoke-test the panel without changing the bar layout, restart Noctalia after
installing the plugin, then run:

```sh
noctalia msg panel-open sergionoodles/filesail:browser "$HOME"
noctalia msg panel-close sergionoodles/filesail:browser
```

For an offline check, run `noctalia plugins lint integrations/noctalia`.

The installer symlinks the adapter into
`$XDG_DATA_HOME/noctalia/plugins/filesail` (honoring `NOCTALIA_DATA_HOME`) and
makes the development launcher available and copies the backend and control CLI
executables to `~/.local/bin`. Ensure that directory is on the PATH of the
running Noctalia process.

## Next milestone

The scaffold deliberately leaves restore-from-Trash, an explicit **Open with…**
chooser, transfer progress/conflict UI, removable-volume controls, and preview
providers for the next iteration. There will be no tab system; additional
locations remain compositor-managed windows, while the reserved second pane is
for previews.

See [docs/architecture.md](docs/architecture.md) for module boundaries and MVP
trade-offs.

## Release version

The application version is defined once in [`VERSION`](VERSION). CMake, the
Noctalia 5 plugin manifest, AppImage packaging, Arch packaging, and release
validation derive their versions from that file.
