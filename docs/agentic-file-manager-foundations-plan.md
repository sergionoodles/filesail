# Agentic file manager foundations: implementation plan

## Purpose

This milestone turns FileSail's sidebar into a workspace-oriented navigator and
adds folder-context awareness to the browser toolbar. It is the foundation for
later agent actions, but it does not yet run an AI model, execute an AI CLI, or
index file contents.

The deliverables are:

1. An icon-only sidebar section selector for Places, Projects, and Bookmarks.
2. Persistent user-defined Projects and Bookmarks, both represented by local
   filesystem folders.
3. A folder-context strip that reports AI-agent configuration, Git, and common
   programming ecosystems for the successfully loaded directory.
4. Stable backend and QML contracts that later agent workflows can build on.

The word "tab" in this document refers only to the three sidebar category
selectors. It does not introduce file-browser tabs. Separate compositor-managed
windows remain FileSail's windowing model, and the second pane remains reserved
for previews.

## Product decisions for v1

These decisions remove ambiguity from the first implementation:

- A Project is a saved local directory intended to become the root of future AI
  workflows.
- A Bookmark is also a saved local directory, but is only a quick-navigation
  shortcut. File bookmarks and arbitrary URLs are deferred.
- The same directory may be both a Project and a Bookmark. Within one collection,
  adding the same canonical directory twice is idempotent.
- The request's Bookmarks empty-state reference to "the first project" is treated
  as a wording typo. The UI will say "first bookmark."
- The selected sidebar section is per-window/session state and defaults to
  Places. The Project and Bookmark collections themselves are durable and shared
  across standalone and embedded FileSail instances.
- Adding an entry in v1 means "add the currently loaded folder." This avoids
  introducing a platform-specific directory picker. A picker and custom labels
  can be added later without changing the storage shape.
- Context detection in v1 applies to markers in the currently loaded directory
  only. It does not silently walk ancestors and does not recursively scan
  descendants. The status copy must say "in this folder" so a nested directory
  is never presented as a verdict on its parent repository. Project-aware
  inheritance is deferred until a saved Project can provide an explicit and
  understandable scan boundary.
- "AI ready" means at least one detection with category `ai`. Git or a language
  manifest alone does not make a directory AI ready.
- Detection proves only that a known marker exists. It does not prove that the
  corresponding executable is installed, configured, authenticated, or usable.
- Badges are informational in v1. They do not launch tools or execute project
  content when clicked.

## Existing architecture and constraints

The plan keeps the boundaries in [architecture.md](architecture.md):

- `qml/components/FileSailView.qml` owns the shared browser composition and is
  the integration point between sidebar actions, the browser session, and
  notices.
- `qml/components/Sidebar.qml` currently owns the logo/name header and the
  Places list. It should remain presentational and host-neutral.
- `qml/core/PlacesModel.qml` is an in-memory singleton for built-in XDG places.
  It already exposes the reusable `{ label, iconName, path, kind }` role shape.
  It should remain read-only rather than becoming a mixed persistence layer.
- `qml/core/BrowserSession.qml` is the façade for navigation and operations.
  Sidebar rows must continue to navigate through it.
- `qml/core/DirectoryModel.qml` accepts only the active backend response, adopts
  the backend's canonical path, and emits `loaded` after a successful load.
- `qml/core/NavigationController.qml` commits history only after that successful
  load. Neither saved locations nor context detection may bypass this invariant.
- `qml/components/BrowserToolbar.qml` already contains a navigation row and an
  action row. It is the host-neutral insertion point for the context strip.
- `src/backend` is the only layer that should inspect or persist local filesystem
  state. The newline-delimited JSON protocol already supports additive response
  fields and asynchronous read/mutation pools.
- There is currently no FileSail-owned persistence layer. Noctalia's theme JSON
  reader is host-specific and must not be reused for user locations.
- Multiple standalone windows intentionally run as separate compositor-managed
  processes. Persistence must therefore be safe across processes, not just
  across QML objects in one process.
