# Consistent context menus: implementation plan

Status: draft for review. This document proposes future work; it does not implement it.

## Objective and scope

Provide one consistent, selection-aware context menu system across FileSail's
details view, icon grid, and other surfaces that represent filesystem locations.
Users should recognize the same labels, ordering, appearance, and behavior
whether they invoke a menu on a file, folder, multiple items, or browser background.
The standalone window owns the implementation regardless of whether it is
launched directly or from the Noctalia bar.

The complete baseline includes opening, Open With, cut/copy/paste, path copying,
creation, rename, Trash and restore, properties, bookmarks, terminal/window
launching, and background view controls. Backend-dependent additions are explicit
implementation phases, not menu entries that ship without working commands.

Keep separate compositor-managed windows, the preview-only second pane, and
Trash as the sole deletion path. No tabs, permanent deletion, or Empty Trash action.
Follow [the architecture](architecture.md) and the repository's `AGENTS.md`.

## Current implementation and gaps

- `BrowserActions.qml` already centralizes many toolbar actions and shortcuts.
  Its commands mostly read live session selection or the current directory;
  they cannot yet safely represent a different context-menu target.
- `BrowserSession.qml` owns selection, filesystem command dispatch, and a
  session-local path clipboard. Paste always targets the current directory.
  Separate browser sessions do not currently share that clipboard.
- `FileListView.qml` accepts both mouse buttons but applies the same selection
  logic to either. Its double-click handler is not restricted to the left button.
- `FileGridView.qml` routes pointer selection through `SelectionMarquee.qml`,
  which accepts only the left button. Neither browser view opens an item menu.
- `FileBrowserPane.qml` owns background handling, view loaders, and empty/error
  overlays. All of these affect where background right clicks can be received.
- `NavigationBar.qml` has an overflow menu and Sort by submenu.
  `ThemedMenuItem.qml` provides reusable styling, but needs consistent icon,
  shortcut, submenu, and destructive-action presentation.
- `BrowserDialogs.qml` supports New folder, single-item Rename, Trash confirmation,
  and single-item File info. `BackendClient.qml` and the backend already support
  default opening, terminal launching, saved locations, and core mutations.
- Explicit Open With, Trash restoration, new empty files, and aggregate properties
  require additional capability. Trash is currently exposed as an ordinary folder.

## Interaction contract

| Invocation | Selection behavior | Menu target |
| --- | --- | --- |
| Right click an unselected item | Replace selection with that item; focus it | That item |
| Right click an item in a multi-selection | Preserve the whole selection; focus the clicked item | Entire selection |
| Right click the only selected item | Preserve selection | That item |
| Right click browser background | Clear selection and its range anchor | Current successfully loaded directory |
| Right click a breadcrumb or sidebar location | Preserve browser selection; identify the clicked location | That location only |
| Menu key or Shift+F10 in the file view | Use the selected set if the focused item belongs to it; otherwise select the focused item | Resolved selection; background when there is no focused item |

- Ctrl and Shift do not toggle or extend selection on a right click. Left-click
  selection, range selection, double-click opening, scrolling, and marquee behavior
  retain their existing semantics.
- Open once on right-button release following a valid click. Right-button movement
  must not start a marquee, activate an item, navigate, or produce duplicate menus.
- In details view, the complete row is an item hit target. Space below rows is
  background. In grid view, each visible tile is an item target; tile gaps and outer
  margins are background. Column headers retain their sort behavior and may use
  the shared view-settings menu, never a menu for a stale file selection.
- Empty folders and zero-result filters still support background menus. A filtered
  view targets its actual directory, and Select all selects only visible entries.
- During initial loading or failed navigation, allow safe view/retry actions, but
  disable directory mutations until a valid target has been established. Do not
  infer a writable destination from the text in the address field.
- Opening a menu must not open a file or change navigation history. Dismissing it
  preserves the selection resulting from invocation.
- A second right click replaces the previous menu with the newly resolved context.
  Outside click, Escape, host deactivation, navigation, or view destruction closes
  it. A directory refresh closes an item menu if its targets disappear or change;
  it must never silently substitute entries at the same model indices.

## Action matrix

“Selection” below means two or more items. Conditional entries are shown only
when meaningful for the entire target set. Applicable but temporarily unavailable
actions remain visible and disabled with an accessible explanation. Omit empty
groups and redundant separators.

