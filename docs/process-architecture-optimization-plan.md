# Process and architecture optimization plan

## Status

Proposed architecture plan. This document covers process sharing and service
lifetime only. QML preview behavior, caches, directory-model efficiency,
request cancellation, and delegate work are specified in
[memory-performance-optimization-plan.md](memory-performance-optimization-plan.md).

## Objective

Stop multiplying FileSail's largest fixed costs across windows and prevent the
Noctalia integration and native helpers from remaining resident when they have
no active work.

This plan preserves the current technology and product direction:

- The standalone UI remains a Quickshell/Qt Quick host.
- The shared QML UI remains usable by standalone and Noctalia hosts.
- Each browser is a separate compositor-managed window; there are no tabs.
- The native filesystem backend remains outside the shell process.
- Trash and backend path-safety invariants remain unchanged.
- A native Qt Quick executable and a Qt Widgets/GTK rewrite are explicitly out
  of scope.

The lifecycle hooks in this plan depend on the cancellation, preview release,
watch cleanup, and bounded-cache contracts from
[memory-performance-optimization-plan.md](memory-performance-optimization-plan.md).
Implement and verify those contracts before making panel unloading or shared
window teardown rely on them.

## Current problems

### One engine and backend per standalone window

Both launchers use `--allow-duplicate`. Each invocation therefore creates a
new QML engine, Qt Quick renderer, theme state, backend process, and set of QML
singletons. The compositor sees the desired separate windows, but FileSail pays
the complete runtime cost for every one.

### Embedded lifetime is not explicit

`Panel.qml` directly owns `FileSailView`. If Noctalia keeps a closed panel
instance alive, its directory model, watches, selection state, and singleton
services stay alive as well. The integration needs a documented active versus
suspended lifetime instead of relying on visual hiding.

### Helpers start and remain resident eagerly

`BackendClient` starts `filesail-backend` as soon as the singleton is created.
The backend constructs preview service state at startup and links preview-only
DBus/libarchive dependencies even if the user never opens a preview.

## Target architecture

```text
standalone launcher
    |
    +-- activate existing FileSail host(path)
    |       |
    |       +-- one ShellRoot / QML engine
    |               |
    |               +-- WindowRegistry
    |               |     +-- FloatingWindow + BrowserSession #1
    |               |     +-- FloatingWindow + BrowserSession #2
    |               |     `-- ...
    |               |
    |               +-- shared BackendClient
    |               `-- shared bounded preview services
    |
    `-- start host(path) when no instance owns activation

Noctalia plugin
    |
    +-- inactive panel: no FileSailView/session ownership
    `-- active panel: acquire session/backend, release on close

filesail-backend
    |
    +-- always-available filesystem operations while acquired
    `-- preview capability created or spawned only on demand
```

Every `FloatingWindow` remains an independent xdg-toplevel that Niri or
Hyprland can tile normally. Sharing an engine is not a tab implementation.

## Architectural contracts

### Window ownership

Introduce a standalone `WindowRegistry` owned by `ShellRoot`. A registry entry
contains a unique window ID, requested initial path, and the minimum state
needed to create one `FloatingWindow`. Each window owns its own
`BrowserSession`, navigation history, selection, view mode, dialogs, and
preview-open preference.

The registry owns creation and destruction:

- an activation request appends a window record;
- closing a window removes exactly that record;
- removing a record destroys its `BrowserSession` and releases its watches and
  preview consumers;
- the host exits when the last window is closed and no operation requiring
  continued lifetime remains.

Do not share navigation, selection, or clipboard state accidentally merely
because the windows share a QML engine. Only deliberate singletons such as
theme data, backend transport, and bounded thumbnail metadata are shared.

### Activation protocol

Use one well-defined activation endpoint for `open(path)`. Prefer Quickshell's
supported IPC mechanism if it can address a packaged path configuration
reliably; otherwise use a small local Unix socket or session D-Bus endpoint.

The protocol must:

1. Accept only an absolute local directory path or an empty value meaning the
   user's home directory.
2. Preserve backend canonicalization as the final authority; launcher
   validation is only an early error check.
3. Return success only after the host accepts the window request.
4. Handle simultaneous first launches without creating two persistent hosts.
5. Reject oversized, malformed, remote, or NUL-containing inputs.
6. Use the current user session only and prevent another user from injecting
   requests.
7. Carry a protocol version for future compatible extension.

The launcher flow is:

```text
normalize CLI input
    |