- Shared components must use `Theme` tokens, square corners, explicit child
  properties on `QtObject`, and no Noctalia/Niri/Hyprland imports.

The toolbar's existing navigation, terminal, search, and file-operation actions
remain part of the component contract. The later implementation must insert the
new strip without replacing or bypassing those actions and their `BackendClient`
and `BrowserSession` paths.

## Target architecture

```text
                                    +----------------------+
                                    | PlacesModel          |
                                    | built-in, in-memory  |
                                    +----------+-----------+
                                               |
+----------------------+             +----------v-----------+
| locations JSON      |<----------->| SavedLocationsModel  |
| XDG config, atomic  |  backend    | projects/bookmarks   |
+----------------------+  protocol  +----------+-----------+
                                               |
                                    +----------v-----------+
                                    | Sidebar              |
                                    | selector + lists     |
                                    +----------+-----------+
                                               |
                                               | navigate(path)
                                               v
+----------------------+  list      +----------------------+  accepted response
| filesail-backend     |<---------->| DirectoryModel       |------------------+
| list + context scan  |            +----------------------+                  |
+----------------------+                                                       |
                                                                                v
                                                                     +------------------+
                                                                     | FolderContextBar |
                                                                     +------------------+
```

There are two separate state streams:

- Saved locations are durable user configuration and have explicit CRUD
  protocol methods.
- Folder context is derived filesystem metadata and is returned atomically with
  the accepted directory listing.

## User experience specification

### Sidebar selector

Replace the existing brand/logo row at the top of `Sidebar.qml` with a single
row of three equal-width, icon-only controls:

| Section | Suggested Lucide icon | Tooltip and accessible name |
| --- | --- | --- |
| Places | `map-pinned` or `house` | Places |
| Projects | `briefcase-business` or `folder-kanban` | Projects |
| Bookmarks | `bookmark` | Bookmarks |

Implementation requirements:

- Use exclusive selection with an `activeSection` string whose allowed values
  are `places`, `projects`, and `bookmarks`.
- Use a `ButtonGroup` or equivalent exclusive state. Do not create browser tabs
  or navigation-history entries merely by switching sidebar sections.
- Every icon control must support mouse hover, a translated tooltip, keyboard
  focus/activation, `Accessible.name`, and `Accessible.role: Accessible.PageTab`.
- Keep the active indicator, hover fill, and focus outline within `Theme`.
- Verify new icon codepoints against the bundled Lucide font before adding them
  to `LucideIcon.qml`; unknown icon names currently fall back silently.
- Keep the current Places content and selection behavior unchanged below the
  selector.

Use a `StackLayout` or mutually exclusive content items below the selector. A
dedicated `SidebarTabButton.qml` is preferable to changing `IconButton.qml`
globally because the existing component is a generic checkable button with an
`Accessible.Button` role.

### Projects and Bookmarks lists

Both user-defined sections share the same visual list component and row schema.
Rows show a folder-oriented icon and the saved label, use the canonical path for
current-directory highlighting, and emit the existing `navigate(path)` signal.

Initial labels are derived from the directory basename. The filesystem root is
labelled `/`. Custom labels, drag reordering, and grouping are deferred, but the
stored record has a stable ID so those features do not need an identity
migration.

Each populated section includes:

- a translated section heading;
- a compact "add current folder" control with a tooltip;
- saved folder rows;
- a remove/unpin action that is keyboard-accessible and does not navigate;
- a visible unavailable state for stored paths that no longer exist.

Do not silently remove missing paths. Disable their navigation action, retain a
tooltip such as "Folder is unavailable," and keep their remove action enabled.

### Empty states

Projects:

- Title: `No projects yet`
- Hint: `Add the current folder to use it as a project.`
- Action: `Add current folder`

Bookmarks:

- Title: `No bookmarks yet`
- Hint: `Add the current folder for quick access.`
- Action: `Add current folder`

