# Memory and performance optimization plan

## Status

Proposed implementation plan. This plan covers memory and responsiveness work
inside the existing FileSail processes. Process ownership, multi-window process
sharing, panel lifetime, and helper-process lifetime are covered separately in
[process-architecture-optimization-plan.md](process-architecture-optimization-plan.md).

## Objective

Make FileSail a light, responsive daily-driver while preserving its current
product and security behavior. The first milestone should eliminate accidental
work and unbounded retention; later milestones should reduce repeated scanning,
temporary directory-data copies, and QML object churn.

The plan must preserve these invariants:

- Trash remains the only deletion path.
- Navigation history is committed only after a directory loads successfully.
- Absolute-path validation and transfer safety checks stay in the backend.
- The newline-delimited JSON protocol remains compatible as it evolves.
- Shared components remain independent of Noctalia and compositor APIs.
- The preview pane remains optional and FileSail does not gain tabs.
- All UI surfaces continue to use the shared `Theme` contract and square radii.

## Baseline and success measures

A preliminary local snapshot over `/usr/share` with 289 entries and previews
closed measured approximately 225 MiB PSS for the standalone `qs` process and
5.5 MiB for `filesail-backend`. In the same environment, Nautilus measured
approximately 127 MiB PSS and Thunar 41 MiB. These are directional numbers, not
release gates: the repeatable benchmark suite below must establish the real
baseline before implementation begins.

Use PSS and USS rather than adding raw RSS values. Measure the standalone `qs`
process and `filesail-backend` separately. Treat `tumblerd` as a shared service
and report it separately. For the Noctalia integration, measure the shell's
incremental PSS with FileSail disabled, closed, and open rather than attributing
the entire shell to FileSail.

The optimization is successful when:

1. Closing or disabling previews results in no preview requests and releases
   decoded preview content.
2. Thumbnail bookkeeping has a fixed budget and reaches a plateau during
   repeated navigation.
3. At most one directory listing per browser session is running, with at most
   one follow-up refresh pending.
4. Superseded directory and preview work stops in the backend and does not
   serialize a discarded response.
5. Selecting more than 16 images does not create more than 16 preview cells.
6. Text and archive previews stay within their 500-line and 250-entry limits.
7. Repeated navigation, scrolling, filtering, and preview open/close cycles do
   not produce continuing PSS growth.

## Explicit scope decisions

This plan intentionally does not:

- select or force a different Qt Quick rendering backend;
- remove directory-entry fields that may be useful to future features;
- immediately replace JSON with CBOR, a native model bridge, or a fully paged
  protocol;
- reduce or remove the standalone 2.5-second theme fallback polling;
- move the standalone theme adapter out of `integrations/noctalia`;
- redesign or further compress text-preview representation beyond imposing the
  requested content limits;
- change process architecture or introduce a different standalone UI toolkit.

## Relationship to existing plans

This plan supersedes two behavior-preserving choices in
[ui-component-modularization-plan.md](ui-component-modularization-plan.md):

- preview-provider state must no longer be preserved while the preview pane is
  disabled; inactive providers are destroyed;
- list and grid coordinators may move behind loaders instead of both remaining
  instantiated, provided the public view contract and intended user state are
  preserved;
- the four dialog flows may share one lazily created prompt instead of keeping
  four complete prompt trees mounted.

The modular component boundaries remain valid. These are targeted lifecycle
changes, not a reversal of the shared-UI architecture.

## Workstream 1: preview activation and bounded content

### 1.1 Destroy hidden built-in previews

`PreviewPane.qml` currently creates `PreviewPanel` even when the pane is
disabled; hiding an item does not stop its loaders or release its content.

Implementation:

1. Host the built-in `PreviewPanel` in a `Loader` whose `active` state requires
   both `previewEnabled` and the absence of an external provider.
2. Keep the external-provider loader inactive while previews are disabled.
3. Pass an empty selection while inactive so a provider cannot react during
   loader teardown.
4. Ensure provider destruction cancels its text, archive, and thumbnail work.
5. Preserve the pane's existing `SplitView` geometry and external preview
   contract when it is enabled.

