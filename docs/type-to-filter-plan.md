# Type to filter the current folder

Status: implemented.

## Intended behavior

When the file pane has keyboard focus, typing filename text immediately focuses
the existing toolbar filter and inserts the triggering text exactly once.
Subsequent typing edits that field normally. If a filter already exists and the
user has returned focus to the file pane, append the triggering text and place
the caret at the end.

Automatic activation requires no keyboard modifiers. Super/Meta, Alt, Shift,
Ctrl, and other reported modifier flags prevent activation, even if the key
produces printable text. This restriction applies only to activation: once the
filter has focus, ordinary text editing, shifted characters, and shortcuts work
normally.

Use the event's produced text, not an ASCII key-code range. Accept nonempty,
printable filename text, including Unicode letters, digits, punctuation, and
spaces. Reject slash, NUL, control characters (including Tab, newline, Escape,
and DEL), and events with no text. Reject the whole event if it contains a
disallowed character. Do not impose Windows filename restrictions on this Linux
application: characters such as colon and backslash are valid. Control
characters are deliberately excluded from activation even where a filesystem
could store them. Dead keys with no committed text do not activate the filter;
ordinary input-method editing remains available after focusing the field.

Activation applies in both list and grid mode, including an empty folder or a
filter with no matches. Do not capture typing in the location editor, dialogs,
menus, preview content, or another window. Clicking the filter continues to work.

Clear the filter as soon as a successfully loaded folder replaces the current
folder, before displaying its entries. Back/Forward also start with an empty
filter; filters are not stored in navigation history. Failed, cancelled, or
superseded navigation and same-folder refreshes preserve the current filter.

## Current implementation

- `BrowserToolbar.qml` contains `NavigationBar.qml`, where `searchInput` binds
  to `session.directory.filter`.
- `DirectoryModel.qml` filters the cached directory snapshot locally, with a
  160 ms debounce. Its successful listing callback publishes the new path and
  calls `applyView()` before emitting `loaded`.
- `BrowserSession.qml` commits navigation history and resets selection/focus in
  the model's `loaded` handler. Clearing there would be too late for the first
  application of the new folder's filter.
- `FileListView.qml` and `FileGridView.qml` handle navigation keys separately;
  `FileBrowserPane.qml` contains both. Space currently toggles selection, and
  `BrowserActions.qml` assigns `?` to keyboard help.

## Implementation plan

### 1. Reuse the existing filter field

Add a small `beginFiltering(text)` method to `NavigationBar.qml` and forward it
through `BrowserToolbar.qml`, following the existing `beginPathEditing()`
pattern. Focus `searchInput`, append the triggering text once using the field's
editing API, and leave the caret at the end. Preserve synchronization with
`directory.filter`, including programmatic resets after the user has edited
the field. Avoid synthetic key replay or a second copy of filter state.

### 2. Route filename typing from the file pane

Keep the activation predicate and request in `FileBrowserPane.qml`. Have both
view key handlers offer events to this shared logic before their existing key
branches. Wire the accepted request through `FileSailView.qml` to the toolbar.
Use a small callback or equivalent direct component hook so the handlers know
whether the event was consumed; do not create a global keyboard service.

Require the active file view's focus and no active dialog or popup. Accept an
event only after it qualifies and is handed to the filter. Leave rejected events
available to existing navigation and shortcuts. Ensure initial view focus and
background clicks allow this behavior even when no entries exist.

Resolve the existing printable-key conflicts explicitly:

- Unmodified Space starts filtering with a space. Preserve selection toggling
  with Ctrl+Space and update the keyboard-help entry accordingly. Spaces already
  entered in the filter continue to use the model's existing matching semantics
  (`filter.trim()`); this feature does not change matching rules.
- An unmodified `?` produced by a keyboard layout starts filtering. Prevent the
  help Action from intercepting that qualifying event before the view handler.
  Shift+`?` does not auto-activate the filter and can retain the existing help
  behavior. Keep help reachable through its existing non-typing entry points.

Arrows, Enter, Backspace, Escape, Delete, function keys, and modified shortcuts
retain their existing behavior. Once filter focus is established, the file-pane
activation logic no longer participates in editing.

### 3. Reset at the successful directory transition

In `DirectoryModel.qml`'s listing success callback, after the existing stale
request checks, compare `result.path` with the previously displayed `path`.
When they differ, clear `filter` before the new snapshot's `applyView()` call.
Stop the filter debounce timer after clearing so the immediate application does
not leave a redundant delayed rebuild. Keep the normal debounce for typing.

Use this shared commit point for every navigation source: opening a folder,
breadcrumbs, location entry, sidebar, Back/Forward/Up/Home, removable volumes,
and external control requests. Do not clear on navigation request, load kind
alone, or every `loaded` signal. A retry that succeeds in entering a different
folder clears the filter then; a refresh, sort change, hidden-file toggle, or
filesystem watcher update in the same folder preserves it.

Keep history commits in `BrowserSession.qml` after successful loading. Clear
only this model instance's filter; other browser windows keep theirs. No backend
protocol, host adapter, dependencies, or additional UI surfaces are needed.

## Verification and acceptance

Add a focused QML runtime check using the existing isolated smoke-test pattern.
Exercise actual key delivery and focus changes, not only the text predicate.

1. In both views, type a letter, digit, dot, space, and unshifted Unicode text.
   Confirm filter focus, exactly one insertion of the first text, normal
   subsequent editing, and appending after returning focus to the pane.
2. Verify every modifier independently and in combinations blocks activation.
   Cover slash, empty text, control characters, dead keys, and the existing
   navigation keys. Verify Ctrl+Space selection and the `?` shortcut conflict.
3. Repeat with an empty folder and zero matching results. Verify typing in the
   location editor, rename/create/unlock dialogs, menus, and another window
   does not activate this filter.
4. Enter a filter that would hide every entry in a destination folder, then
   navigate there successfully. Verify the field and model are empty before
   the destination's first visible snapshot and focus/selection reset uses the
   unfiltered entries. Cover Back/Forward and an external navigation request.
5. Confirm failed/cancelled navigation and same-path refresh preserve the text.
   Cover superseded requests, large-folder confirmation, watcher refreshes,
   hidden-file toggles, and a pending filter debounce during navigation.
6. Edit the field, navigate, then type again to detect broken text bindings.
   Confirm a second window's filter is unaffected.

For implementation, run the shared and integration QML lint commands from
`AGENTS.md`, the focused runtime check, and relevant existing CTest checks.
Confirm a bounded standalone launch reaches `Configuration Loaded`; this
briefly creates a Wayland window. Terminate all test instances afterward.
Manually verify real keyboard layouts and modifier behavior on Wayland.

This draft changes documentation only; runtime checks belong to implementation.