The action must use the successfully loaded `session.directory.path`, not a
pending address-bar value. Success and failure should flow through
`FileSailView.showNotice()`.

### Folder context strip

Add a slim third toolbar row between the navigation/breadcrumb row and the file
operation row. A separate row keeps breadcrumbs and the existing filter field
usable at compact widths.

The strip contains:

1. A leading status:
   - `AI ready in this folder` when at least one `ai` signal exists;
   - `No AI markers in this folder` otherwise.
2. Ordered context badges: AI tools first, then version control, then
   programming ecosystems/toolchains.
3. A horizontally clipped/flickable badge region at narrow widths rather than
   wrapping the toolbar or shrinking breadcrumbs.

Each badge is a non-interactive semantic item with:

- a generic Lucide icon and short translated label;
- square `Theme.radiusS` surfaces;
- plain-text rendering for all backend evidence;
- an accessible name;
- a tooltip naming the evidence, for example
  `Claude Code detected from CLAUDE.md`.

Do not ship third-party brand artwork in v1. Generic icons plus labels avoid an
asset/licensing dependency and fit the current Lucide-only icon system. If brand
logos are added later, review their licenses and keep them out of the theme
contract.

While navigation is pending, retain the old path, listing, and context together.
On a successful response, replace all three together. On navigation failure,
leave all three unchanged. This mirrors the existing browser behavior and
prevents badges for one folder from appearing over another folder's contents.

## Saved locations data model

### On-disk location

Store a deterministic, host-independent file at:

```cpp
QDir(QStandardPaths::writableLocation(QStandardPaths::GenericConfigLocation))
    .filePath("filesail/locations.json")
```

Do not use a QML `Settings` namespace because standalone FileSail runs under
Quickshell while embedded FileSail runs inside Noctalia, and their process
identities differ.

### Schema

```json
{
  "version": 1,
  "projects": [
    {
      "id": "2c471bf6-4cc7-4a8d-a96d-a5f84c2cdecb",
      "label": "filesail",
      "path": "/home/user/workspace/filesail"
    }
  ],
  "bookmarks": []
}
```

`available` is derived when records are read and returned to the client; it is
not persisted. The response record shape is:

```json
{
  "id": "2c471bf6-4cc7-4a8d-a96d-a5f84c2cdecb",
  "label": "filesail",
  "path": "/home/user/workspace/filesail",
  "available": true
}
```

### Validation and durability

- Accept collection names only from the closed set `projects`, `bookmarks`.
- Reuse the backend's absolute-local-path, NUL, ambiguous URL, and locale
  round-trip protections.
- On add, require an existing directory, canonicalize it, and use the canonical
  path for duplicate identity.
- On read, preserve records whose path has disappeared and mark them
  unavailable.
- Generate stable UUIDs in the backend. Never use mutable list indexes as IDs.
- Cap each collection at 1,000 entries, labels at 255 Unicode scalar values,
  and the complete config input at 1 MiB.
- Reject malformed documents without overwriting them and return a useful error.
  The backend remains stateless between requests; the QML model retains its last
  valid snapshot when a reload fails.
- Define version handling explicitly: accept version 1; reject unknown newer
  versions without modification; migrate older versions through named code
  paths when they exist.
- Use `QLockFile` around read-modify-write operations because separate FileSail
  windows have separate backend processes.
- Reload the latest document after acquiring the lock, apply one mutation, and
  commit with `QSaveFile` so updates are atomic and do not lose another process's
  changes.
- Create the `filesail` config directory before the first watch/write, with
  user-only permissions where the platform supports them.
- Use a dedicated `QFileSystemWatcher` for saved locations rather than sharing
  the reference-counted navigation watcher. Watch the containing directory,
  debounce changes, and emit a `savedLocationsChanged` protocol event. Watching
  the directory is more robust than watching only a file that `QSaveFile`
  atomically replaces.
