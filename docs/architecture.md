# FileSail architecture

FileSail is split into three layers so file management never depends on a
particular compositor or shell.

## Shared UI

`qml/components/FileSailView.qml` owns the browser layout, selection, list/grid
switching, navigation, and commands. It is a content item: it does not create a
window and does not import Noctalia, Niri, or Hyprland APIs. A reserved
`SplitView` loader is the future preview pane; previews can be added without
turning the application into a tabbed interface.

`qml/core/Theme.qml` is the stable token contract. Theme providers and shell
adapters may map live host tokens into that contract without making shared UI
depend on a particular host.

## Backend protocol

`filesail-backend --serve` is a long-lived Qt Core helper. It accepts one compact
JSON request per stdin line and emits one compact protocol message per stdout
line. The process
boundary has two advantages:

1. The same backend is available to standalone Quickshell and embedded shell
   plugins without installing a native QML extension into the shell process.
2. A native backend fault cannot crash the user's desktop shell.

The primary protocol methods are `list`, `mkdir`, `rename`, `trash`, `copy`,
`move`, `setExecutable`, and `open`. Requests carry numeric IDs. Directory
entries include symbolic `permissions`, effective `isExecutable` state, and a
`created` timestamp for the file info view. `watch` and `unwatch` manage
explicit, reference-counted directory subscriptions; `QFileSystemWatcher`
events are emitted immediately and each directory model debounces its own
refreshes.

Serialized mutations are registered in a backend-owned FIFO. The backend emits
additive `operationChanged` events for queued/running state and copy/move
progress, and `operations.list` returns the current mutation snapshot. These
events are non-terminal; the original request response remains the sole source
of success, failure, and partial-transfer results. Progress reports logical
source paths, completed entries, top-level item counts, aggregate bytes written,
and current-file byte counters. Aggregate directory totals are intentionally
not pre-scanned, so directory transfers may report indeterminate progress.

Filesystem work runs outside the protocol event loop. Directory queries use a
small read pool, while mutating operations use the explicit single-worker FIFO
so their ordering remains deterministic. Request IDs are also operation IDs,
and mutation cancellation remains a future extension with explicit staging
boundary semantics.

Copies are staged on the destination filesystem and committed with atomic
no-replace semantics. Copy and cross-device move preserve regular files,
directories, symbolic links, permission bits, modification times, and POSIX
ACLs. Special filesystem entries are rejected; ownership, non-ACL extended
attributes, hard-link relationships, sparse layout, and symlink timestamps are
not part of the current copy contract. If a cross-device move commits its destination but
cannot remove the source, the error response includes a structured `partial`
entry so the UI can report the committed destination and failed source cleanup
without treating the move as complete.

## Hosts

- `shell.qml` is the standalone host. Its `WindowRegistry` creates independent
  normal `FloatingWindow` xdg-toplevels, so Niri and Hyprland can tile each
  browser normally while all windows share one QML engine and backend.
- `integrations/noctalia` is a thin Noctalia 4.7.7 adapter. Noctalia owns the
  layer surface, focus, attachment, blur, animation, and IPC; FileSail only
  supplies panel content and a bar trigger.

The standalone launcher uses Quickshell's per-user IPC endpoint (`filesail.v1`
target, protocol version `1`) to route `open(path)` requests to the existing
host. A short per-user startup lock and bounded readiness probe arbitrate the
first-launch race. `--new-instance` is retained as a temporary diagnostic
escape hatch.

The optional `filesail-dbus` package adds a separate native Qt service for
`org.freedesktop.FileManager1`. It translates local URI requests into the same
launcher and IPC path, so the default package and AppImage do not claim the
global session-bus name. The package installs a user-level systemd unit rather
than a system D-Bus activation file, avoiding conflicts with file managers such
as Nautilus. Users explicitly enable the unit when they want FileSail to own
the name. `ShowItems` groups selections by containing directory and applies them
after the directory snapshot loads.
- A future Omarchy host should map Omarchy tokens and panel lifecycle into the
  same shared UI. No compositor code belongs in the file model or operations.

## Installation

The repository supports a standalone installation: `cmake --install build`
installs `filesail-backend` and the `filesail` launcher in the configured bindir,
and installs `shell.qml`, the QML tree, desktop entry, and the Noctalia adapter
under `share/filesail`. The root-level `shell.qml` remains the sole standalone
host; `hosts/standalone` is reserved until there is a second standalone host
implementation. Release metadata has one source of truth in the root `VERSION`
file; CMake derives `PROJECT_VERSION` from it and configures the installed
manifest. The Noctalia development installer generates the same manifest in
the checkout when needed. Noctalia development remains supported by
`scripts/install-noctalia.sh`, which intentionally symlinks the checkout.

## Deliberate MVP boundaries

- Trash is the only deletion path. Permanent delete is not exposed.
- Trash browsing works as a normal folder; restore metadata support comes later.
- Mutating filesystem operations run outside the UI process and are serialized
  on a worker queue; directory queries remain responsive while they run.
- `xdg-open` handles defaults; an explicit “Open with…” chooser comes next.
- The preview pane contract exists, but no preview provider ships yet.
- New tiled windows replace tabs. The development launcher already allows
  duplicate standalone Quickshell instances.
