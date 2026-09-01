# File previews implementation plan

## Status

Approved design for later implementation. This document does not describe an
already-shipped protocol and should be updated if implementation discoveries
change any contract below.

## Objective

Add content previews without putting file decoders or filesystem work in the
Quickshell process. The feature has two surfaces:

1. Explorer thumbnails for files shown in list and grid views.
2. A side preview panel driven by the current selection.

The first supported content families are:

- Raster images and SVG.
- Video poster frames.
- PDF first pages.
- Plain text, source code, and Markdown with syntax highlighting.
- Archives as a bounded, read-only contents listing.

The design remains independent of Noctalia, Niri, Hyprland, and window types.
It extends the existing preview seam without introducing tabs or moving native
code into the shell process.

## User-visible behavior

### Selection routing

Selection routing uses the complete selected-entry set, not only the primary
selection.

| Selection | Side panel behavior |
| --- | --- |
| No entries | Hide the panel content or show its neutral empty state. |
| One raster image or SVG | Show the image provider as a one-item grid using the largest useful cached flavor. |
| Multiple entries, all raster images or SVG | Show every selected entry in a virtualized image grid. |
| One video | Show a large poster frame and available file metadata. |
| One PDF | Show the first page and page-count metadata when available. |
| One text, source, or Markdown file | Show bounded, read-only, syntax-highlighted source. |
| One supported archive | Show a bounded list of archive members and summary metadata. |
| One directory or unsupported file | Show basic metadata and the normal file icon. |
| Multiple entries containing any non-image | Show a selection summary; do not silently preview only the image subset. |

SVG counts as an image for multi-selection behavior. Markdown counts as text
and is displayed as highlighted source; rendering Markdown to HTML is outside
the initial scope.

The image grid must preserve directory order so its layout does not change as
selection order changes. `primarySelectionPath` remains meaningful for focus
and backward compatibility, but it does not determine whether the grid is
eligible.

### Explorer thumbnails

- Grid view uses 128-pixel thumbnails for images, SVG, videos, and PDF files.
- List view uses the same normal-flavor thumbnail in the existing icon-sized
  area. The delegate geometry remains fixed while the image loads.
- A video badge overlays video posters so they cannot be confused with images.
- Directories, archives, text files, unsupported files, failed previews, and
  unreadable files continue to use `FileIcon`.
- Thumbnail failures are quiet in the explorer. A failed thumbnail must not
  cause repeated work while the file is unchanged.
- Thumbnails are requested only for instantiated delegates and a small
  `cacheBuffer`, never eagerly for every item in a directory.

### Side panel layout

- The panel remains a `SplitView` child with a preferred width near the current
  300 scaled pixels.
- The panel should have a user-facing toggle and remember its enabled state
  once settings persistence exists. Until then, default it to enabled.
- At widths where the sidebar, browser minimum, and preview minimum cannot all
  fit, collapse the preview panel rather than violating the browser minimum.
- All surfaces and controls use the central `Theme` radius tokens. FileSail's
  square-corner convention remains unchanged.
- Loading, unsupported, truncated, password-protected, and error states use
  stable panel geometry so selection changes do not resize the browser.

## Architectural overview

```text
FileBrowserPane / PreviewPanel
             |
        PreviewManager (QML singleton)
             |
         BackendClient
             |
   filesail-backend PreviewService
       |                         |
 Tumbler over D-Bus       bounded preview jobs
       |                  /                    \
XDG thumbnail cache   KSyntaxHighlighting    libarchive
       |
 cached PNG file URLs returned to QML
```

Tumbler owns visual thumbnail generation and the freedesktop thumbnail cache.
FileSail owns request prioritization, selection routing, highlighted text, and
archive listings. No image, SVG, video, PDF, or archive bytes cross the JSON
protocol.

## Repository changes by layer

### Shared QML UI

#### `qml/core/BrowserSession.qml`

Add a stable, ordered selection projection containing the full directory-entry
objects for selected paths. Each entry must include at least:

- `name`
- `path`
- `url`
- `mimeType`
- `size`
- `modified`
- `isDirectory`
- `isSymlink`
- `isReadable`

Recompute the projection when either selection state or
`DirectoryModel.revision` changes. Iterating the directory model and selecting
matching paths gives deterministic directory order and avoids re-statting in
QML.

Expose a monotonically increasing selection revision. Preview consumers use it
to reject late results after rapid selection or navigation changes.

#### `qml/components/FileSailView.qml`

- Install FileSail's built-in `PreviewPanel` as the default preview component.
- Expand `previewContext` to include `selectedEntries`, `selectedPaths`,
  `primarySelectionPath`, and `selectionRevision`.
- Preserve the existing `selectedPath` property during the first protocol
  iteration so external test or host providers do not break immediately.
- Separate "the user enabled the preview pane" from "this selection has
  previewable content". The panel router, not the outer loader, owns empty and
  unsupported states.
- Add a preview toggle action and ensure compact hosts can collapse the panel.

#### New shared components

Create small provider components rather than one large conditional component:

- `qml/components/FileVisual.qml`
  - Fixed-size icon/thumbnail wrapper shared by list and grid delegates.
  - Shows `FileIcon` until a thumbnail reaches the ready state.
  - Never requests thumbnails for directories or ineligible MIME types.
- `qml/components/PreviewPanel.qml`
  - Routes the complete selection to a provider.
  - Owns loading, empty, unsupported, and multi-selection summary states.
- `qml/components/ImageSelectionPreview.qml`
  - A `GridView`, including for the one-image case.
  - Uses large or x-large cached thumbnails according to available width and
    device-pixel ratio.
  - Gives every tile an accessible name and keyboard focus behavior without
    stealing focus merely because selection changed in the browser.
- `qml/components/VisualFilePreview.qml`
  - Large poster/first-page surface for one video or PDF.
  - Adds a metadata footer and video/PDF type badge.
- `qml/components/TextFilePreview.qml`
  - Read-only selectable text, vertical and horizontal scrolling, monospaced
    font, truncation notice, and language label.
  - Treats backend output as generated markup only; source text is escaped by
    the backend.
- `qml/components/ArchivePreview.qml`
  - Virtualized member list with name, kind, and uncompressed size.
  - Makes no extraction or open-member action available initially.
- `qml/components/FileMetadataPreview.qml`
  - Fallback for directories, unsupported files, and preview errors.

Register new shared components in `qml/components/qmldir` and ensure the CMake
install rule continues to include them.

#### `qml/core/PreviewManager.qml`

Add a singleton that is the only QML caller of preview backend methods. It
must:

- Deduplicate requests by path, file size, modification time, provider, and
  requested flavor.
- Maintain `idle`, `queued`, `loading`, `ready`, `unsupported`, and `error`
  states.
- Batch explorer requests over a short debounce window instead of sending one
  Tumbler D-Bus request per delegate.
- Give side-panel requests higher priority than explorer requests.
- Limit active non-Tumbler requests to two.
- Track consumers so recycled delegates can release interest.
- Drop queued work with no consumers.
- Request backend cancellation for active preview work with no consumers.
- Cache only metadata and thumbnail URLs in memory. Do not retain file contents
  after the relevant selection changes.
- Clear stale state when path, size, or mtime changes.
- Expose a revision per result so an `Image` can reset its source before
  reusing the same freedesktop cache path after regeneration.

Use `Image.asynchronous: true`, bound `sourceSize`, and fixed delegate geometry.
Set `cache: false` for generated cache files when necessary to guarantee that a
regenerated file at the same URL is reloaded.

All visual providers load only generated cache PNGs. They do not use the
original raster, SVG, video, or PDF file as a QML `Image.source`.

### Backend protocol client

Extend `qml/core/BackendClient.qml` with typed helpers instead of calling the
generic request API from UI components:

- `requestThumbnails(items, flavor, priority, onSuccess, onFailure)`
- `requestTextPreview(path, appearance, onSuccess, onFailure)`
- `requestArchivePreview(path, onSuccess, onFailure)`
- `requestPreviewCapabilities(onSuccess, onFailure)`
- `cancelPreview(requestId)`