- If the config directory is deleted or its watch is lost, recreate it, re-add
  the watch, and emit one reload event. Also run this ensure/watch step before
  every locations operation so recovery does not depend on one particular
  filesystem notification.
- The QML singleton reloads after this event. Duplicate self-notifications are
  harmless; stale or failed loads must not clear the last valid models.

### Backend protocol

Add the following methods while retaining the existing newline-delimited
framing and request envelope.

List:

```json
{"id":31,"method":"locations.list","params":{}}
```

Add current folder:

```json
{
  "id": 32,
  "method": "locations.add",
  "params": {
    "collection": "projects",
    "path": "/home/user/workspace/filesail"
  }
}
```

Remove:

```json
{
  "id": 33,
  "method": "locations.remove",
  "params": {
    "collection": "projects",
    "id": "2c471bf6-4cc7-4a8d-a96d-a5f84c2cdecb"
  }
}
```

Every success returns the complete current snapshot so the client can replace
both collections atomically:

```json
{
  "id": 32,
  "ok": true,
  "locations": {
    "version": 1,
    "projects": [],
    "bookmarks": []
  }
}
```

`locations.list` belongs on the read pool. Add/remove belong on the single
mutation pool, with the cross-process lock providing serialization beyond one
backend process. Duplicate add should return success with the existing record
rather than creating an error toast. Removing an unknown UUID is also an
idempotent success/no-op that returns the current snapshot and does not show an
error toast.

## Folder-context detection contract

### Why detection extends `list`

Add context as an optional, additive field on the existing `list` response,
requested with `includeContext: true`. Do not create a second `inspect` request
in v1.

The existing directory enumeration already sees every direct child before
`showHidden` and the text filter are applied. Reusing it:

- avoids a second traversal of local, mounted, FUSE, or slow directories;
- prevents a second request from competing for the two read workers;
- keeps listing and context under the same request-ID stale-response guard;
- preserves the large-directory confirmation path;
- makes path, entries, and badges change atomically after a successful load.

`BreadcrumbBar` performs lightweight listing requests for completion. It should
omit `includeContext` so completion does no extra marker work.

### Additive response schema

```json
{
  "id": 41,
  "ok": true,
  "path": "/home/user/workspace/filesail",
  "parentPath": "/home/user/workspace",
  "entries": [],
  "context": {
    "version": 1,
    "signals": [
      {
        "id": "agent-instructions",
        "category": "ai",
        "evidence": ["AGENTS.md"]
      },
      {
        "id": "git",
        "category": "vcs",
        "evidence": [".git"]
      },
      {
        "id": "node",
        "category": "technology",
        "evidence": ["package.json"]
      }
    ]
  }
}
```

Backend output contains stable semantic IDs, categories, and bounded evidence.
It does not contain localized UI labels, icons, colors, or tooltips. A QML
`ContextBadgeCatalog.qml` maps IDs to those presentation properties and provides
a generic fallback for future backend IDs.

Derive `aiReady` in QML from `signals.some(signal => signal.category === "ai")`
instead of returning a redundant boolean that could drift from the signal list.

### V1 marker registry

All checks are case-sensitive on Linux. One signal may collect several evidence
markers but appears only once. The type and symlink rules are uniform unless a
row says otherwise:

- names shown as files must be regular files;
- names ending in `/` must be directories;
- inspect type with non-following metadata (`lstat`/`symlink_status`);
- reject symbolic links, FIFOs, sockets, devices, and other special entries as
  marker evidence in v1;
- `.git` is the sole multi-type exception and may be a real directory or a real
  regular file, but not a symbolic link.

AI and agent configuration:

| Signal ID | Display label | Direct markers |
| --- | --- | --- |
| `agent-instructions` | Agent instructions | `AGENTS.md`, `AGENTS.override.md`, `.agents/` |
| `claude` | Claude Code | `CLAUDE.md`, `.claude/` |
| `gemini` | Gemini CLI | `GEMINI.md`, `.gemini/` |
| `cursor` | Cursor | `.cursor/`, `.cursorrules` |
| `windsurf` | Windsurf | `.windsurf/`, `.windsurfrules` |
| `copilot` | GitHub Copilot | `.github/copilot-instructions.md`, `.github/instructions/` |