Acceptance criteria:

- Toggling the preview pane off destroys the active provider.
- Changing selection while previews are off produces zero preview protocol
  requests.
- Reopening the pane loads only the current selection.
- External providers receive the same properties as before.

### 1.2 Virtualize the image grid and cap it at 16 images

`ImageSelectionPreview.qml` currently uses `Grid` plus `Repeater`, creating a
delegate for every selected image.

Implementation:

1. Replace the eager grid with a clipped, virtualized `GridView`.
2. Expose at most the first 16 selected images to the grid.
3. Show a lightweight summary when additional selected images are omitted, for
   example “16 of 43 images”. Do not create hidden delegates for the remainder.
4. Request thumbnails only for visible or near-visible cells.
5. Keep directory or mixed selections on the metadata/unsupported path rather
   than attempting an image grid.

Acceptance criteria:

- Selecting 1, 16, 17, or 1,000 images creates no more than 16 image-preview
  model entries and only a viewport-sized set of delegates.
- Selection order remains directory order.
- Extra-selection summary text is correct and accessible.

### 1.3 Right-size decoded images and icons

Implementation:

1. Derive thumbnail decode size from the item's rendered width and height,
   multiplied by the effective device-pixel ratio and clamped to the available
   freedesktop thumbnail flavors.
2. Stop requesting 128px grid images for 46px cells and 1024px previews for a
   roughly 220-300px pane unless the actual pixel size requires them.
3. Set explicit source sizes for icon-theme images where the underlying image
   type does not already guarantee the correct decode size.
4. Replace the Noctalia bar's 1200x1200 `logo.png` load with an appropriately
   sized raster or vector asset, set `sourceSize`, and remove unnecessary
   mipmapping.
5. Avoid keeping a loaded fallback file icon beside a ready thumbnail. Use
   mutually exclusive loaders or clear the inactive source.

Acceptance criteria:

- No decoded preview dimension materially exceeds its rendered physical-pixel
  dimension.
- File icons still appear immediately while thumbnails are unavailable.
- The Noctalia bar icon remains sharp at all supported scale factors without
  decoding the 1200x1200 source.

### 1.4 Bound text and archive previews

Text preview should remain otherwise unchanged. Limit input before creating the
HTML response:

- emit at most 500 lines;
- start with a tunable 65,536-character ceiling so one extremely long line
  cannot bypass the bound;
- set `truncated` only when content exists beyond either emitted limit. Read
  enough input to distinguish exactly 500 lines or 65,536 characters from a
  genuinely truncated preview.

Archive preview should emit at most 250 entries. It reports `truncated` only if
a 251st header exists or another safety bound stops enumeration. The existing
metadata-byte and elapsed-time safety bounds remain as secondary limits. The UI
may label these as preview lines, but the backend limit is 250 archive entries.

Add boundary tests for 499/500/501 text lines, a single oversized line, and
249/250/251 archive entries.

## Workstream 2: bounded thumbnail ownership

### 2.1 Replace session-long result retention with a budgeted LRU

`PreviewManager` currently retains every result for the lifetime of the QML
engine and clones the complete result object to publish each update.

Implementation:

1. Give each thumbnail-result record explicit state, last-use generation, and
   active-consumer count.
2. Enforce an entry/metadata ceiling for result records. Separately, grant
   active image-decode leases using an estimated `width * height * 4` cost.
   Start with a conservative 32-64 MiB active-decode budget and tune it from
   benchmark data.
3. Evict least-recently-used records with no consumers. Records with active
   consumers are pinned; if the decode budget is full, new leases wait rather
   than silently evicting an image that is still displayed.
4. Remove obsolete fingerprints for a path after the file changes.
5. Drop records from older directory generations when they have no consumers.
6. Publish targeted revision changes rather than cloning the full cache.
7. Track live FileSail views in the engine and clear all result metadata,
   pending work, and decode leases when the final view releases ownership. This
   remains necessary when the surrounding Noctalia QML engine stays alive.