`cancelPreview` must be distinct from mutation cancellation. Copy, move,
rename, trash, and mkdir operations must never be interrupted through the
preview cancellation path.

When the generic request timeout expires for a preview request,
`BackendClient` must also send preview cancellation to the backend rather than
only deleting the callback as it does today.

### Backend service

Add `src/backend/previewservice.{h,cpp}` and keep preview routing out of
`fileoperations.cpp`. `BackendServer` owns one `PreviewService` and forwards
the preview protocol methods to it.

Add Qt DBus support to the backend for Tumbler. The service must continue to
process filesystem requests while preview requests are outstanding.

Preview requests count against a separate, much smaller limit than the current
general active-job limit. Directory listings and mutations always have higher
resource priority than explorer thumbnails.

## Protocol additions

All requests retain the existing numeric `id`, `method`, and `params` framing.
Additive response fields preserve protocol compatibility.

### `thumbnailBatch`

Request:

```json
{
  "id": 41,
  "method": "thumbnailBatch",
  "params": {
    "items": [
      { "path": "/home/user/Pictures/a.svg", "mimeType": "image/svg+xml" },
      { "path": "/home/user/Videos/b.mp4", "mimeType": "video/mp4" }
    ],
    "flavor": "normal",
    "priority": "background"
  }
}
```

Ready items arrive incrementally as protocol events so one slow decoder does
not delay every other delegate:

```json
{
  "event": "thumbnailReady",
  "requestId": 41,
  "path": "/home/user/Pictures/a.svg",
  "fingerprint": "opaque-backend-value",
  "url": "file:///home/user/.cache/thumbnails/normal/example.png"
}
```

Per-item errors use a corresponding `thumbnailError` event with `requestId`,
`path`, `fingerprint`, and a bounded error code. A final ordinary response
closes the batch after Tumbler emits `Finished`:

```json
{
  "id": 41,
  "ok": true,
  "items": [
    {
      "path": "/home/user/Pictures/a.svg",
      "status": "ready",
      "url": "file:///home/user/.cache/thumbnails/normal/example.png"
    },
    {
      "path": "/home/user/Videos/b.mp4",
      "status": "unsupported"
    }
  ]
}
```

Rules:

- Supported flavors are `normal`, `large`, `x-large`, and `xx-large`, mapping
  to 128, 256, 512, and 1024 pixels.
- Query Tumbler's supported flavors at startup and fall back to the closest
  smaller available flavor.
- Batch paths by flavor and priority.
- Treat per-item failure as an item status; do not fail an entire batch because
  one file is corrupt or unsupported.
- Include the backend-generated source fingerprint in every item result and
  event so late events cannot be applied to a changed file at the same path.
- Validate the cache file exists and resolves inside the XDG thumbnail cache
  before returning its URL.
- Never accept a caller-provided cache output path.

### `previewCapabilities`

Return the providers actually available at runtime rather than assuming that
install-time dependencies are functioning:

```json
{
  "id": 44,
  "ok": true,
  "tumbler": true,
  "flavors": ["normal", "large", "x-large", "xx-large"],
  "thumbnailMimeTypes": ["image/png", "image/svg+xml", "video/mp4", "application/pdf"],
  "textHighlighting": true,
  "archiveListing": true
}
```

The MIME list may be summarized by the backend internally, but the UI must be
able to distinguish unavailable service, unsupported type, and generation
failure. Refresh capabilities when the Tumbler D-Bus service owner changes.

### `textPreview`

Request:

```json
{
  "id": 42,
  "method": "textPreview",
  "params": {
    "path": "/home/user/project/README.md",
    "appearance": "dark"
  }
}
```

Response:

```json
{
  "id": 42,
  "ok": true,
  "kind": "text",
  "mimeType": "text/markdown",
  "language": "Markdown",
  "encoding": "UTF-8",
  "truncated": false,
  "bytesRead": 8192,
  "lineCount": 180,
  "html": "<pre>escaped and highlighted content</pre>"
}
```