`AGENTS.md` and `.agents/` are deliberately presented as generic agent
instructions rather than a Codex-only badge because the convention is consumed
by multiple tools. Official Codex documentation still makes `AGENTS.md` a valid
AI-readiness marker.

Repository and technology signals:

| Signal ID | Display label | Direct markers |
| --- | --- | --- |
| `git` | Git | `.git` as a directory or regular file |
| `node` | Node.js | `package.json` |
| `typescript` | TypeScript | `tsconfig.json` |
| `python` | Python | `pyproject.toml`, `setup.py`, `Pipfile`, `requirements.txt` |
| `rust` | Rust | `Cargo.toml` |
| `go` | Go | `go.mod` |
| `jvm` | JVM | `pom.xml`, `build.gradle`, `build.gradle.kts` |
| `cpp` | C/C++ | `CMakeLists.txt`, `meson.build`, direct `*.c`, `*.cc`, `*.cpp`, `*.h`, `*.hpp` evidence |
| `ruby` | Ruby | `Gemfile` |
| `php` | PHP | `composer.json` |
| `swift` | Swift | `Package.swift` |
| `dotnet` | .NET | direct `*.sln`, `*.csproj`, `*.fsproj` evidence |

Keep extension-based evidence bounded: return at most three known evidence names
per signal and never echo an unbounded filename list. These are ecosystem
inferences, not guarantees that a folder builds or that every source language
has been identified.

### Detection safety and performance

- Run detection in the backend read worker, never in the shell process.
- Reuse the canonical path established by `listDirectory`.
- Feed safe direct entries into a small `FolderContextDetector` before hidden
  and text-filter checks, then perform only the fixed nested probes needed for
  `.github/copilot-instructions.md` and `.github/instructions/`.
- Never execute a detected tool, inspect the user's `PATH`, access the network,
  or parse/execute project configuration.
- Do not read file contents in v1. If content inspection is added later, it must
  reject special files, cap bytes, and treat all data as untrusted.
- Do not recursively traverse arbitrary directories and do not walk ancestors.
- Detect `.git` by safe name/type checks without opening repository internals.
  Accept a regular `.git` file for worktrees and submodules.
- Do not let `showHidden` or the directory text filter change signals.
- Preserve the 5,000-entry confirmation behavior. A directory that requires
  confirmation does not produce context until its listing is accepted.
- Keep signal and evidence order deterministic so UI and tests do not flicker.
- A direct marker add/remove will be caught by the existing root directory
  watcher. Adding a nested Copilot marker inside an already existing `.github`
  directory may require F5 or navigation away/back in v1. Live nested-marker
  watches are a later enhancement.

### Explicitly deferred inherited context

When Project roots exist, a later version may report both local and inherited
context while browsing inside a registered Project. That design should:

- stop at the registered Project path rather than walking silently to `/`;
- tag evidence with `local`, `project`, or `inherited` scope;
- watch relevant ancestor marker directories with reference counting;
- define precedence for nested agent instructions;
- show the evidence scope in tooltips.

This is intentionally not folded into v1 because it changes both semantics and
watcher ownership.

## File-by-file implementation map

### Backend

- `src/backend/savedlocations.h/.cpp` (new)
  - Own schema parsing, validation, canonicalization, availability checks,
    locking, atomic writes, and snapshot serialization.
  - Remain stateless across protocol jobs: each list reads an atomic disk
    snapshot and each mutation reloads under the cross-process lock. This avoids
    shared mutable state between the read and mutation pools.
- `src/backend/foldercontext.h/.cpp` (new)
  - Own the stable detection registry, direct-entry accumulation, fixed nested
    probes, de-duplication, evidence bounds, and deterministic sorting.
