# UI component modularization plan

## Status

Proposed refactor. This plan changes ownership and file boundaries without
intentionally changing FileSail's appearance or behavior.

## Objective

Make the shared QML interface easier to understand and safer to change with AI
agents by giving each meaningful UI section a clear file. The target is a
moderate number of feature-sized components, not a component for every button,
label, delegate fragment, or layout primitive.

The refactor must preserve the architectural boundaries in
[architecture.md](architecture.md): shared components remain host-neutral,
`BrowserSession` remains the UI-facing state and command facade, the second pane
remains reserved for previews, and FileSail does not gain tabs.

## Current concentration

The existing component tree has a sound top-level layering, but three files own
too many independently changeable UI regions:

| File | Current responsibilities | Problem |
| --- | --- | --- |
| `qml/components/FileSailView.qml` | Public view contract, session, actions and shortcuts, page layout, preview loading, status bar, notices, and four dialogs | Most cross-UI changes converge on one 300-line composition root. |
| `qml/components/FileBrowserPane.qml` | List header, list delegate, grid delegate, empty/error/loading states, and view switching | List and grid work cannot be assigned independently and state UI is duplicated around them. |
| `qml/components/BrowserToolbar.qml` | Navigation row, address/filter controls, file-action row, context strip, and overflow menu | The navigation and file-operation regions have unrelated reasons to change. |

`BreadcrumbBar.qml` is also relatively large, but its path editing,
completion, and breadcrumb presentation form one cohesive feature. Splitting it
now would mostly create extra property forwarding. `ModalPrompt.qml`, the
sidebar components, and individual preview providers are likewise already at
useful boundaries and should remain intact in this pass.

## Boundary rules

Use these rules when extracting components:

1. A file represents a user-visible region or one cohesive coordination role.
2. Keep a small layout fragment inline when it has no behavior and is unlikely
   to be requested independently.
3. Pass domain objects such as `session` and `Action` instances rather than
   mirroring many leaf properties.
4. State has one owner. Extracted visual components emit intent and do not
   duplicate session, selection, clipboard, navigation, or dialog state.
5. Keep the public `FileSailView` properties and functions compatible with the
   standalone and Noctalia hosts.
6. Do not add generic abstractions until at least two components need them.
7. Continue to use the central `Theme` contract and square radius tokens in
   every extracted component.

These rules deliberately allow files in the 30-150 line range when the file is
a complete, nameable section. Line count is a warning signal, not the API.

## Target component tree

```text
FileSailView.qml                         public API and composition root
├── BrowserSession                      navigation, selection, operations
├── BrowserActions.qml                  actions, shortcuts, view preferences
├── Sidebar.qml                         existing sidebar feature
├── BrowserToolbar.qml                  toolbar coordinator
│   ├── NavigationBar.qml               navigation, path, filter, view/menu
│   │   └── BreadcrumbBar.qml           existing path/address feature
│   └── FileActionBar.qml               file commands, preview, folder context
├── SplitView
│   ├── FileBrowserPane.qml             list/grid switching only
│   │   ├── FileListView.qml            details header and list behavior
│   │   ├── FileGridView.qml            grid behavior
│   │   └── BrowserPaneStateOverlay.qml empty, error, and loading states
│   └── PreviewPane.qml                 built-in/external provider hosting
│       └── PreviewPanel.qml            existing built-in provider router
├── BrowserStatusBar.qml                item/selection and clipboard summary
├── NoticeBanner.qml                    transient success/error feedback
└── BrowserDialogs.qml                  create, rename, Trash, large-folder UX
    └── ModalPrompt.qml                 existing reusable prompt primitive
```

This adds ten shared component files. It is a small enough inventory to scan at
a glance while creating clear targets for common requests such as “change only
the grid”, “adjust the status bar”, or “update the rename dialog flow.” The
existing `qml/components` directory can remain flat; subdirectories would add
import and `qmldir` overhead before the component count justifies them.

## Component contracts

### `FileSailView.qml`

Retain this as the stable public component used by `shell.qml` and
`integrations/noctalia/Panel.qml`. It should own only:

- the public host contract (`initialPath`, compact sizing, corner radius, and
  external preview inputs);
- the `BrowserSession` instance;
- top-level composition and one-pixel separators;
- wiring between action intent, dialogs, notices, and the session;
- compatibility methods such as `navigate(path)` and `showNotice(...)`.

Keep `viewMode`, `previewPaneEnabled`, `selectedCount`, `previewContext`, and
`modalActive` available from `FileSailView`. The currently writable
`viewMode`, `previewPaneEnabled`, and replaceable `previewContext` must remain
writable; use writable aliases or equivalent two-way forwarding. Read-only
forwarding is appropriate only for the already read-only `selectedCount` and
`modalActive`. Hosts must not need changes as a consequence of this refactor.

### `BrowserActions.qml`

