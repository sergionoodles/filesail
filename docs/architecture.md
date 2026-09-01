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
JSON request per stdin line and emits one response per stdout line. The process
boundary has two advantages:

1. The same backend is available to standalone Quickshell and embedded shell
   plugins without installing a native QML extension into the shell process.
2. A native backend fault cannot crash the user's desktop shell.

The primary protocol methods are `list`, `mkdir`, `rename`, `trash`, `copy`,
`move`, and `open`. Requests carry numeric IDs. `watch` and `unwatch` manage
explicit, reference-counted directory subscriptions; `QFileSystemWatcher`
events are emitted immediately and each directory model debounces its own
refreshes.

Filesystem work runs outside the protocol event loop. Directory queries use a
small read pool, while mutating operations use a single-worker queue so their
ordering remains deterministic. Request IDs are also operation IDs, leaving a
compatible seam for later progress and cancellation events.

Copies are staged on the destination filesystem and committed with atomic
no-replace semantics. Copy and cross-device move preserve regular files,
directories, symbolic links, permission bits, and modification times. Special
filesystem entries are rejected; ownership, ACLs, extended attributes,
hard-link relationships, sparse layout, and symlink timestamps are not part of
the current copy contract. If a cross-device move commits its destination but
cannot remove the source, the error response includes a structured `partial`
entry so the UI can report the committed destination and failed source cleanup
without treating the move as complete.

## Hosts

- `shell.qml` is the standalone host and creates a normal `FloatingWindow`. Niri and
  Hyprland see it as an ordinary xdg-toplevel and can tile it normally.
- `integrations/noctalia` is a thin Noctalia 4.7.7 adapter. Noctalia owns the
  layer surface, focus, attachment, blur, animation, and IPC; FileSail only
  supplies panel content and a bar trigger.
- A future Omarchy host should map Omarchy tokens and panel lifecycle into the
  same shared UI. No compositor code belongs in the file model or operations.

## Installation

The repository supports a standalone installation: `cmake --install build`
installs `filesail-backend` and the `filesail` launcher in the configured bindir,
and installs `shell.qml`, the QML tree, desktop entry, and the Noctalia adapter
under `share/filesail`. The root-level `shell.qml` remains the sole standalone
host; `hosts/standalone` is reserved until there is a second standalone host
implementation. The installed manifest is configured from `PROJECT_VERSION`.
Noctalia development remains supported by `scripts/install-noctalia.sh`, which
intentionally symlinks the checkout.

## Deliberate MVP boundaries

- Trash is the only deletion path. Permanent delete is not exposed.
- Trash browsing works as a normal folder; restore metadata support comes later.
- Mutating filesystem operations run outside the UI process and are serialized
  on a worker queue; directory queries remain responsive while they run.
- `xdg-open` handles defaults; an explicit “Open with…” chooser comes next.
- The preview pane contract exists, but no preview provider ships yet.
- New tiled windows replace tabs. The development launcher already allows
  duplicate standalone Quickshell instances.