Limits are backend constants, not client-controlled values:

- At most 256 KiB read from the source.
- At most 4,000 lines returned.
- At most 32 KiB from any one logical line before truncation.
- At most 2 MiB of generated JSON/HTML output.

Detect UTF-8, UTF-8 BOM, UTF-16LE BOM, and UTF-16BE BOM. Files with NUL bytes
outside recognized UTF-16 or a strong binary-control-byte ratio return
`unsupported` rather than replacement-character soup. A file ending in the
middle of a UTF-8 sequence must be truncated back to a valid boundary.

Select the syntax definition with
`KSyntaxHighlighting::Repository::definitionForFileName()` first, then MIME
type, then plain text. Markdown extensions such as `.md`, `.markdown`, and
`.mdown` must route to the Markdown definition even when the MIME database
returns generic text.

The backend must HTML-escape every source character before adding its own
markup. Generated output contains no links or embedded images. Choose a
KSyntaxHighlighting light or dark theme based on the appearance parameter;
never load arbitrary theme paths supplied by the request.

### `archivePreview`

Request:

```json
{
  "id": 43,
  "method": "archivePreview",
  "params": { "path": "/home/user/Downloads/source.tar.zst" }
}
```

Response:

```json
{
  "id": 43,
  "ok": true,
  "kind": "archive",
  "format": "tar",
  "filter": "zstd",
  "truncated": true,
  "entryCountAtLeast": 500,
  "entries": [
    {
      "name": "source/src/main.cpp",
      "type": "file",
      "size": 4200,
      "modified": "2026-08-30T10:15:00.000Z",
      "encrypted": false
    }
  ]
}
```

Use libarchive to read headers only. Enable its built-in format and filter
support, but never extract members or invoke external decompression commands.

Initial archive policy:

- Support formats libarchive can identify, including zip, tar and compressed
  tar variants, 7z, cpio, ISO images, and readable RAR variants.
- Stop after 500 entries or 4 MiB of cumulative member-name/header metadata.
- Stop after 64 MiB of compressed input has been consumed while scanning
  headers or after a five-second monotonic deadline. Implement libarchive input
  through bounded callbacks so these limits are measurable and enforceable.
- Check cancellation between every entry.
- Do not descend into archives contained inside archives.
- Preserve member paths for display but mark absolute paths, `..` traversal,
  control characters, and invalid encodings as unsafe. Unsafe names are shown
  in escaped form and never become actionable paths.
- Report encrypted archives and members when libarchive exposes that state.
- Do not ask for passwords in the first release.
- Do not calculate total expanded size by reading member data. Sum only sizes
  supplied by headers and label the result partial when the listing truncates.
- Treat sparse, device, FIFO, socket, and hard-link entries as metadata rows
  only. No member receives an open or extraction action.

### `cancelPreview`

The request targets an outstanding preview request ID. The backend should:

- Dequeue a matching Tumbler handle.
- Set cooperative cancellation for text or archive jobs.
- Ignore late worker completion and suppress the original response after
  cancellation.
- Return success even when the target has just completed, making cancellation
  idempotent from the UI's perspective.

## Tumbler integration

Use the session-bus service
`org.freedesktop.thumbnails.Thumbnailer1` and its `Queue`, `Dequeue`, `Ready`,
`Error`, and `Finished` contract.

The integration should:

1. Validate every requested path as an absolute local path.
2. Require a readable regular file. A symlink is eligible only when its
   resolved target is a readable regular file.
3. Re-detect MIME using `QMimeDatabase` in the backend. Directory listing MIME
   remains extension-based for speed, but a parser request must not trust it.
4. Convert the original cleaned path to an absolute local file URI.
5. Group URI and MIME arrays into one Tumbler queue request per flavor and
   priority.
6. Map Tumbler request handles back to FileSail request IDs and item paths.
7. On `Ready`, derive the standard cache path from the URI and flavor, validate
   it, and record it as ready.