| Action | Single file | Single folder | Selection | Background |
| --- | --- | --- | --- | --- |
| Open | Default application | Navigate in this window | Open selected files; folders in separate windows | — |
| Open With… | Application chooser | — | Only when one application can accept all selected files | — |
| Open in New Window | — | Selected folder | Open folders in new windows for an all-folder selection | Open current folder in new window |
| Open in Terminal | — | Selected folder | — | Current folder |
| Cut / Copy | Item | Item | Entire selection | — |
| Paste | — | Label “Paste Into Folder”; selected folder destination | — | Current folder destination |
| Copy Path / Copy Paths | Absolute path | Absolute path | All selected paths in visible order | Current folder path |
| New Folder… | — | — | — | Create in current folder |
| New File… | — | — | — | Create an empty file in current folder |
| Rename… | Item | Item | —; batch rename is deferred | — |
| Move to Trash | Item | Item | Entire selection | — |
| Restore | Recognized Trash item only | Recognized Trash item only | Recognized top-level Trash items only | — |
| Add to Bookmarks / Remove from Bookmarks | — | Selected folder | — | Current folder |
| Properties | File details | Folder details | Aggregate selection details | Current folder details |
| Select All | — | — | — | Visible directory entries |
| View / Sort By / Show Hidden Files / Refresh | — | — | — | Shared directory controls |

### Stable groups and labels

Order groups as follows; retain relative ordering when entries are omitted:

1. Open, Open With, new-window and terminal actions.
2. Creation actions for background menus.
3. Cut, Copy, Paste, Copy Path(s).
4. Rename, bookmark actions, Restore where applicable, Move to Trash.
5. Background selection and view controls.
6. Properties, always last.

Use “Cut” consistently for the existing Ctrl+X action currently named “Move”.
Use “Properties” consistently for the existing File info action and dialog.
Use an ellipsis for actions requiring another input dialog; direct actions have
none. Show existing shortcuts from the shared command definition, including
Alt+R for Rename, rather than silently changing keyboard bindings in this work.
Do not display Ctrl+V on Paste Into Folder: normal Ctrl+V targets the current
directory, and a selected folder context has a different destination.

For multiple folders, label Open as “Open in New Windows” and omit an equivalent
duplicate entry. For a mixed selection, label it “Open Selected Items”. Confirm
before opening more than five items/windows, with the count and Cancel as default.
Execute batches without blocking the UI and report individual launch failures.

The View submenu offers Details, Grid, and Preview pane. Sort By uses the existing
name/size/modification-date, direction, and folders-first settings. Show Hidden
Files uses the same checked state as the overflow menu.

## Targeting, safety, and command behavior

### Explicit context and one command implementation

Create a small context resolver that records the origin surface, loaded directory,
clicked path, ordered target paths, relevant entry metadata, destination directory,
selection/directory revisions, and focus-return target at invocation time.
Copy values; do not retain delegate references or use mutable model indices.

Each command has one identifier, translated label, icon, optional shortcut,
visibility/applicability rule, enabled rule, and handler. Menus, toolbars, and
shortcuts use the same command behavior, while supplying their own explicit
context. Do not temporarily overwrite the live selection or global Action text
to run a sidebar command. Avoid creating duplicate shortcut registrations.

Freeze the menu target set while it is open. Revalidate at activation and pass
the captured paths into confirmation dialogs and backend requests. Ignore late
capability/chooser responses from an older context. Backend validation remains
authoritative even when a menu was enabled a moment earlier.

### Clipboard and destination semantics

- Introduce a shared clipboard service for FileSail windows and integrate with the
  desktop clipboard's local-file URI and copy/cut representations. Verify the
  available Qt/Quickshell API and interoperability formats during implementation;
  keep any platform bridge out of compositor-specific UI code.
- Snapshot clipboard content at command activation. Reject unsupported/nonlocal
  URI inputs with a useful explanation. Preserve spaces, Unicode, and literal
  filename characters through URI encoding; never construct shell commands.
- Copy Path(s) writes plain text, one absolute path per line, and replaces the
  previous file-transfer clipboard content. File transfers must use URI data,
  never reinterpret newline-delimited path text as a transfer payload.
- Cut marks items as pending a move. Clear only successfully moved items and only
  if the clipboard generation still matches the operation. Preserve failed items
  and newer clipboard content, including after a partial cross-device move.