- `src/backend/fileoperations.h/.cpp`
  - Add location list/add/remove operations.
  - Invoke `FolderContextDetector` from `listDirectory` only when
    `includeContext` is true and attach the additive response field.
- `src/backend/backendserver.h/.cpp`
  - Dispatch `locations.list`, `locations.add`, and `locations.remove` to the
    correct pools.
  - Own/debounce a dedicated config-directory watcher, recover lost watches, and
    emit `savedLocationsChanged`; do not mix config paths into navigation watch
    reference counts.
- `CMakeLists.txt`
  - Compile the two focused backend modules.
  - Register any split protocol test scripts if the existing smoke test becomes
    too large.

### QML core

- `qml/core/SavedLocationsModel.qml` (new singleton)
  - Own explicit `ListModel` properties for projects and bookmarks.
  - Load once, expose `addCurrentDirectory(collection, path)` and
    `remove(collection, id)`, replace both models from full snapshots, and
    reload on `savedLocationsChanged`.
  - Retain the last valid snapshot on backend failure and expose failures through
    callbacks/signals for `FileSailView` notices.
- `qml/core/ContextBadgeCatalog.qml` (new singleton)
  - Map stable signal IDs to translated labels, generic Lucide icons, category
    order, and tooltip formatting; include an unknown-ID fallback.
- `qml/core/DirectoryModel.qml`
  - Send `includeContext: true` for browser listings.
  - Add `folderContext` with an empty versioned default.
  - Replace it only inside the accepted successful-list callback, beside path
    and entries.
- `qml/core/BackendClient.qml`
  - Add typed wrappers for the three locations methods. Context requires no new
    method because it is part of `listDirectory`.
- `qml/core/qmldir`
  - Register both new singletons.

### Shared components

- `qml/components/SidebarTabButton.qml` (new)
  - Icon-only category selector with tooltip, checked/focus state, keyboard
    activation, and page-tab accessibility semantics.
- `qml/components/SidebarLocationList.qml` (new)
  - Shared list/empty-state rendering for Projects and Bookmarks, including add,
    navigate, unavailable, and remove signals.
- `qml/components/ContextBadge.qml` (new)
  - Static accessible badge with plain-text evidence tooltip.
- `qml/components/FolderContextBar.qml` (new)
  - AI-ready status, ordered badge presentation, and compact overflow behavior.
- `qml/components/Sidebar.qml`
  - Replace the brand header with the section selector.
  - Add `activeSection`, injected project/bookmark models, and narrow signals:
    `navigate(path)`, `addCurrentDirectoryRequested(collection)`, and
    `removeLocationRequested(collection, id)`.
  - Do not import the backend or BrowserSession.
- `qml/components/FileSailView.qml`
  - Inject `SavedLocationsModel` models into Sidebar.
  - Handle add/remove signals using the accepted current directory and existing
    notice surface.
- `qml/components/BrowserToolbar.qml`
  - Insert `FolderContextBar` and bind it to
    `session.directory.folderContext`.
- `qml/components/LucideIcon.qml`
  - Add only verified glyph mappings needed by the selector and generic badges.
- `qml/components/qmldir`
  - Register all new shared components.

No host adapter should require feature logic. `shell.qml` and
`integrations/noctalia/Panel.qml` should inherit the feature through
`FileSailView`; only bounded visual adjustments are acceptable if the extra
toolbar row exposes a host sizing issue.

## Delivery phases

### Phase 1: Folder-context backend contract

1. Add detector unit boundaries and the `includeContext` list option.
2. Implement the conservative v1 registry and additive response.
3. Add backend protocol tests before changing QML.
4. Confirm old list callers still work when the option is absent.

Exit criteria: fixture directories produce deterministic signals without
affecting listing, filtering, hidden-file behavior, or large-directory guards.

### Phase 2: Context strip UI