try activation endpoint
    |-- success -> exit launcher
    `-- no owner -> start FileSail host with initial path
                       |
                       `-- publish endpoint before accepting later requests
```

Avoid unbounded retry loops. Use a short bounded retry to cover the startup
race, then return a useful error.

### Backend ownership

Add explicit acquire/release semantics to `BackendClient`:

- a live `BrowserSession` acquires the backend;
- destruction or suspension releases it;
- a request may lazily start it if it is not already running;
- active filesystem mutations hold an operation lease independently of views;
- shutdown occurs only when session and operation lease counts are both zero;
- an optional short idle grace period prevents churn during rapid panel or
  window reopen.

The backend remains one process per FileSail QML engine. In standalone mode it
is shared by all windows. In Noctalia it is shared by all FileSail panel views
within that shell. Backend exit must reject or resolve all pending frontend
callbacks deterministically.

### Noctalia panel ownership

The adapter must discover the actual Noctalia panel lifecycle rather than
assuming `visible` means closed. Once the lifecycle signal is identified:

1. Load `FileSailView` only when the panel becomes active, unless Noctalia
   requires the geometry placeholder earlier.
2. If a persistent geometry item is required, keep only a lightweight
   placeholder resident and put the browser view behind a loader.
3. On close, cancel read/preview work, unsubscribe the directory watch, clear
   selection and decoded content, release the backend session lease, and
   destroy the browser tree after any host-owned close animation completes.
4. Do not cancel a committed copy/move/Trash mutation merely because the panel
   closes; its operation lease keeps the backend alive until completion.
5. Reopening creates a clean session at the adapter's configured initial path,
   falling back to the user's home directory. Last-path persistence is not part
   of this migration and may be added later without retaining the old view.

This contract must also cover plugin disable/uninstall and Noctalia shutdown.

### Preview-service ownership

Implement preview dependency loading in two measured stages:

1. Lazily construct `PreviewService` and establish its D-Bus connections only
   on the first preview capability or content request. Destroy it after an idle
   period once it has no active jobs.
2. Measure mapped and private memory. Because directly linked Qt DBus and
   libarchive libraries may still be mapped at backend startup, proceed to an
   on-demand `filesail-preview` helper only if lazy construction does not save
   enough memory.

If a separate preview helper is justified:

- keep filesystem mutation/listing methods in `filesail-backend`;
- use the same bounded, versioned newline-delimited JSON framing conventions;
- start the helper on the first preview request and stop it after idle timeout;
- proxy or route cancellation by request ID;
- never allow helper failure to terminate the filesystem backend or shell;
- remove preview-only library links from `filesail-backend` once the helper is
  established;
- retain all local-path and regular-file validation in the preview helper.

## Implementation phases

### Phase 0: lifecycle instrumentation and design spike

1. Add counters/logging for live windows, browser sessions, backend leases,
   operation leases, watches, preview jobs, and helper processes.
2. Measure one through four current standalone windows to establish the
   per-window fixed cost.
3. Verify which Quickshell IPC/instance-discovery mechanism works for installed
   path-based configurations and document the result.
4. Identify Noctalia's panel-created, opened, closing, closed, disabled, and
   destroyed signals and whether its geometry placeholder must stay resident.
5. Write lifecycle state diagrams before changing launch behavior.

Exit criteria: activation transport and Noctalia lifetime hooks are known, and
the current process/window cost curve is recorded.

### Phase 1: one standalone engine with multiple windows

1. Add `WindowRegistry` and a reusable standalone window component.
2. Move the current `FloatingWindow` and `FileSailView` construction behind the
   registry model without changing the shared `FileSailView` API.
3. Add the versioned activation endpoint and `open(path)` handler.
4. Change development and installed launchers to activate the existing host
   first instead of unconditionally using `--allow-duplicate`.
5. Handle concurrent first launch with endpoint ownership and bounded retry.
6. Remove a registry record on window close and quit after the final safe
   window closes.

Exit criteria:

- four launcher invocations produce four independently tiled windows under one
  `qs` process and one backend process;
- each window has independent navigation, selection, clipboard, and dialogs;
- closing one window leaves the others intact;
- closing the last window leaves no FileSail process when no operation is
  active.

### Phase 2: explicit backend leases and lazy startup

1. Make backend process `running` derive from lease/request state rather than
   being permanently true.
2. Acquire and release session leases in `BrowserSession` lifecycle hooks.
3. Hold operation leases for mutations and release them on every completion,
   failure, backend exit, and teardown path.
4. Add a bounded idle shutdown timer.
5. Define behavior when a backend exits while several windows have pending
   requests, including optional lazy restart for later reads.

Exit criteria:

- constructing no session starts no backend;
- several windows still create only one backend;
- closing a view releases its watches and session lease;
- an active mutation can finish safely after its initiating window closes;
- the backend exits after the final lease and idle grace period.

### Phase 3: Noctalia panel suspension/unloading

1. Introduce the lightweight persistent geometry placeholder if required.
2. Load the browser tree when the host reports the panel active.
3. Sequence close animation, cancellation/release, and loader deactivation.
4. Cover plugin disable and shell shutdown paths.
5. Verify that rapid close/reopen cannot leak a second session or unwatch the
   newly active session's directory.

Exit criteria:

- closed-panel incremental PSS returns close to the plugin-enabled baseline;
- there are no FileSail directory watches or preview consumers while closed;
- the backend observes the lease policy from Phase 2;
- opening and closing remains visually and functionally compatible with
  Noctalia.

### Phase 4: on-demand preview service

1. Add lazy construction and idle destruction inside the current backend.
2. Measure idle backend PSS and mappings before and after the change.
3. If the improvement is insufficient, create the isolated preview helper and
   remove its dependencies from the main backend.
4. Preserve capability detection, thumbnail batch limits, cancellation, text
   limits, archive limits, and error behavior defined in the memory plan.

Exit criteria:

- preview dependencies do not create active objects or D-Bus subscriptions
  before the first preview request;
- the preview service/helper exits after becoming idle;
- filesystem browsing and mutations continue if preview startup or execution
  fails;
- helper processes never accumulate across open/close cycles.

## Failure handling and migration

- Keep a temporary launcher escape hatch that forces a new instance while the
  activation path is being stabilized; do not make it the normal path.
- If activation reaches an incompatible protocol owner, report the version
  mismatch rather than silently starting an uncontrolled duplicate.
- If one shared backend crashes, surface the error to every affected window and
  allow later read requests to restart it. Do not replay mutations
  automatically.
- If the Noctalia lifecycle API is unavailable in a supported version, fall
  back to explicit session suspension even if the lightweight view wrapper must
  remain instantiated.
- Preserve old backend protocol methods throughout migration so installed QML
  and backend versions fail compatibly rather than misrouting operations.

## Verification strategy

### Automated coverage

Add tests for:

- activation path validation and protocol versioning;
- simultaneous first-launch arbitration;
- repeated activation producing windows in one host;
- independent per-window state;
- registry cleanup on arbitrary close order;
- session and operation lease accounting on all success/failure paths;
- backend lazy startup, idle shutdown, crash, and restart;
- panel open/close/disable cycles and watch cleanup;
- preview service lazy start, failure isolation, cancellation, and idle exit;
- host shutdown while reads, previews, and mutations are active.

### Runtime scenarios

Measure PSS/USS and process counts for:

1. one, two, and four standalone windows;
2. closing windows in different orders;
3. Noctalia with the plugin disabled, enabled but closed, and open;
4. opening/closing the panel 20 times;
5. preview never used, used once then closed, and repeatedly used;
6. closing the initiating UI during a long copy or move;
7. backend and preview-helper failure with multiple windows open.

The expected standalone curve is one large fixed `qs` cost followed by a much
smaller marginal cost per additional window. The expected closed-panel state is
no live browser session, directory watch, preview consumer, or unnecessary
backend/helper process.

### Required project checks

Run the backend tests, both QML lint commands, and bounded standalone launch
after each phase. Multi-window tests must confirm that the compositor still
receives separate normal windows. No test may leave a FileSail, backend, or
preview-helper process running.

## Out of scope

This plan does not create a dedicated native Qt Quick host and does not rewrite
the standalone interface using Qt Widgets or GTK. Reconsidering the UI toolkit
would require a separate product and architecture decision.