- Paste Into Folder must pass the clicked folder explicitly. A background Paste
  passes the loaded directory. Refresh affected visible source/destination views,
  including when the destination is not the initiating session's current path.
- Keep collision, self/descendant-copy, and unsafe cross-device protections. A
  collision reports the failure without silent overwrite. Reuse operation queue,
  progress, and partial-result reporting; richer conflict resolution is separate.

### Capabilities, metadata, and special locations

- Derive obvious applicability locally, then obtain missing metadata/capabilities
  asynchronously. Directory creation needs parent write/search access; rename and
  Trash availability cannot be inferred solely from the file's `isWritable` flag.
  Handle read-only mounts, sticky directories, ACLs, missing targets, and backend
  disconnects without synchronous filesystem work in QML.
- Treat symlinks explicitly: Copy Path, Rename, and Trash act on the link itself;
  opening follows the target. Folder navigation/paste requires a valid directory
  target. Broken links retain link-management actions, with opening disabled.
- Properties supports a single item, the current folder, and multiple items. Show
  counts and known sizes immediately. Compute recursive folder totals only through
  bounded/cancellable backend work; do not traverse symlink targets or freeze the UI.
- Open With discovers installed applications asynchronously and launches using
  validated application identifiers and argument lists. Support a common handler
  for compatible multi-file selections; do not change defaults unless the chooser
  explicitly offers that choice and the user selects it.
- New File creates an empty file using the same absolute-parent, name validation,
  and no-overwrite principles as New Folder. Do not expose arbitrary templates yet.
- Recognize Trash roots and original-location metadata in the backend, including
  supported per-volume Trash locations. Restore uses that metadata, validates the
  original destination, and preserves recoverability on failure or collision.
  Missing original parents require an explicit recovery choice; never guess a path.
- In Trash, replace Move to Trash with Restore for eligible top-level entries.
  Disable restore without valid metadata. Suppress Cut, Paste, Rename, and creation
  in Trash-managed contents so ordinary operations cannot corrupt its bookkeeping.
  Copy out remains available. Nested trashed contents are inspectable/copyable but
  are restored through their top-level Trash item, not independently.
- Never expose permanent deletion, Empty Trash, or an implied permanent-delete
  shortcut. Retain the existing confirmation before moving items to Trash.

## Shared presentation and app-wide coverage

Introduce a reusable themed menu container and separator alongside
`ThemedMenuItem.qml`. Use `Theme` for spacing, typography, colors, focus states,
and every radius; FileSail surfaces and controls remain square (`0`). Use the
same primitives in the existing overflow and Sort By menus.

Reserve aligned columns for icons, labels, shortcuts/check states, and submenu
arrows. Use restrained destructive coloring only for Move to Trash. Support
translated labels, long names, scaling, checked/disabled states, and keyboard
highlighting without clipped text or shifting columns.

Own one context-menu controller per `FileSailView`, above the clipped list/grid
content. Convert pointer coordinates from the source surface to its popup anchor;
flip/clamp menus and submenus to available host bounds and allow scrolling when
height is constrained. Verify popup behavior inside a normal Wayland window
before committing to a popup type.

Support arrow navigation, Enter, Escape, submenu navigation, Menu/Shift+F10, and
accessible names/roles/enabled states. Restore focus to the originating view or
location after dismissal; when opening a dialog, transfer focus to that dialog
and restore it after completion. Suppress file-view shortcuts while a popup or
dialog owns keyboard focus, so Escape does not also clear selection and Delete
cannot activate a second action underneath a menu.

Additional surface rules:

- Breadcrumbs and sidebar places use a location subset: Open, Open in New Window,
  Open in Terminal, Copy Path, bookmark controls, and Properties. They do not offer
  filesystem Rename or Trash for navigation shortcuts.
- Saved bookmarks/projects additionally offer “Remove from Bookmarks” or “Remove
  from Projects”; these only remove saved references. Right click must work even
  when the location is unavailable so a stale reference can still be removed.
- Built-in Trash uses the Trash-specific subset; it cannot itself be trashed or
  removed like a saved bookmark.
- File preview surfaces may forward a file context only when they represent an
  explicit path. Text selection and editable fields retain their text-editing
  menus. Toolbar buttons, scrollbars, operation controls, and dialogs do not inherit
  background file commands through a global right-click catcher.

## Implementation sequence

