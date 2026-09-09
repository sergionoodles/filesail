# FileSail Agent Guide

## Mission

Build a daily-driver Quickshell file manager for Noctalia/Niri and
Omarchy/Hyprland. Use separate compositor-managed windows instead of tabs; the
optional second pane is reserved for previews.

## Architecture

- `qml/components/FileSailView.qml`: shared browser UI. Keep it independent of
  Noctalia, Niri, Hyprland, and window types.
- `qml/core`: theme, backend client, directory model, and navigation state.
- `src/backend`: long-lived Qt Core helper using newline-delimited JSON over
  stdin/stdout. Keep native code outside the shell process.
- `shell.qml`: standalone tiled `FloatingWindow` host.
- `integrations/noctalia`: thin Noctalia panel/bar adapter only.
- See `docs/architecture.md` before changing layer boundaries.

## Non-negotiable behavior

- Trash is the default and only deletion path; never add permanent deletion
  without an explicit product decision and strong confirmation UX.
- Validate absolute local paths in the backend. Preserve protections against
  empty paths, self/descendant copies, collisions, and unsafe cross-device
  moves.
- Commit navigation history only after a directory loads successfully.
- Keep compositor-specific APIs behind host adapters.
- Extend the central `Theme` contract; do not import private shell tokens into
  shared components.
- Do not introduce tabs.

## Implementation style

- Prefer small, readable QML components and Qt filesystem APIs.
- Keep the UI responsive; long operations belong in the backend process.
- Preserve JSON protocol compatibility when adding operations or progress
  events.
- `QtObject` has no default child property: declare `Timer`, `Connections`,
  models, processes, and file views as explicit object properties.
- Avoid QML property names beginning with `on`; QML may interpret them as signal
  handlers.
- Use FileSail's shared `Theme` radius tokens for every UI surface and control.
  FileSail's convention is square corners (`0` radius); do not introduce
  rounded buttons, fields, dialogs, toolbars, or cards.

## Verification

Run checks appropriate to the change:

```sh
cmake --build build
ctest --test-dir build --output-on-failure
qmllint -I /usr/lib/qt6/qml -I qml qml/core/*.qml qml/components/*.qml shell.qml
qmllint -I /usr/lib/qt6/qml -I /etc/xdg/quickshell/noctalia-shell -I qml integrations/noctalia/*.qml
```

For QML runtime changes, confirm a bounded standalone launch reaches
`Configuration Loaded`; note that this briefly creates a Wayland window. Do not
leave test Quickshell instances running.

Add backend protocol tests for path validation, partial framing, multiple
requests, destructive operations, transfer edge cases, and new methods.

## Near-term roadmap

Prioritize restore-from-Trash, Open With, transfer progress/conflicts, removable
volumes, and preview providers. Keep these additions compatible with both the
standalone host and Noctalia panel.
