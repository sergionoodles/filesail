# FileSail architecture

FileSail is split into three layers so file management never depends on a
particular compositor or shell.

## Shared UI

`qml/components/FileSailView.qml` owns the browser layout, selection, list/grid
switching, navigation, and commands. It is a content item: it does not create a
window and does not import Noctalia, Niri, or Hyprland APIs. The optional second
pane hosts `PreviewPanel`, which selects image, visual thumbnail, text, archive,
or metadata providers according to the selection. It is reserved for previews.

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

`previewCapabilities`, `thumbnailBatch`, `textPreview`, and `archivePreview`
serve the preview providers. `PreviewService` is created on demand and released
after its jobs finish and an idle timeout expires. Text and archive reads run
on the read pool with bounded output; thumbnails use the session's external
thumbnailer and cache. `cancelPreview` and `cancel` cancel eligible read and
preview requests. `locations.list`, `locations.add`, and `locations.remove`
manage atomic saved-location snapshots independently of the host.

`VolumeService` owns the Linux UDisks2 system-bus integration. It coalesces
ObjectManager/property changes into revisioned, drive-centric snapshots and
exposes only backend-instance-scoped opaque drive and volume IDs. Additive
`volumes.*` methods mount, unlock, prepare and cancel removal, and unmount;
`drives.safeRemove` sequences filesystems, encrypted containers, sibling drives,
and the supported eject/power-off step without forced unmounts. Short-lived
removal reservations reject overlapping FileSail mutations. UDisks2 absence is
nonfatal and is represented by an unavailable volume snapshot.

## Desktop clipboard

`filesail-clipboard` is a long-lived Qt Core helper, separate from Quickshell
and the filesystem backend. It owns a Wayland data-control selection when the
desktop exposes `ext-data-control-v1`, falling back to
`zwlr_data_control_manager_v1` without branching on compositor names. The
helper publishes and reads `text/uri-list` and
`x-special/gnome-copied-files`, validates local file URIs, and communicates
with QML over bounded request-ID NDJSON. It never creates a helper window or
reads arbitrary clipboard text.

`FileClipboard.qml` is the shared cache/coordinator used by every browser
session in the QML engine. The desktop selection remains authoritative: tokens
are used to reject stale asynchronous pastes, and only a still-owned FileSail
selection may be conditionally pruned after a completed Cut. Filesystem safety
and transfer completion remain the backend's responsibility. When data-control
is unavailable, the coordinator exposes an unavailable state without affecting
directory browsing. See [the clipboard implementation plan](clipboard-plan.md)
for codec, protocol, and desktop verification details.

Unlock passphrases use a direct, non-replayable backend request: QML never queues
the serialized request and clears its password field on submit or close, while
the backend never logs or snapshots it. QML/JavaScript and Qt strings do not
provide guaranteed secure-memory erasure, so this reduces retention but cannot
promise that every transient copy is overwritten.

Serialized mutations are registered in a backend-owned FIFO. The backend emits
additive `operationChanged` events for queued/running state and copy/move
progress, and `operations.list` returns the current mutation snapshot. These
events are non-terminal; the original request response remains the sole source
of success, failure, and partial-transfer results. Progress reports logical
source paths, completed entries, top-level item counts, aggregate bytes written,
and current-file byte counters. Copy and move operations first run a cancellable,
no-symlink-follow scan on the mutation worker. The scan publishes estimated
aggregate byte and entry totals, allowing the primary progress indicator to
represent the whole selected transfer; current-file counters remain secondary
detail. Empty and zero-byte trees fall back to entry progress.
`operations.cancel` removes queued mutations before dispatch and cooperatively
stops running copies and moves at traversal and I/O checkpoints; Trash stops
between selected items. Copy commits, move source cleanup, and rollback are
protected boundaries. The original mutation always emits its terminal response,
including completed-item accounting and structured recovery paths when cleanup
cannot finish safely.