Make this a non-visual `QtObject` that owns the current `Action` objects and
their shortcuts. It receives `session` and `modalActive`, and owns the
per-window `viewMode` and `previewPaneEnabled` preferences. It emits intent for
UI-owned flows that it cannot complete itself:

- `editLocationRequested()`
- `createRequested()`
- `renameRequested()`
- `trashRequested()`

Navigation, refresh, clipboard, open-terminal, and view-mode actions can call
the session or update action-owned state directly. Declare all `Action`
instances as explicit object properties because `QtObject` has no default child
property. Avoid a map of dynamically created actions: named properties keep
QML bindings and agent-directed changes easy to follow.

### `BrowserDialogs.qml`

Own the four related modal flows and their temporary payload state. Its public
API should be imperative and narrow:

- `openCreate(parentPath, focusTarget)`
- `openRename(path, focusTarget)`
- `openTrash(paths, focusTarget)`
- `openLargeDirectory(path, entryCountAtLeast, focusTarget)`
- read-only `active`

It receives `session` and invokes the existing `session.runOperation(...)` or
`session.loadLargeDirectory(...)` paths. It composes the existing
`ModalPrompt`; it does not introduce a new general dialog framework. Trash
remains the only deletion path. The wrapper fills the view, sits at a higher
top-level sibling `z` than `NoticeBanner`, and preserves the prompts' background
input consumption. A child's `z` value does not escape its wrapper's stacking
context, so ordering only the nested `ModalPrompt` instances is insufficient.

### `NoticeBanner.qml`

Own notice presentation and its timer. Expose `show(message, isError)` and a
read-only visibility/running state if needed for tests. It must render messages
as plain text through `Format.safeText`, retain the current timeout and z-order,
and use `Theme` tokens.

### `BrowserStatusBar.qml`

Receive `itemCount`, `selectedCount`, `clipboardCount`, and `clipboardMode`.
Keep it purely presentational. It must not inspect `BrowserSession` internals or
mutate clipboard state.

### `PreviewPane.qml`

Own the complete preview-hosting seam currently embedded in `FileSailView`:

- built-in versus external provider selection;
- URL and `Component` loading;
- initial property injection via `Loader.setSource`;
- live binding of `selectedPath`, `selectedEntries`, and
  `selectionRevision` after loading;
- stable pane geometry while selection changes.

Receive `enabled`, `previewSource`, `previewComponent`, and `previewContext`.
The root is one `SplitView` child so `FileSailView` no longer needs parallel
built-in and external children. It should stay instantiated and control its
content through visibility/loader activity, preserving provider state where the
current behavior does. Selection routing remains in the existing
`PreviewPanel`.

### `BrowserToolbar.qml`, `NavigationBar.qml`, and `FileActionBar.qml`

Keep `BrowserToolbar` as the public toolbar coordinator so `FileSailView` has
one toolbar child and one place to call `beginPathEditing()`. It accepts the
session, compact flag, and named actions, then forwards them to two visual rows:

- `NavigationBar` owns back/forward/up, `BreadcrumbBar`, folder filtering,
  view switching, terminal, and the overflow menu.
- `FileActionBar` owns create, rename, copy, cut, paste, Trash, preview toggle,
  and `FolderContextBar`.

Do not make components for individual toolbar buttons. `IconButton` already is
the reusable control primitive. Keep the overflow menu with `NavigationBar`
because its anchor and trigger belong to that row.

### `FileBrowserPane.qml`, `FileListView.qml`, and `FileGridView.qml`

Reduce `FileBrowserPane` to a coordinator that switches between two persistent
view implementations and places shared state feedback above them.

Both view components receive `session`; they continue to use the session's
selection and open-entry methods. `FileListView` owns the details header and
row delegate. `FileGridView` owns cell sizing and its delegate. Keep each
delegate inline in its respective view for now: a list row or grid tile has no
second consumer, and extracting each would increase API surface without making
the feature easier to find.

Preserve the existing optimization of binding the inactive view's model to
`null`. Do not let both views instantiate delegates simultaneously merely to
simplify switching.

### `BrowserPaneStateOverlay.qml`

Own the empty, filtered-empty, load-error/retry, and loading-indicator states.
Receive only the values it renders plus a `retryRequested()` signal. The pane
coordinator wires retry back to `session.directory.refresh("refresh")`.

Use a single overlay component rather than separate files for empty, error, and
loading states. Empty and error presentation replace one another, but loading
is deliberately concurrent: it remains a thin, non-blocking indicator above
the mounted list or grid while a refresh is in progress. It must not unmount,
hide, or block the active view because the current entries and scroll position
remain usable until the refresh succeeds. Preserve the current empty-state
condition of not loading, no error, and zero entries, as well as error retry
behavior.

## Files intentionally unchanged

- `qml/core/BrowserSession.qml`: its 250 lines represent one stateful facade.
  UI extraction should not be mixed with a behavioral session redesign.