Disk thumbnails managed by the freedesktop thumbnail service are not part of
these budgets. `Image.cache: false` should remain in effect unless a later
central decoded-image cache owns a strict budget. A `FileVisual` without a
decode lease keeps its fallback icon and may retry when a higher-priority lease
is released.

### 2.2 Make consumer lifecycle explicit

Implementation:

1. Assign every `FileVisual` a stable numeric consumer token.
2. Track per-key consumer counts rather than stringifying QML objects.
3. Release the old key when `entry`, fingerprint, or flavor changes.
4. Release on delegate pooling as well as destruction, and reacquire when a
   pooled delegate is reused.
5. Remove queued work immediately when its last consumer disappears.
6. Make repeated acquire/release calls idempotent.

### 2.3 Bound batching and make thumbnail lookup linear

Implementation:

1. Split every thumbnail request into protocol batches of at most 64 items.
2. Limit foreground and background in-flight batches separately.
3. Replace consumer-prefix scans with direct per-key counts.
4. Build a path-to-entry map for response matching instead of calling `.find()`
   for every returned item.
5. Avoid copying the complete `results`, `queued`, or `consumers` registry for
   each mutation.

Acceptance criteria for Workstream 2:

- Cache and consumer counters never exceed configured limits in a 20-folder
  navigation loop.
- Scrolling away, switching view mode, closing previews, and destroying a
  window all release their consumer references.
- No protocol thumbnail batch contains more than 64 items.
- A late response cannot resurrect an evicted generation.

## Workstream 3: real cancellation and refresh coalescing

### 3.1 Add protocol-level cancellation

Frontend cancellation currently removes callbacks without stopping native
work. Extend the protocol compatibly with cancellation request IDs and native
cancellation tokens.

Implementation:

1. Associate cancellable directory, thumbnail, text, and archive jobs with an
   atomic token.
2. Check the token during directory enumeration, archive-header iteration, and
   before expensive metadata or response construction.
3. Never serialize or write a completed result after its request is canceled.
4. Keep filesystem mutations outside generic cancellation unless a separate,
   operation-safe cancellation design is approved.
5. Lower the broad 256-job allowance with method-specific queue limits.

### 3.2 Make Tumbler integration asynchronous

`thumbnailBatch` currently enters a nested event loop and stores one global
Tumbler handle, making overlapping requests re-entrant and difficult to cancel.

Implementation:

1. Replace the nested event loop with asynchronous per-handle request state.
2. Keep a bounded request map and route Ready/Error/Finished signals by handle.
3. Dequeue Tumbler work when all consumers cancel it.
4. Time out individual requests without blocking the backend protocol loop.
5. Reuse one `QMimeDatabase` and avoid content sniffing when validated directory
   metadata is sufficient.

### 3.3 Coalesce directory refreshes

Each browser session should own this state machine:

```text
idle -> listing -> idle
           |        ^
           +-> dirty+
```

While a listing is active, new watcher or UI refresh requests set one `dirty`
flag rather than starting more scans. When the active request completes or is
canceled, exactly one follow-up refresh runs if the flag is set.

Also:

- deduplicate a mutation's explicit refresh against its watcher event;
- use adaptive watcher debounce/backoff for bursty directories;
- preserve the current directory contents while refreshing;
- ignore stale responses by session and directory generation.

After this state machine is stable, extend the backend watcher to emit batched
filename-level add/remove/change events and apply them to the current directory
snapshot. A watcher overflow, ambiguous rename, missed generation, or
unsupported filesystem falls back to one coalesced full refresh. This
incremental stage is required, but follows cancellation and coalescing so its
fallback path is safe.

Acceptance criteria:

- Rapid filtering/navigation leaves no abandoned scans.
- A busy watched directory has at most one scan and one pending refresh.
- Copy/move/rename does not trigger duplicate full refreshes.
- The backend protocol remains responsive while thumbnail generation runs.

## Workstream 4: leaner directory and selection paths

This workstream deliberately starts small. Paging, binary transport, and a
native model bridge remain possible follow-ups only if measurements show the
initial changes are insufficient.

### 4.1 Reuse the parsed entry array instead of copying into `ListModel`