8. On `Error`, mark only the reported URIs failed.
9. On `Finished`, complete unresolved items as unsupported or cancelled.
10. Handle service disappearance without stopping `filesail-backend`; existing
    explorer icons remain usable.

Query Tumbler's supported URI schemes, MIME types, and flavors before queueing.
Unsupported items should be completed locally instead of sent to the service.
Listen for D-Bus owner changes so activation failures and service restarts clear
or rebuild outstanding handle mappings safely.

Use `foreground` scheduling for the selected side-panel item and background or
normal scheduling for explorer batches. Do not enable Tumbler's network cover
provider. FileSail never sends local filenames to an online artwork service.

### SVG behavior

Route `image/svg+xml` and `image/svg+xml-compressed` through Tumbler like other
images. Arch's Tumbler can use registered `.thumbnailer` providers such as the
Glycin SVG thumbnailer. This rasterizes SVG outside Quickshell and produces a
bounded PNG.

Do not bind a QML `Image` directly to the original SVG. The side panel uses an
x-large or xx-large cached raster instead. SVG scripts, links, animations, and
external resources are not executed or fetched by FileSail. If no SVG
thumbnailer is registered, fall back to the normal SVG icon and report an
unsupported side preview.

## Cache behavior

Use the freedesktop cache rooted at:

```text
${XDG_CACHE_HOME:-$HOME/.cache}/thumbnails
```

Do not add a second FileSail visual-thumbnail cache. Tumbler is responsible for
atomic creation, PNG metadata, permissions, modification checks, and failure
records.

Before returning or displaying a cache file:

- Confirm its path is inside the expected flavor directory.
- Confirm it is a regular file and not a symlink.
- Rely on Tumbler to validate `Thumb::URI` and `Thumb::MTime`; use size and mtime
  in the QML in-memory key to prevent stale UI reuse.
- Clear the `Image.source` while regeneration is pending, then assign it again
  after readiness so the Qt image cache cannot display old pixels.

FileSail does not delete the shared thumbnail cache during rename, move, or
trash. Stale shared entries are harmless and are managed by the desktop cache
policy. A future cache settings screen is outside this feature.

Text contents and archive listings are never persisted to disk by FileSail.

## Concurrency and responsiveness

- Tumbler handles its own decoder queue. FileSail batches and cancels requests
  but does not create an additional decoder thread pool for visual thumbnails.
- Text and archive work use a dedicated preview pool capped at two threads and
  never share the directory-read pool or serialized mutation pool.
- Permit at most two active side-panel jobs and two queued explorer batches.
- Cap a thumbnail batch at 64 items. Split larger visible sets into batches.
- Debounce explorer batching for approximately 30-50 ms.
- Drop background results when the directory revision has changed.
- A selected side-panel request may move ahead of queued explorer work, but it
  must not interrupt a mutation.

Cooperative cancellation is sufficient for bounded text reads. Archive jobs
must check cancellation after every header, and their custom libarchive input
callbacks must enforce compressed-byte and monotonic-time limits. If fuzzing
reveals archive inputs that still cannot be bounded reliably, move archive
parsing into a one-shot `filesail-backend --preview-worker` subprocess and
enforce a parent-side wall-clock timeout there before enabling the provider by
default.

## Security and resource limits

Preview files are attacker-controlled input. Apply the same absolute-local-path
and locale-round-trip validation used by filesystem operations, then add these
preview-specific rules:

- Never read from directories, block/character devices, FIFOs, sockets, or
  other special files.
- Permit symlinks only when the resolved target is a regular readable local
  file. Return both display path and resolved safety status internally; never
  replace the user's displayed path with the target path.
- Re-stat before and after non-Tumbler preview work. Discard the result if size,
  mtime, device, or inode changed while it was generated.
- Reject cache outputs outside the XDG thumbnail directory.
- Never pass a preview path through a shell. D-Bus and `QProcess` arguments, if
  later needed, must use structured argument arrays.
- Keep generated dimensions bounded to Tumbler flavors.
- Keep backend JSON responses under the existing framing limit, with smaller
  provider-specific output limits.