Filesystem work runs outside the protocol event loop. Directory queries use a
small read pool, while mutating operations use the explicit single-worker FIFO
so their ordering remains deterministic. Request IDs are also operation IDs.
Cancellation requests are scoped to the backend instance so a restarted helper
cannot receive a stale stop request.

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
- `integrations/noctalia` contains the Noctalia 5 bar widget/native panel and the
  standalone host's app-theme bridge. The standalone host follows
  Noctalia 5 app theming: a user template writes `~/.config/filesail/theme.json`
  whenever the palette changes, and `NoctaliaConfigThemeProvider` maps that
  file into `Theme`. Registration waits for both atomic writes, reloads Noctalia's
  config, then requests a render; failures retry with backoff. File watches plus
  a recovery timer handle late startup, missing output, and atomic replacement.
  Only complete, valid palettes replace the last good snapshot. Metrics come
  from `noctalia config export full`, so includes, defaults, and GUI overrides
  use Noctalia's own precedence. Shared color transitions respect animation
  settings. Qt's system palette supplies defaults until a host palette arrives.
  The optional Noctalia 5 plugin is a Luau bar entry and native declarative
  panel using plugin API 24. The bar click opens an attached native browser
  panel with breadcrumbs, search, refresh, desktop file opening, a terminal
  action, and an explicit full-window action. A bundled helper sorts, filters,
  and chunks directory listings outside the panel VM so large folders stay
  within Noctalia's callback budget. The panel cannot embed the shared QML
  browser because Noctalia 5 does not load third-party QML; its full-window
  action launches the compositor-managed FileSail host for complete operations.

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

The standalone host exposes live browser sessions through a shared
`ControlRouter` and thin `ControlWindowAdapter` objects. The separate
`filesail.control.v1`
Quickshell IPC target carries versioned JSON requests, retained results, and
sequence-based events; it never forwards arbitrary backend or QML calls. Each
adapter owns a backend-generated 128-bit random ID for the lifetime of its
view. The native `filesail-cli` enumerates Quickshell instances, pins each call
to an exact instance ID, and keeps no state between invocations. Navigation and
selection are still executed by the target `BrowserSession`, so directory
commit, history, filtering, and modal rules have one implementation. The
standalone registry supplies the optional window-creation capability. The
Noctalia 5 widget opens the native panel by default. Its `window` IPC event
still enters through the normal standalone launcher when an external caller
needs a full FileSail window.

- A future Omarchy host should map Omarchy tokens and panel lifecycle into the
  same shared UI. No compositor code belongs in the file model or operations.

## Installation

The repository supports a standalone installation: `cmake --install build`
installs `filesail-backend`, `filesail-cli`, and the `filesail` launcher in the
configured bindir, and installs `shell.qml`, the QML tree, desktop entry,
bundled agent skill, and Noctalia app-theme bridge under `share/filesail`. The
root-level `shell.qml` remains the sole standalone
host; `hosts/standalone` is reserved until there is a second standalone host
implementation. Release metadata has one source of truth in the root `VERSION`
file; CMake derives `PROJECT_VERSION` from it and configures the Noctalia 5
plugin manifest used by compatibility checks. The Noctalia development
installer generates the same versioned `plugin.toml` in the checkout when
needed. Noctalia development remains supported by
`scripts/install-noctalia.sh`, which intentionally symlinks the adapter.

## Deliberate MVP boundaries

- Trash is the only deletion path. Permanent delete is not exposed.
- Trash browsing works as a normal folder; restore metadata support comes later.
- Mutating filesystem operations run outside the UI process and are serialized
  on a worker queue; directory queries remain responsive while they run.
- `xdg-open` handles defaults; an explicit “Open with…” chooser comes next.
- Previews include images, external visual thumbnails, bounded UTF-8 text,
  archive listings, and file metadata. Syntax highlighting remains deferred.
- New tiled windows replace tabs. Launchers reuse the existing host by default;
  `--new-instance` remains a diagnostic escape hatch.