The current load path parses a JS entry array, clears a `ListModel`, and appends
every entry individually. This duplicates directory data and sends thousands
of model notifications.

Implementation:

1. Change `DirectoryModel.entries` to own the immutable parsed array for the
   current generation directly.
2. Update list/grid delegates and selection code to consume `modelData` rather
   than `ListModel.get()` proxies.
3. Replace the complete array atomically after a successful load so failed
   navigation continues to show the previous directory.
4. Release the prior generation after delegates have switched.
5. Benchmark peak and settled PSS before considering a more complex transport.
6. Add a configurable hard post-confirmation ceiling, initially 50,000 entries,
   so accepting the existing 5,000-entry warning cannot produce an unlimited
   response. Treat the starting value as a benchmark-tuned safety default.

This retains all existing entry fields for future functionality.

### 4.2 Avoid duplicated folder-context storage and scans

Fold context detection into directory enumeration:

1. Accumulate fixed marker flags and at most three extension examples per
   technology while walking entries.
2. Remove the second `contextEntries` vector.
3. Avoid repeated whole-vector `hasEntry` and extension scans.
4. Recompute context only when the directory contents change, not for local
   filter or sort changes.

### 4.3 Filter and sort without rereading the directory

Implementation:

1. Keep one immutable directory snapshot per generation.
2. Apply text filtering and sort order through a lightweight proxy/index array
   rather than a new backend listing.
3. Preserve directories-first ordering and locale-aware name comparison.
4. Reuse a configured `QCollator` or cached sort keys.
5. Let filesystem watcher changes invalidate the source snapshot.

### 4.4 Add a narrow path-completion method

Add `completeDirectories(parent, prefix, limit)` with a hard limit of eight
results and only the fields needed by the popup. It must support real
cancellation and must not perform or serialize a normal full listing.

### 4.5 Make selection updates incremental

Implementation:

1. Build a path-to-index map once per directory generation.
2. Update the selected-entry array only for paths that changed.
3. Retain complete entry objects by reference rather than copying dictionaries.
4. Remove the duplicate `updateSelectedEntries()` call after directory loads.
5. Keep selected-entry ordering consistent with directory order.

### 4.6 Load expensive metadata on demand

After completing the initial directory changes, profile MIME lookup, date/size
collection, and serialization to choose the exact fields and batch size. Then
add a compatible bounded metadata request for visible, near-visible, and
selected entries. Preserve every existing field in the model contract: entries
outside the loaded range carry an explicit pending value and are filled on
demand. Sorting by a lazy field must fetch the required sort metadata in a
bounded background pass before publishing the new order.

This phase follows the simpler snapshot/proxy work so its design is driven by
measurements, but it is part of this plan rather than an optional future
redesign.

Deferred unless profiling justifies another phase:

- paged or streamed directory listing;
- compact binary/CBOR transport;
- a native model bridge across the current process boundary;
- removing existing entry fields.

## Workstream 5: QML object and allocation cleanup

### 5.1 Load inactive UI only when needed

Use loaders for the active list/grid implementation, active sidebar page, and a
single reusable modal prompt. Saved-location collections that can grow beyond a
small number should use a virtualized list.

Do not mount both list and grid delegates simultaneously. Preserve selection,
scroll restoration where intended, accessibility, and modal focus behavior.

### 5.2 Reduce delegate churn

1. Enable `reuseItems` where supported and implement pool/reuse hooks that
   correctly release thumbnail consumers.
2. Pass `modelData` or typed leaf properties without constructing a new entry
   dictionary in every `FileVisual` binding.
3. Tune list/grid `cacheBuffer` using delegate-count and scroll benchmarks.
4. Consider showing type icons rather than thumbnails in compact list mode if
   measurements show a meaningful benefit.

### 5.3 Remove repeated small allocations

- Move the Lucide codepoint table and context-badge catalog to singleton data.
- Mutate request registries behind targeted revision counters rather than
  cloning the entire object on every request and completion.