1. Add `DirectoryModel.folderContext` and the presentation catalog.
2. Add context badge/bar components and integrate the third toolbar row.
3. Verify atomic context changes during success, failed navigation, refresh, and
   rapid navigation.
4. Verify compact layout, tooltips, plain-text evidence, and accessibility.

Exit criteria: users can distinguish AI-ready, Git, and technology context at a
glance in both hosts without toolbar overlap.

### Phase 3: Saved-locations backend

1. Implement versioned config loading and full-snapshot responses.
2. Add canonical/idempotent add and ID-based remove.
3. Add cross-process locking, atomic writes, directory watching, and reload
   events.
4. Cover malformed data, unavailable paths, and concurrent updates.

Exit criteria: separate backend processes converge on one durable collection
without lost updates or config corruption.

### Phase 4: Sidebar rework

1. Add `SavedLocationsModel` and typed backend wrappers.
2. Replace the brand header with accessible icon-only section selectors.
3. Extract shared location-list and empty-state components.
4. Wire add/remove/navigation through `FileSailView` and existing notices.
5. Verify Places remains the default and existing navigation behavior is
   unchanged.

Exit criteria: both empty states guide the first add, entries survive restart,
missing entries remain manageable, and switching sidebar categories never
creates browser history.

### Phase 5: Stabilization and documentation

1. Run the complete verification matrix below.
2. Update `README.md` and `docs/architecture.md` with saved-location ownership,
   the additive context response, and the new agentic-foundation boundary.
3. Capture one screenshot showing sidebar selectors and mixed context badges.
4. Record follow-up issues for inherited Project context and actual agent
   actions rather than expanding v1 late.

## Verification plan

### Backend protocol tests

Extend `tests/backend-smoke.sh` or split focused scripts registered in CTest.

Folder context:

- Empty directory returns `context.version == 1` and `signals: []`.
- Every AI, Git, and technology marker maps to the expected stable ID,
  category, and bounded evidence.
- `.git` is detected as both a directory and regular file.
- Hidden markers are detected when `showHidden` is false.
- Context is unchanged by a text filter that excludes the marker from entries.
- Multiple markers for one signal are de-duplicated and ordered.
- Similar names, wrong case, and wrong entry types do not false-positive.
- `includeContext` absent preserves the old response contract.
- Partial framing and multiple requests remain compatible.
- Relative, empty, unsafe, and ambiguous local URL paths still fail.
- Large-directory confirmation still occurs; confirmed loading returns context.
- Direct marker addition/removal appears on the next list request.

Saved locations:

- First run returns two empty collections and creates no corrupt partial file.
- Add rejects empty, relative, URL-ambiguous, missing, file, unsafe-locale, and
  NUL-containing paths.
- Add canonicalizes symlinked directory paths and is idempotent within one
  collection.
- The same path can exist once in each collection.
- Remove validates collection and UUID shape; an unknown well-formed UUID is a
  successful no-op returning the current snapshot.
- Missing saved paths survive reload with `available: false`.
- Malformed, oversized, and unknown-newer-version config files are not
  overwritten.
- Atomic-write failure leaves the previous valid file intact.
- Two backend processes adding different entries do not lose either update.
- First run creates and watches the missing config directory safely.
- Config-directory changes emit a debounced event and clients reload.
- Deleting and recreating the config directory restores the watch and converges
  clients after the next locations operation.
- Existing newline framing, queue limits, and request IDs remain intact.

### Static checks

Run the repository-prescribed checks appropriate to the implementation:

```sh
cmake --build build
ctest --test-dir build --output-on-failure
qmllint -I /usr/lib/qt6/qml -I qml qml/core/*.qml qml/components/*.qml shell.qml
qmllint -I /usr/lib/qt6/qml -I /etc/xdg/quickshell/noctalia-shell -I qml integrations/noctalia/*.qml
```

### Manual UI matrix

Verify in both the standalone host and Noctalia panel:

- Places is selected by default and all three selector tooltips appear after the
  normal delay.