- Escape control characters and markup in text and archive member names.
- Do not render HTML, execute Markdown, follow SVG links, extract archives, or
  contact remote cover services.
- Record concise provider errors without echoing file contents into logs.

## Dependencies and packaging

### Build dependencies

Update CMake to discover and link:

- `Qt6::Core`
- `Qt6::Concurrent`
- `Qt6::DBus`
- `Qt6::Gui` for syntax formatting types if required by KSyntaxHighlighting
- `KF6::SyntaxHighlighting`
- `LibArchive::LibArchive`

The backend remains a `QCoreApplication`; adding Qt Gui value types does not
turn it into a windowed application.

### Arch runtime dependencies

Required for the agreed feature set:

- `tumbler`
- `ffmpegthumbnailer`
- `poppler-glib`
- `syntax-highlighting`
- `libarchive`

Tumbler pulls in `gdk-pixbuf2`; on current Arch its registered thumbnailers,
including the `glycin` SVG provider backed by `librsvg`, supply broad raster and
SVG coverage. FileSail packaging should make this provider chain explicit for
the promised SVG behavior rather than silently decoding SVG inside Quickshell.

Omarchy 4 already includes `ffmpegthumbnailer` and `qt6-imageformats`, but the
FileSail package must still declare the dependencies it directly promises and
must not rely on unrelated Omarchy applications to keep them installed.

Potential later optional dependencies:

- `libgepub` for EPUB covers.
- `libgsf` for OpenDocument thumbnails.
- `libopenraw` for RAW camera formats.
- `taglib` or `ffprobe` for richer audio metadata and embedded artwork.

Do not add `qt6-webengine` merely for Qt PDF. Tumbler plus Poppler provides the
first-page behavior without that large dependency. Do not add KIO or
`kio-extras` unless a later product decision chooses the KDE thumbnailer stack
instead of Tumbler.

## Implementation phases

### Phase 1: selection and UI contracts

- Add ordered selected-entry projection and selection revision.
- Add `PreviewPanel` routing and all stable empty/loading/error states.
- Add the preview toggle and compact-width collapse behavior.
- Extend the central `Theme` contract with a host-neutral light/dark appearance
  value used to select the KSyntaxHighlighting theme.
- Preserve the old single-path external provider contract temporarily.

Acceptance criteria:

- Routing is correct for zero, one, all-image multi-selection, and mixed
  multi-selection.
- Navigation and directory refresh cannot leave a stale preview visible.
- A narrow window remains usable with the preview enabled.

### Phase 2: thumbnail infrastructure and explorer visuals

- Add Qt DBus and `PreviewService`.
- Integrate Tumbler capability discovery, incremental events, queueing,
  cancellation, owner-change handling, flavor discovery, and cache-path
  validation.
- Add `PreviewManager` batching and `FileVisual`.
- Enable raster image, SVG, video, and PDF thumbnails in both explorer modes.

Acceptance criteria:

- Cold-cache and warm-cache browsing work.
- Requests remain proportional to instantiated delegates in a confirmed
  5,000-entry directory.
- Fast scrolling does not show another file's thumbnail in a recycled delegate.
- Missing or stopped Tumbler degrades to icons without breaking navigation.

### Phase 3: image selection grid and single visual previews

- Add virtualized all-image selection grid.
- Add large video poster and PDF first-page providers.
- Add metadata footer and provider-specific badges.

Acceptance criteria:

- Raster images and SVG can be mixed in the same image selection grid.
- One-image and many-image states use the same provider without layout jumps.
- Any non-image in a multi-selection switches to the summary state.

### Phase 4: highlighted text and Markdown

- Add the bounded text reader and binary detection.
- Integrate KSyntaxHighlighting filename/MIME definition selection.
- Add safe generated markup and the QML read-only viewer.
- Route Markdown to highlighted source.

Acceptance criteria:

- Common source formats and Markdown receive the expected definition.
- Plain text falls back cleanly.
- Invalid UTF-8, binary data, huge lines, and large files cannot exceed limits.
- Source containing HTML/script tags is displayed literally and never treated
  as executable markup.

### Phase 5: archive contents

- Add libarchive header-only listing.
- Add entry limits, cancellation, unsafe-name display, and archive metadata.
- Add the virtualized archive member list.

Acceptance criteria:

- Zip, tar, tar.gz, tar.xz, tar.zst, 7z, and a supported RAR sample are covered.
- Corrupt, encrypted, traversal-bearing, and archive-bomb fixtures fail or
  truncate safely.
- No test extracts a member or creates a filesystem path from a member name.

### Phase 6: polish and compatibility cleanup

- Add settings persistence for preview visibility and optional size thresholds.
- Measure cache behavior, scrolling, memory, and selection latency.
- Document packages and user-facing troubleshooting.
- Remove the legacy single-path provider contract only after integrations have
  migrated.

## Verification plan

### Backend protocol tests

Extend the protocol test suite with fixtures and cases for:

- Relative path, remote file URL, URL query/fragment, NUL, and unsafe-locale
  rejection.
- Directory, FIFO, socket, device, broken symlink, and symlink-to-regular-file
  behavior.
- Partial JSON framing and multiple preview requests in one input stream.
- Thumbnail batching with mixed ready, unsupported, and corrupt files.
- Tumbler unavailable, disappearing mid-request, error, and timeout behavior.
- Tumbler partial ready/error, out-of-order event, late event, owner restart,
  and percent-encoded URI behavior using a fake private-session D-Bus service.
- Cache path containment and symlinked-cache-file rejection.
- Duplicate request coalescing and cancellation.
- Cache hit and invalidation after source mtime or size changes.
- UTF-8/BOM decoding, invalid encoding, binary detection, truncation boundaries,
  huge lines, and output caps.
- HTML escaping of text such as `<script>`, `&`, quotes, and bidi/control
  characters.
- KSyntaxHighlighting definition choice for extensionless scripts, source files,
  and Markdown.
- Archive format coverage, entry limits, corrupt headers, encrypted entries,
  traversal names, absolute names, control characters, and cancellation.

Prefer focused C++ tests for provider internals and keep representative
end-to-end cases in `tests/backend-smoke.sh`.

### QML tests

Cover:

- Preview routing for every selection row in the behavior table.
- Stable directory-order image grids.
- Stale response suppression after selection changes and delegate recycling.
- Thumbnail placeholder and error fallback.
- Panel collapse at narrow widths.
- Text truncation and archive truncation notices.
- Plain-text treatment of all backend error and metadata strings.

### Manual and runtime verification

- Run the repository's required build, test, and lint checks:

  ```sh
  cmake --build build
  ctest --test-dir build --output-on-failure
  qmllint -I /usr/lib/qt6/qml -I qml qml/core/*.qml qml/components/*.qml shell.qml
  qmllint -I /usr/lib/qt6/qml -I /etc/xdg/quickshell/noctalia-shell -I qml integrations/noctalia/*.qml
  ```

- Perform a bounded standalone launch and verify it reaches
  `Configuration Loaded`; do not leave a Quickshell instance running.
- Exercise the standalone host and Noctalia panel with the same fixtures.
- Test cold and warm thumbnail caches on local SSD and a slow mounted volume.
- Confirm explorer interaction stays responsive while thumbnails, syntax
  highlighting, and archive listing are active.
- Inspect the backend and Tumbler processes for unbounded CPU, memory, or queued
  work during rapid navigation.

## Explicit non-goals for the first release

- Video or audio playback inside the preview panel.
- Multipage PDF navigation, text selection, or PDF search.
- Rendered Markdown or HTML.
- Archive extraction, member opening, nested archive inspection, or passwords.
- Recursive folder-size or folder-content previews.
- Network downloads for video or audio artwork.
- Office conversion through headless LibreOffice.
- 3D, CAD, or executable-file rendering.

These can be added as independent providers later without changing the
selection contract or compositor-neutral UI boundary.
