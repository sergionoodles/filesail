# Thumbnail cache validation and incremental delivery

Status: draft; implementation has not started.

## Outcome and scope

Fix two problems in `src/backend/previewservice.cpp`: stale cached thumbnails
can be accepted, and generated thumbnails are withheld until their entire
Tumbler batch finishes. Keep Tumbler as the generator and preserve the shared
freedesktop cache, existing thumbnail appearance, and final JSON responses.

This plan is independent of [original image previews](image-preview-quality-plan.md).
Replacing Tumbler, changing thumbnail sizes, and building new image generators
are outside its scope.

## Current behavior

- `cachedThumbnail()` hashes the encoded local-file URI and searches the
  requested flavor followed by smaller flavors. It checks that a candidate is
  a regular, non-symlink file, but never checks PNG metadata against the source.
- `thumbnails()` records a size/mtime fingerprint, but that fingerprint does
  not establish whether an existing PNG describes the current source.
- `tumblerReady()` only logs. `finishThumbnail()` scans the cache and delivers
  every result after `Finished` or the 15-second timeout. A mixed batch also
  withholds its initial cache hits while uncached files are generated.
- `BackendClient` already dispatches unsolicited events separately from final
  responses. `PreviewManager` already tracks request IDs, batches, consumers,
  and decoding leases; reuse these mechanisms.

## 1. Validate each cache candidate

Keep URI hashing and flavor order. For every candidate:

1. Preserve `localRegularFile()` validation and existing symlink rejection.
   Obtain current source information rather than trusting client metadata.
2. Read PNG metadata with Qt's PNG support through `QImageReader`; require a
   readable PNG with a valid, bounded image size. Explicitly select PNG so a
   cache filename cannot dispatch arbitrary image formats. Add `Qt6::Gui` to
   the backend build; retain `QCoreApplication` and headless operation. Do not
   introduce a handwritten PNG parser.
3. Require matching `Thumb::URI` and `Thumb::MTime`. Compare mtime in integer
   Unix seconds, as specified by freedesktop, rather than the millisecond
   fingerprint used internally. Validate `Thumb::Size` when present; its
   absence alone is not a cache miss. Reject missing required fields, invalid
   numbers, or mismatches.
4. Treat an invalid candidate as a miss and continue through the existing
   flavor fallback. If none validate, ask Tumbler to generate the thumbnail.
   Do not delete another application's cache files.
5. Recheck the source fingerprint after validation and after generation. If
   it changed, do not publish the old result as ready. Let a refreshed listing
   issue a request for the new version; avoid an unbounded retry loop.

Keep the URI representation consistent between hashing, stored metadata, and
comparison. Do not resolve symlinks differently merely for hashing. Test spaces,
Unicode, `%`, `#`, and `?` in names.

Run cache inspection on the existing bounded read pool, with cancellation
checks, rather than adding image I/O to the backend event loop. Inspect owned
files/readers in the worker and return values to the event thread, which alone
updates request maps and writes protocol output. Bound input/metadata work and
any thumbnail decode; verify Qt's PNG metadata behavior using actual fixtures,
including text chunks after image data. Keep the service alive until these
workers finish, including after cancellation.

The standard's second-resolution mtime plus optional size cannot detect every
same-size edit within one second. Preserve the internal millisecond fingerprint
where available, but do not claim stronger interoperability than the cache
format provides.

## 2. Deliver ready items before the batch finishes

Add an optional `incremental: true` parameter to `thumbnailBatch`. Existing
clients keep the existing final-response behavior. FileSail's QML client opts
in and receives events shaped as follows:

```json
{
  "event": "thumbnailReady",
  "requestId": 42,
  "items": [
    {
      "path": "/home/user/Pictures/photo.jpg",
      "fingerprint": "123456:1750000000000",
      "status": "ready",
      "url": "file:///home/user/.cache/thumbnails/normal/example.png"
    }
  ]
}
```

The example cache filename is illustrative; production URLs retain MD5 names.
An event has no top-level response `id` and never completes the request.

- Publish validated initial cache hits promptly, even if the same batch needs
  generation. For an entirely cached batch, the immediate final reply suffices.
- On Tumbler `Ready`, resolve its handle to the live request and intersect the
  signaled URIs with that request's queued items. Validate the resulting cache
  files before publishing; a signal alone is not proof of a valid thumbnail.