### 1. Command contexts and baseline behavior

- Add the context resolver and shared command descriptors; evolve `BrowserActions`
  and `BrowserSession` to accept explicit targets/destinations while preserving
  current toolbar and shortcut behavior.
- Extend `BrowserDialogs` to receive captured payloads and focus-return targets.
- Establish the selection rules and action matrix as executable behavior tests.

Exit condition: commands resolve the correct targets independently of list/grid
delegates and do not change targets after asynchronous state changes.

### 2. Shared menus and pointer routing

- Add the menu controller/container and extend themed items/separators.
- Wire `FileBrowserPane`, `FileListView`, `FileGridView`, and `SelectionMarquee`
  into one request path; explicitly separate left/right button handling.
- Implement background, keyboard, positioning, dismissal, and focus behavior.
- Migrate overflow styling and reuse shared view/sort commands.

Exit condition: all four primary contexts work identically in list and grid using
existing functional actions, without breaking left-click or marquee interaction.

### 3. Complete common actions

- Add the shared/system clipboard bridge, Copy Path(s), and destination-aware Paste.
- Implement New File, Open With, and aggregate/current-directory Properties with
  additive backend protocol methods and `BackendClient` wrappers where required.
- Add safe multi-item opening and bookmark commands; normalize Cut/Properties labels.
- Preserve backend mutation serialization, request IDs, progress events, and
  existing completion/partial-result compatibility.

Exit condition: every applicable ordinary-directory action in the matrix works;
no placeholders or enabled commands without a handler remain.

### 4. Trash and secondary surfaces

- Add Trash metadata/capability discovery and restore support, including protocol
  tests and the special-location restrictions above.
- Route breadcrumbs, sidebar locations, saved references, and applicable previews
  through the same controller without changing browser selection.
- Register any new core QML types and dependencies in the relevant module/build
  and packaging files; document protocol additions in `architecture.md`.

Exit condition: all covered surfaces use the same presentation and command rules,
and Trash operations preserve restore metadata and recoverability.

### 5. Verification and completion

Add focused automated coverage for target resolution and observable behavior,
using a Qt Quick test harness if the repository has none. Cover:

- Selected/unselected right clicks, homogeneous and mixed selections, modifier
  keys, keyboard invocation, disabled actions, and exactly one command per gesture.
- Background hits in empty/filtered folders, list trailing space, grid gaps/margins,
  loading/error overlays, and interactions with scrolling and delegate reuse.
- Selection/directory/clipboard changes while a menu, chooser, or dialog is open;
  removed targets; navigation/window closure; delayed capability responses.
- Two windows exchanging cut/copy data, external clipboard changes, Paste Into
  Folder targeting, partial success, and clipboard-generation preservation.
- Read-only locations, inaccessible folders, roots, symlinks/broken links, special
  characters, unavailable saved places, and Trash entries with missing metadata.

Extend backend protocol tests for every new method: absolute/local path validation,
partial framing, multiple requests, malformed inputs, creation collisions, safe
application launch arguments, restore collisions/missing parents, copy/move edge
cases, and partial failure. Test destructive operations only in temporary fixtures.

Run the repository checks after implementation:

```sh
cmake --build build
ctest --test-dir build --output-on-failure
qmllint -I /usr/lib/qt6/qml -I qml qml/core/*.qml qml/components/*.qml shell.qml
qmllint -I /usr/lib/qt6/qml -I qml integrations/noctalia/*.qml
```

Perform a bounded isolated standalone launch and confirm `Configuration Loaded`;
this briefly creates a Wayland window. Stop every test instance afterward.
Manually verify direct and Noctalia-launched standalone windows, list/grid
parity, compact windows, scaled displays, all popup edges, submenus, keyboard-only operation,
text-field menus, and cross-window/desktop clipboard interoperability. Record
unavailable host environments as validation gaps rather than claimed passes.

Completion means the entire baseline matrix and secondary surface rules are
implemented, automated checks pass, host checks are recorded, and no duplicate
file-operation implementation or compositor dependency was added to shared UI.

## Explicit follow-up work

Archive compression/extraction, batch rename, templates beyond empty files,
Duplicate, Create Link, undo, advanced permission editing, removable-volume
mount/eject controls, and interactive transfer conflict resolution remain separate
features. Add their commands through the same capability and context system when
their backend behavior is implemented; do not prepopulate unusable menu entries.