- Use maps for path/result lookup instead of repeated linear searches.
- Parse all complete protocol frames before compacting `m_requestBuffer`,
  avoiding repeated front removal.
- Reuse backend helper objects such as `QMimeDatabase` and `QCollator`.
- Fix current QML type-assignment and invalid-color warnings so routine use does
  not generate avoidable logging work.

### 5.4 Build and packaging optimizations

1. Ensure release packages use an optimized, stripped backend build.
2. Evaluate Quickshell-compatible QML cache/AOT compilation for installed QML.
3. Measure startup time and private memory before adopting allocator tuning.
4. Consider allocator arena limits only after unbounded retention and request
   churn are fixed; allocator work must not conceal a lifecycle bug.

The existing 2.5-second standalone theme fallback timer and current theme
adapter location are intentionally unchanged.

## Implementation sequence

Apply the workstreams in this order, keeping each phase independently
reviewable:

1. Add the benchmark harness and counters needed to verify subsequent work.
2. Gate hidden previews and add the 16-image, 500-line, and 250-entry limits.
3. Right-size image/icon decoding and fix the Noctalia bar asset.
4. Introduce the bounded thumbnail LRU and correct consumer lifecycle.
5. Add real cancellation, asynchronous Tumbler requests, and refresh
   coalescing.
6. Replace the frontend `ListModel` copy with one immutable entry snapshot;
   then add incremental watcher deltas and optimize context detection, local
   filter/sort, completion, selection bookkeeping, and visible-range metadata.
7. Lazy-load inactive QML trees and tune delegate reuse/cache buffers.
8. Apply the remaining small allocation and packaging improvements.
9. Re-measure before deciding whether any deferred directory-protocol work is
   warranted.

Do not combine the process-architecture migration with these phases. The
process plan may depend on the cleanup/release APIs introduced here, but each
memory fix should remain measurable in the existing single-window host first.

## Verification strategy

### Automated tests

Add coverage for:

- zero preview requests while the pane is disabled;
- preview provider destruction and cancellation on close;
- image-selection caps at 16;
- text line boundaries at 499/500/501 lines, including exact `truncated`
  semantics;
- text character boundaries at 65,535/65,536/65,537 characters, including
  exact `truncated` semantics;
- archive boundaries at 249/250/251 entries, including exact `truncated`
  semantics;
- thumbnail batches of at most 64;
- cache eviction, consumer refcounts, generation invalidation, and late
  responses;
- true cancellation of directory, thumbnail, text, and archive work;
- one-in-flight/one-dirty refresh behavior;
- mutation/watcher refresh deduplication;
- incremental add/remove/change events and full-refresh fallback behavior;
- rejection above the hard directory-entry ceiling;
- local filter/sort equivalence with current backend ordering;
- path completion returning no more than eight directories;
- watch and consumer counts returning to baseline after destruction.

### Scenario benchmarks

Measure cold and warm runs for:

- empty, small, 1,000-entry, and 5,000-entry directories;
- ordinary files and image/video/PDF-heavy folders;
- list and grid scrolling;
- preview off, one preview, and 16-image preview;
- selecting more than 16 images;
- rapid filter and address-entry typing;
- a busy watched directory;
- repeated navigation through the same 20 folders.

Record settled and peak PSS/USS, active delegates, JS heap, cache entries and
estimated bytes, backend active jobs, watches, CPU time, wakeups, I/O, page
faults, and GPU texture memory where available. Use Qt Creator's QML Profiler
for object/binding/JS-heap work, `heaptrack` or Massif for the backend, and
`perf`/`strace -c -f` for CPU and I/O attribution.

### Required project checks

Run checks appropriate to each phase:

```sh
cmake --build build
ctest --test-dir build --output-on-failure
qmllint -I /usr/lib/qt6/qml -I qml qml/core/*.qml qml/components/*.qml shell.qml
qmllint -I /usr/lib/qt6/qml -I /etc/xdg/quickshell/noctalia-shell -I qml integrations/noctalia/*.qml
```

For QML runtime changes, perform a bounded standalone launch and confirm it
reaches `Configuration Loaded`. Do not leave test Quickshell instances running.