- Remember which items have been published. Repeated signals must not produce
  repeated updates or decoding leases. Keep events bounded by the existing
  maximum batch size of 64.
- Keep one complete final response for every normally completed request,
  including ready items already published. Finalize unresolved items using
  existing status vocabulary. A failed Queue call must not leave terminal
  results marked `queued` with no outstanding work.
- Coordinate `Ready` validation workers with `Finished`: do not finalize a
  request while its accepted validation work can still publish an event.
  Finalization revalidates source identity and does not retain stale success.
- Preserve cancellation semantics: canceled preview requests can suppress their
  original response, while the cancellation request receives its own reply.
  Suppress late events after cancellation, timeout, service shutdown, or final
  completion. Use request identity beyond an unguarded numeric lookup in delayed
  callbacks, and do not let an old timeout affect a later request.
- Make timeout cleanup dequeue outstanding Tumbler work and release mappings,
  jobs, and callbacks exactly once. Handle Tumbler disappearance the same way.

Audit Queue/Dequeue ordering while wiring these callbacks. Prefer asynchronous
D-Bus calls if the current blocking calls prevent correct signal registration
or responsiveness; test signals adjacent to the Queue reply and cancellation
before a handle arrives. This is bounded lifecycle work, not a new scheduler.

## 3. Apply incremental updates in QML

Add an explicit `Connections` property in `PreviewManager` listening to
`BackendClient.eventReceived`. Factor result application out of `completeBatch`
so an event can update records and grant leases without clearing the batch.

Accept an item only when its request is still active, its path belongs to that
batch, and `requests[key]` still identifies that request. Compare the returned
fingerprint to the requested entry's size and parsed modification timestamp;
discard superseded versions. Preserve the original requested path in results
even if backend URI normalization is needed internally.

Final completion alone clears tracking. Both event and final application must
be idempotent; late callbacks cannot overwrite records owned by a newer request.
On a transport failure, preserve already validated ready items and mark only
unresolved records failed. On source changes, invalidate obsolete records.
Clear old event eligibility when the backend stops or a batch is canceled.

Review `FileVisual` reload behavior when regeneration replaces a PNG at the
same URL. A changed content revision must force a reload even though the URL
is unchanged; duplicate final results must not trigger another decode.

## Files and implementation order

1. `src/backend/previewservice.{h,cpp}`, `backendserver.{h,cpp}`, and
   `CMakeLists.txt`: cache validation, bounded worker lifecycle, regression tests.
2. The same backend files: incremental events and terminal cleanup.
3. `qml/core/BackendClient.qml`, `PreviewManager.qml`, and, if needed,
   `qml/components/FileVisual.qml`: opt-in, event application, image reload.
4. `docs/architecture.md`: document event and cache-validation contracts.

## Verification and acceptance

Extend `tests/backend-smoke.sh` for cache fixtures and protocol validation.
Add a focused integration test with a fake Thumbnailer1 on an isolated
`dbus-run-session`; never depend on the user's real Tumbler or cache. Use a
temporary `XDG_CACHE_HOME` and deterministic signal ordering.

- Accept valid external thumbnails; reject mismatched URI/mtime/size, missing
  required metadata, corrupt PNGs, and unsafe candidates. Accept absent optional
  size metadata. Cover flavor fallback and unusual filenames.
- With two generated files, emit `Ready` for A while withholding B's completion.
  Assert A's event arrives before `Finished`, followed by one complete response.
  Repeat with one cache hit and one generated file.
- Cover duplicate/unknown signals, simultaneous batches, source edits during
  generation, cancellation, timeout, Tumbler failure, and late worker completion.
  Interleave events with other replies and split incoming JSON across writes.
- In a focused QML harness, verify immediate display, no duplicate leases,
  stale-event rejection, same-URL regeneration, and cleanup after navigation.

For implementation, run the repository build, CTest, and shared/host QML lint
commands from `AGENTS.md`. Run a bounded standalone launch through
`Configuration Loaded` and terminate that test instance. Acceptance requires a
valid early thumbnail to appear while another file in its batch is still pending,
and a modified source never to be accepted merely because its cache path exists.

## References

- [Freedesktop cache validation](https://specifications.freedesktop.org/thumbnail/latest/modifications.html)
- [Thumbnail metadata and URI rules](https://specifications.freedesktop.org/thumbnail/latest-single/)
- [Qt image metadata APIs](https://doc.qt.io/qt-6/qimagereader.html)
