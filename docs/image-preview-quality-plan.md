# Original-image previews

Status: draft; implementation has not started.

## Outcome and scope

Display selected images from their original files at enough resolution for the
preview pane and screen scale. Keep list/grid thumbnails and their Tumbler/cache
pipeline unchanged. This can ship independently of the
[thumbnail correctness plan](thumbnail-correctness-plan.md).

Use the existing Qt Quick `Image` type for the first implementation. No custom
decoder, generated preview disk cache, native QML extension, or new backend
protocol is needed for ordinary supported images. Video/PDF previews, zoom/pan,
animation playback, and additional codecs are outside this change.

## Current behavior and cause

`PreviewPanel.qml` routes all-image selections to `ImageSelectionPreview.qml`.
Its delegates use `FileVisual` with `flavor: "x-large"` and a fixed
`thumbnailSize: 512`. `FileVisual` displays the cached PNG returned by
`PreviewManager`, not the original image. The backend can also fall back to a
smaller cached flavor. Enlarging those pixels cannot recover source detail.

Directory entries already contain `url`, constructed with `QUrl::fromLocalFile`
by the backend, plus `path`, `size`, and `modified`. Reuse this URL rather than
constructing `file://` strings in JavaScript.

## 1. Separate the image-preview renderer

Add a small `qml/components/ImageFilePreview.qml` with an entry, an active flag,
and readable readiness/error properties. Replace only the `FileVisual` delegate
inside `ImageSelectionPreview` with this component.

The renderer should:

- Load the backend-provided local `entry.url` using `Image`, asynchronously,
  with aspect-fit rendering, smooth filtering, automatic orientation, and
  image caching disabled. Use the original as the source; bound the decoded
  output to the display target instead of retaining its full native resolution.
- Derive target pixel dimensions from the actual drawable area times
  `Screen.devicePixelRatio`, rounded upward. Remove the fixed 512-pixel ceiling.
  Validate sizing on fractional-scale screens and when moving between screens.
- Use the existing icon plus a small loading/error indication while unavailable.
  On decoding failure, show a clear unavailable state and filename. Do not
  silently report a blurry thumbnail as a successful original-image preview.
- Keep first-frame/static rendering for animated formats. Installed Qt image
  plugins determine coverage; MIME classification alone does not prove support.

Use all available preview width and height for a single image rather than
forcing its cell to be square. Preserve the existing two-column multi-selection
layout, 16-image limit, file accessibility labels, and overflow count. Keep
surfaces square using the shared Theme radius tokens.

## 2. Bound lifetime and repeated work

Preserve GridView pooling, but replace thumbnail-consumer hooks with explicit
activation and release of the original-image renderer. Pooled or offscreen
delegates must clear/unload their image; reused delegates load their current
entry. Opening a folder with many images must not decode its originals until
they are actually selected and visible in the preview.

When the pane closes or its provider is destroyed, release its images. A fast
selection change must clear the previous selection's content immediately and
prevent an old load from changing the new entry's readiness.

Track source identity using URL, size, and modification time. The existing
selection model already compares size/mtime; extend it to compare URL as well.
For a changed fingerprint at the same URL, recreate/reload the `Image` using a
small Loader or an explicit source reset across an event-loop turn. Merely
setting `cache: false` does not make an unchanged source binding reload. Do not
append arbitrary query strings to filesystem URLs.

Coalesce resize-driven decode requests with a short, component-owned Timer
(approximately 100 ms). Reload once geometry settles and immediately on a new
selection. Keep the currently selected image visible during size-only updates
where possible, but never retain another selection's image as its replacement.
Use APIs available at the repository's Qt 6.6 minimum; do not require
`retainWhileLoading`, which was introduced later.

## 3. Report actual preview readiness

`ImageSelectionPreview` currently exposes no `previewReadiness`, so
`PreviewPanel` treats a loaded provider component as ready before its pixels
necessarily load. Add aggregation for active visible delegates:

- `loading` while any required visible image is pending, including initial
  delegate creation;
- `ready` once all required visible originals are decoded successfully;
- `error` once loading settles with one or more failures, with a useful summary.

Offscreen/pooled delegates and entries beyond the 16-image limit do not block
readiness. Successful images remain visible when another image fails. Remove
delegate state on pooling/destruction and reject updates for old entry versions.
Keep aggregation local to this provider; do not build a second global manager.

Exercise `PreviewPanel`, `PreviewPane`, and the existing control adapter so
`preview.show` and state snapshots reflect image loading and errors accurately.

## 4. Resource and architecture limits

This approach reuses Qt's existing asynchronous image loader in the Quickshell
process. It introduces no native extension, but decoding original files there
does not provide the backend process's crash isolation. Document that tradeoff
in `docs/architecture.md` rather than implying all preview work is isolated.

Display-sized output, visible-only activation, and disabled retention in Qt's
image cache limit retained image data. These originals are not covered by
`PreviewManager.maximumDecodeBytes`; do not count its 48 MiB thumbnail lease
budget as protection for them. Decoders can also allocate temporary buffers
larger than their final output. The 16-image limit alone is not a memory bound.

Measure peak and settled memory with large JPEG/PNG images, rapid selection,
resizing, and multiple FileSail windows. Preserve Qt's allocation safeguards.
If those checks show unacceptable memory growth or UI stalls, move original
decoding/resizing into a bounded FileSail worker in a follow-up design before
claiming the approach meets the daily-driver requirement. Do not hide resource
problems by quietly restoring a low-resolution preview ceiling.

## Files and implementation order

1. Add `ImageFilePreview.qml` and switch `ImageSelectionPreview.qml` delegates
   to original URLs, display-sized loading, and active lifetime management.
2. Implement same-file refresh, resize coalescing, and provider readiness.
3. Add a focused preview harness, following the isolated-host pattern in
   `tests/theme-smoke.py`; register it with existing test infrastructure as
   appropriate. Update `docs/architecture.md` for the direct image-rendering path.

`FileVisual`, list/grid delegates, Tumbler generation, and video/PDF provider
behavior should not require changes for this plan.

## Verification and acceptance

Use deterministic high-resolution fixtures containing small text and fine lines
alongside photographs; keep an intentionally blurry cached thumbnail for the
same file. Test with Tumbler absent as well as present.

- Confirm the renderer's source is the original local URL and its requested
  pixels follow preview geometry and DPR. Visually compare a preview larger
  than 512 physical pixels against the original at the same displayed size.
  It must not show the deliberately blurry cache contents.
- Cover landscape, portrait, transparency, EXIF rotation, small originals,
  Unicode and URL-sensitive filenames, and optional formats supported locally.
- Cover missing/unreadable/corrupt files and unsupported codecs. Errors must
  settle visibly without a perpetual loading state or falsely ready provider.
- Rewrite an image at the same path, with a changed observable fingerprint;
  confirm the displayed pixels refresh. Switch selections during loading and
  verify no previous file flashes into the new selection.
- Cover 1, 2, 16, and more than 16 selected images; scrolling, pooling/reuse,
  hiding/reopening the pane, resizing, and changing screen scale. Verify
  readiness includes only currently required visible images.
- Confirm list/grid thumbnails and video/PDF previews retain their current
  behavior. Record memory and responsiveness observations from the stress cases
  above rather than inferring safety from `sourceSize` alone.

For implementation, run shared and host QML lint from `AGENTS.md`, the focused
runtime test, and the existing CTest suite. Confirm a bounded standalone launch
reaches `Configuration Loaded`; terminate all test instances afterward. The
visual acceptance check requires a real Wayland window, including a HiDPI or
fractionally scaled output where available.

## Reference

[Qt Quick Image](https://doc.qt.io/qt-6/qml-qtquick-image.html) documents local
asynchronous loading, orientation, output sizing, caching, and load status.