- Mouse and keyboard can focus/activate each selector; accessibility names and
  roles are correct.
- Projects and Bookmarks have distinct, correct empty copy and add actions.
- Add current folder, duplicate add, remove, restart persistence, and
  unavailable-path removal all behave predictably.
- Saved-row navigation, back/forward history, canonical path highlighting, and
  failed navigation preserve existing invariants.
- A directory with several AI markers, `.git`, and multiple ecosystem manifests
  produces ordered, de-duplicated badges and accurate tooltips.
- A non-AI code directory shows `No AI markers in this folder` while retaining
  Git and ecosystem badges.
- A nested directory without direct markers also says `No AI markers in this
  folder`; v1 must not imply that the parent Project/repository lacks AI setup.
- Empty directories do not leave stale badges from the previous directory.
- Direct marker create/remove refreshes through the existing debounce.
- Sidebar widths of 174 and 190 scaled pixels remain usable.
- The context strip remains usable at the standalone minimum width and in the
  compact Noctalia view without overlapping breadcrumbs, search, or actions.
- Every surface remains square and uses only shared Theme tokens.
- A bounded standalone runtime reaches `Configuration Loaded` and no test
  Quickshell instance remains running.

## Risks and mitigations

| Risk | Mitigation |
| --- | --- |
| "Tabs" conflicts with FileSail's no-tabs rule | Name them sidebar sections in code/docs; they only swap sidebar lists. |
| Multiple windows lose saved-location changes | Lock, reload-under-lock, atomic replace, and config-directory change events. |
| Marker list becomes an unmaintainable pile of conditions | Isolate a table-driven detector with stable IDs and focused fixtures. |
| Badges imply a tool is installed or working | Phrase tooltips as "marker detected" and never probe executables in v1. |
| Filter/hidden settings change context unexpectedly | Detect from raw enumeration before UI filtering. |
| Rapid navigation mixes entries and context | Return both in one list response and update only for the accepted request ID. |
| Slow or hostile directory trees stall the shell | Run in the backend, remain shallow, bound evidence, and preserve large-folder confirmation. |
| Nested `.github` changes are not live | Document F5/navigation freshness in v1; add nested watches only with explicit ownership later. |
| New detector IDs break an older UI | Provide a generic QML fallback for unknown IDs and keep schema versioned. |
| Third-party logos create licensing/theme work | Use generic Lucide icons and text labels in v1. |

## Follow-up roadmap toward a full agentic file manager

This foundation intentionally leaves the following as separate product/design
decisions:

1. Project-root-aware inherited context and monorepo boundaries.
2. A folder trust model before any instruction file is read or agent is run.
3. Installed-agent discovery and explicit launch adapters for supported tools.
4. A task/prompt surface with permission previews, command confirmation, and
   clear working-directory scope.
5. Agent run lifecycle, streaming logs, cancellation, and per-window/process
   ownership.
6. Sandboxing and write boundaries that preserve FileSail's absolute-local-path
   and Trash-only deletion guarantees.
7. Project indexing/search, opt-in content parsing, ignore rules, and privacy
   controls.
8. Reusable workflows/skills and agent capability badges distinct from mere
   marker detection.

None of those features should execute because a badge was detected. Detection,
trust, configuration, and execution must remain separate stages.

## Marker reference notes

The initial registry should be rechecked when implemented because tool
conventions evolve. The v1 choices are grounded in current primary documentation:

- [OpenAI Codex: custom instructions with AGENTS.md](https://learn.chatgpt.com/docs/agent-configuration/agents-md)
- [Claude Code: CLAUDE.md and `.claude/rules/`](https://code.claude.com/docs/en/memory)
- [Cursor project rules](https://docs.cursor.com/context/rules)
- [GitHub Copilot custom-instructions support](https://docs.github.com/en/copilot/reference/custom-instructions-support)
- [Gemini CLI context files](https://github.com/google-gemini/gemini-cli/blob/main/docs/cli/gemini-md.md)
