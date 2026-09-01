# FileSail

FileSail is a Quickshell-native file manager designed for tiled Wayland
desktops. The first host targets Noctalia 4 on Niri; the UI and backend are kept
portable for Omarchy/Hyprland.

The current MVP scaffold includes:

- details/list and icon-grid browsing;
- breadcrumbs, editable address (`Ctrl+L`), back/forward/up, and filtering;
- multi-selection, create folder, rename, copy, move, and Trash-by-default;
- XDG default-application opening;
- a reserved preview pane instead of tabs;
- a normal tiled window and a native Noctalia plugin panel using the same UI.

## Build the backend

Requirements: CMake 3.24+, a C++20 compiler, Qt 6 Core and Concurrent, and
Quickshell.

```sh
cmake -S . -B build
cmake --build build
ctest --test-dir build --output-on-failure
```

## Install the standalone host

```sh
cmake --install build
```

This installs the `filesail` launcher, backend, desktop entry, QML tree, and
Noctalia adapter using CMake's configured install prefix. The checkout remains
usable for Noctalia plugin development through `scripts/install-noctalia.sh`.

## Run as a tiled window

```sh
./scripts/run.sh
./scripts/run.sh ~/Downloads
```

Each invocation uses `--allow-duplicate`, so the tiling compositor can manage
separate FileSail windows instead of application tabs.

## Install into Noctalia 4

```sh
./scripts/install-noctalia.sh
```

Enable FileSail under **Settings → Plugins**, then add the FileSail widget to the
bar. The panel can also be controlled through Noctalia IPC:

```sh
qs -c noctalia-shell ipc call plugin togglePanel filesail
```

The installer symlinks this checkout for plugin development and copies only the
backend executable to `~/.local/bin`. Ensure that directory is on the PATH of
the running Noctalia service.

## Next milestone

The scaffold deliberately leaves restore-from-Trash, an explicit **Open with…**
chooser, transfer progress/conflict UI, removable-volume controls, and preview
providers for the next iteration. There will be no tab system; additional
locations remain compositor-managed windows, while the reserved second pane is
for previews.

See [docs/architecture.md](docs/architecture.md) for module boundaries and MVP
trade-offs.