- `qml/components/BreadcrumbBar.qml`: address editing and completion are one
  feature; reassess only if new path-entry behavior makes it grow materially.
- `qml/components/ModalPrompt.qml`: it is already a reusable modal primitive.
- `qml/components/Sidebar.qml` and `SidebarLocationList.qml`: their current
  section/list split is appropriately granular.
- `qml/components/PreviewPanel.qml` and provider files: routing is already
  separate from format-specific presentation.
- `qml/core`, `src/backend`, and the JSON protocol: no changes are needed for a
  visual ownership refactor.

## Implementation sequence

Each phase should be a behavior-preserving, reviewable change. Run QML lint and
the bounded standalone smoke check after every phase so regressions are
localized.

### Phase 1: extract leaf UI regions

1. Add `NoticeBanner.qml` and replace the inline notice rectangle/timer.
2. Add `BrowserStatusBar.qml` and replace the inline status row.
3. Add `BrowserDialogs.qml`, move prompt payload state into it, and route
   session warnings and action intent to its methods.
4. Add `PreviewPane.qml` and move all built-in/external loader behavior without
   changing the public preview contract.

This phase removes self-contained regions first and establishes the intended
signal/forwarding style before changing central controls.

### Phase 2: separate browser views

1. Move the details header, `ListView`, and row delegate to `FileListView.qml`.
2. Move the `GridView` and tile delegate to `FileGridView.qml`.
3. Move shared state UI to `BrowserPaneStateOverlay.qml`.
4. Leave `FileBrowserPane.qml` responsible only for switching, background
   selection clearing where appropriate, and retry wiring.

Verify selection modifiers, background deselection, double-click/open,
keyboard activation, scrolling, and inactive-view model teardown in both
modes.

### Phase 3: separate toolbar regions

1. Extract `NavigationBar.qml` while preserving `beginPathEditing()` and the
   breadcrumb completion popup's positioning.
2. Extract `FileActionBar.qml` with the existing action instances and folder
   context.
3. Reduce `BrowserToolbar.qml` to layout and contract forwarding.

The `Action` instances remain temporarily in `FileSailView` during this phase,
which keeps the toolbar move mechanical.

### Phase 4: centralize actions and finish the composition root

1. Add `BrowserActions.qml` and move named actions and shortcuts into it.
2. Make it the owner of `viewMode` and `previewPaneEnabled`, while preserving
   the corresponding `FileSailView` public properties through forwarding.
3. Wire prompt intent to `BrowserDialogs` and location-edit intent to
   `BrowserToolbar`.
4. Remove obsolete temporary state and helper functions from
   `FileSailView.qml`.
5. Update `qml/components/qmldir` with every new shared component.

Doing the non-visual extraction last avoids changing action ownership at the
same time as the visual tree is being moved.

## Verification and acceptance criteria

Run the repository-prescribed checks after the refactor:

```sh
qmllint -I /usr/lib/qt6/qml -I qml qml/core/*.qml qml/components/*.qml shell.qml
qmllint -I /usr/lib/qt6/qml -I /etc/xdg/quickshell/noctalia-shell -I qml integrations/noctalia/*.qml
```

Also perform a bounded standalone launch and confirm it reaches
`Configuration Loaded`, then ensure the test instance exits. A backend build or
protocol test run is unnecessary unless implementation work unexpectedly
touches those layers.

Manually verify:

- both standalone and Noctalia hosts instantiate `FileSailView` without API
  changes;
- list/grid switching, selection, keyboard shortcuts, and open behavior match
  the current implementation;
- create, rename, Trash, and large-directory prompts retain focus and payloads;
- notices retain success/error coloring, plain-text safety, and timeout;
- dialogs remain above notices and consume input outside the prompt surface;
- built-in, URL-based, and `Component`-based preview providers receive the same
  selection properties and remain responsive to selection changes;
- refreshing a populated folder leaves its active view mounted and interactive
  beneath the loading indicator;
- compact sizing and preview collapse thresholds are unchanged;
- all new surfaces use `Theme` and FileSail's square-corner convention.

The refactor is complete when `FileSailView.qml` reads as a composition root,
`FileBrowserPane.qml` reads as a view switcher, and `BrowserToolbar.qml` reads
as a two-row coordinator. No exact line-count gate is required, but none of
those files should still contain full delegates, prompt implementations, or
provider-loading internals.

## Guardrails against over-fragmentation

After this plan, add another component only when at least one of these is true:

- it is a user-visible section an agent may reasonably be asked to change on
  its own;
- it owns behavior or lifecycle that would otherwise be duplicated;
- it has a stable contract and more than one consumer;
- keeping it inline makes its parent mix distinct state ownership concerns.

Do not extract one-off separators, headings, button clusters smaller than a
coherent toolbar row, list/grid delegates, or individual empty/error variants
solely to reduce line counts. If the flat components directory later grows past
roughly 40 production files, revisit feature subdirectories as a separate
module-layout change rather than combining it with this refactor.
