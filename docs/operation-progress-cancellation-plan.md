# Sidebar operation progress and cancellation: implementation plan

Status: proposed implementation, based on the repository as inspected on
2026-09-13. This document does not implement the feature.

## Goal and scope

Make every operation in the sidebar Activity queue understandable while it is
waiting or running, and let users cancel queued work or stop a long transfer
safely. Prioritize large files, recursive folder copies, and cross-device moves.

Keep the existing single-worker mutation FIFO and shared backend. One queue row
represents one request, which may contain several selected files or folders; the
current nested file belongs inside that row, not in thousands of child rows.
All standalone windows observe the same queue and can cancel its operations,
including windows launched through Noctalia.

Follow [the architecture](architecture.md): filesystem work stays in the native
backend, shared QML stays independent of hosts, and all surfaces use square
`Theme` radius tokens. Preserve path validation, no-replace commits, source
identity checks, metadata preservation, and partial-transfer reporting. Trash
remains the only user-facing deletion path.

## Existing foundation and gaps

| Area | Current behavior | Work needed |
| --- | --- | --- |
| `src/backend/backendserver.{h,cpp}` | Owns a mutation FIFO, operation IDs, queued/running snapshots, `operationChanged`, and `operations.list`. | Add explicit mutation cancellation, per-job tokens, capability fields, and consistent finalization. |
| `src/backend/fileoperations.cpp` | `TransferProgress` reports phases, logical source paths, aggregate bytes, current-file bytes, entries, and top-level counts. Copies use a 256 KiB read/write loop and staging. | Check cancellation inside recursion and file I/O; define rollback and commit boundaries; improve progress semantics and throttling. |
| Existing cancellation | `copyPaths`/`movePaths` accept a token, but the mutation worker passes an empty token. `transferPaths` only checks between top-level sources. Read/preview cancellation can suppress the original response. | Supply real mutation tokens and always return the original mutation's terminal result, even after cancellation. |
| `qml/core/BackendClient.qml` | Keeps ordered operation snapshots, backend identity and event sequence, callbacks, and backend leases. `cancel()` deliberately refuses mutations. | Add a separate mutation-cancel API that retains the original callback and lease. |
| `qml/components/OperationQueue.qml` | Displays the current request and queued requests, with navigation and expand/collapse. | Render existing progress data, phase/status text, and independent Cancel controls. |
| `qml/core/BrowserSession.qml` | Handles success, `completed`, and committed-destination `partial` errors; updates selection and clipboard. | Treat ordinary cancellation as a distinct outcome and preserve recovery details. |
| `tests/backend-smoke.sh` | Covers queue ordering, progress events, terminal responses, staging and transfer safety. | Add interactive cancellation, boundary, cleanup, and lifecycle coverage. |

The initial progress UI can reuse the existing protocol. Cancellation is the
larger change because recursive transfers must stop at safe filesystem boundaries.

## User-visible behavior

### Queue presentation

- Keep the Activity section and its expansion behavior. Replace the ambiguous
  `pending / total` header with a localized summary such as `1 running · 2 queued`.
- The running row shows the operation, selection/folder name, current file,
  progress indicator, compact counters, and a Cancel button. Show the destination
  and full logical source in tooltips or accessible descriptions when elided.
- Queued rows show `Waiting`, their subject, and Cancel. Waiting is a status, not
  a fabricated percentage or animated transfer. Preserve FIFO ordering.
- On a cancel click, immediately disable repeat submission and show
  `Requesting cancellation…`. Once acknowledged, show `Cancelling…` until the
  original operation ends. Keep phase details such as `Restoring source…` visible.
- Preserve click-to-navigate using a separate navigation target and sibling
  Cancel button. Cancellation must never trigger row navigation, and an absent
  navigation path must not disable cancellation.
- Ordinary cancellation needs no extra confirmation: already completed items
  remain completed. Explain this in the Cancel tooltip and terminal notice.
  A normal result can still win a race with a late cancel request.
- Remove the active row only on the original terminal response. Show a concise
  notice such as `Copy cancelled; 2 items completed`. Recovery failures need
  persistent, selectable details with source, destination, and recovery paths.
  Do not rely on a transient, single-line banner for stranded source data.
- Keep sidebar height bounded and pending rows scrollable. Provide keyboard
  focus, accessible Cancel names identifying the operation, text equivalents of
  progress, and animation behavior consistent with `Theme`. Avoid announcing
  every byte update to assistive technology.

### Progress semantics by operation

| Operation/phase | Indicator and counters | Cancellation behavior |
| --- | --- | --- |
| Any queued mutation, including saved locations | Waiting; no percentage | Remove from FIFO before dispatch. |
| Regular-file copy or cross-device copy stage | Determinate aggregate byte bar for the whole selection; current-file bytes remain secondary detail | Cooperative stop during copy, followed by cleanup/rollback. |
| Recursive directory transfer | Cancellable `Scanning…` phase followed by aggregate estimated byte progress, entries processed, and selected items completed; zero-byte trees use entry progress | Check during scanning, traversal, and every I/O chunk. |
| Same-filesystem move | Item counts between atomic renames; indeterminate while renaming | Stop before the next item; an atomic rename already underway finishes. |
| Trash batch | Completed item count out of selected items; indeterminate during each `QFile::moveToTrash` call | Stop between items; finish an in-flight Trash call. |
| Running mkdir, rename, permission or saved-location update | Indeterminate activity until terminal response | Queued cancellation only; running atomic work is not advertised as cancellable. |
| Commit, source cleanup, or rollback | `Finishing current item…`, `Cleaning up…`, or `Restoring source…`; no overall 100% claim | Complete the protected boundary; cancel remaining items afterward if requested. |

`topLevelDone / topLevelTotal` counts selected roots, not all descendants or
elapsed work. `entriesDone` includes completed directory/symlink processing and
does not mean those entries have been committed to the final destination.
`bytesDone` counts bytes written to staging, including work later discarded; it
is not committed output size or an assurance of durable storage.

Do not derive a folder percentage from the current file or selected-item count.
The backend scans the selected trees first and the primary progress indicator
uses the resulting aggregate byte total, falling back to entry totals for
empty and zero-byte trees.

## Protocol and operation lifecycle

### Additive operation metadata

Retain `operationChanged`, `operations.list`, existing field names, numeric
request IDs, `backendInstance`, `queueSequence`, and `eventSequence`. Keep
`state` as `queued` or `running` for compatibility; cancellation is additional
metadata, and the UI derives its displayed status from it.

Add these fields to both event and snapshot representations:

- `canCancel`: whether a new cancellation request is supported now.
- `cancelMode`: `queued`, `cooperative`, `betweenItems`, or `none`. A protected
  commit/cleanup may advertise `betweenItems` when later work can still stop.
- `cancellationRequested`: the backend has accepted a stop request. This is not
  proof that cancellation has completed or that a commit was prevented.
- `progress.currentFileActive`: current-file byte counters apply to the displayed
  path and phase. Reset it and stale file counters on directory, symlink,
  preparation, commit, cleanup, and rollback transitions.

Continue serializing byte counts as decimal strings. In QML, validate numeric
conversion, clamp display ratios, and handle missing data, zero-byte files,
changing source sizes, and values beyond exact JavaScript integer precision.
Rounded display calculations must never affect backend byte accounting.
Older snapshots without capability fields get progress rendering but no Cancel
button. Unknown phases receive a generic activity label.

### New `operations.cancel` method

Use a dedicated method rather than changing read/preview `cancel` semantics:

```json
{"id":102,"method":"operations.cancel","params":{"operationId":41,"backendInstance":"<instance from snapshot>"}}
```

Validate the target as an integer operation ID and require the current backend
instance. Reject malformed parameters, stale instances, and unsupported running
operations with stable error codes (`invalid_params`, `stale_backend_instance`,
`not_cancellable`). An unknown/already-finished target can return `ok: true`,
`accepted: false`, `reason: "not_active"`; this handles completion races without
claiming cancellation. An accepted request returns:

```json
{"id":102,"ok":true,"operationId":41,"accepted":true}
```

Process this method on the protocol event thread, outside the mutation FIFO and
its admission limits, so a busy/full queue can still be cancelled. Acknowledge
acceptance independently of worker cleanup. Repeated requests for an active job
with its token already set are idempotent. After terminal completion, return
`not_active`; persistent operation history is unnecessary.

The original mutation receives exactly one terminal response. A clean stop is
an unsuccessful operation with a machine-readable cancellation code:

```json
{"id":41,"ok":false,"errorCode":"cancelled","error":"Operation cancelled","completed":["/destination/already-copied.txt"]}
```

Preserve success `paths` and existing failure `completed`/`partial` shapes and
meanings. Add structured `recovery` records for cleanup/rollback failures, with
logical source/destination, retained staging path, failure kind, and error text.
Use a distinct error such as `recovery_failed` plus `cancellationRequested: true`
when a stop exposes a recovery failure. Keep the existing
`destinationCommittedSourceRemovalFailed` partial state for committed moves.
Never misclassify an I/O error as cancellation just because the token was set.

### Backend lifecycle implementation

1. Give each `MutationJob` its own cancellation control, separate from
   `m_cancellationTokens` used by reads/previews. Capture it in worker dispatch.
2. For queued cancellation, remove the ID from the FIFO and registry, send the
   cancel acknowledgement and original cancelled response, and release its job
   count exactly once. Never dispatch the operation or disturb the running job.
3. For supported running work, set the atomic token and emit an updated snapshot.
   Preserve the job and all ownership until worker cleanup and its terminal result.
4. Centralize mutation finalization so normal completion, cancellation, errors,
   and exceptions cannot double-send responses, leak counts, or skip the next job.
   Ensure input EOF still drains accepted work and exits when accounting reaches zero.
5. Deliver all registry changes/protocol writes on the backend event thread.
   Progress after a cancel request must preserve cancellation metadata. Discard
   stale callbacks after terminal completion, including when an ID is reused;
   identify a callback by job generation/queue sequence as well as request ID.
6. Keep read/preview cancellation behavior unchanged. Keep active mutations
   registered during cancellation, rollback and cleanup so volume removal still
   rejects conflicting operations until they really finish.

## Safe cancellation inside filesystem operations

### Cooperative checkpoints

Pass the token through `transferPaths`, `copyOne`, `moveOne`, and `copyEntry`,
including recursive calls. Use an internal typed result distinguishing success,
cancellation and failure instead of detecting cancellation by matching strings.

Check before starting an item, entering a directory, creating an entry, reading
each chunk, retrying partial writes, performing metadata work, and entering the
commit boundary. Count actual successful writes, including partial writes.
Propagate cancellation promptly back to the owner of the staging root; recursive
children must not independently remove shared staging trees.

Cancellation is cooperative. A blocked filesystem call, flush, ACL operation,
Trash call, or cleanup may delay it. Do not kill the worker thread or backend to
implement Abort. On responsive storage, the target is to observe a stop at the
next chunk/traversal checkpoint; do not promise a hard deadline on stalled I/O.

### Copy staging

Before destination commit, cancellation closes owned descriptors and removes
only the temporary destination tree created by this operation. The source and
previously completed destinations remain untouched. Keep the existing staging
ownership and no-follow protections; never remove a colliding final destination.

The final token check before the no-replace rename is the cancellation boundary.
If that check observes cancellation, clean up. If the commit wins the race,
record the item as completed and stop before the next item. Do not roll back
already committed user-visible output. If it was the final item and all work
completed, a normal success response is valid despite a late cancel click.

Cleanup runs to completion without being interrupted by the same cancel token.
Report a cleanup phase while it runs. If cleanup fails, return its retained
staging path in `recovery`, not an apparently clean cancellation.

### Cross-device move staging

The existing implementation first renames the source into a private sibling,
copies it to destination staging, commits the destination, then removes the
staged source. Preserve this protection against removing a replacement source.

- Before destination commit: remove unfinished destination staging and restore
  the source staging entry to its original name with no-replace rename.
- A recreated original source name must never be overwritten. Leave the pinned
  source at its recovery path and return structured recovery details.
- Use scope-owned recovery around every path after the initial source staging
  rename, including source inspection failures and exceptions. The current
  post-rename inspection path can return before attempting restoration; the new
  cancellation implementation must cover it as well.
- After destination commit: finish the existing identity-checked source cleanup
  for that item before honoring cancellation of remaining items. Interrupting
  recursive source removal could leave an ambiguous partially removed source.
- Preserve the committed destination on cleanup failure and return the existing
  partial result plus any retained source staging location. Never report the move
  as fully completed in that case.

Rollback and post-commit source cleanup are protected phases. Their progress can
be indeterminate; keep the row visible until recovery is finished. Internal
staging cleanup remains part of transfer implementation, not a permanent-delete
feature or deletion of arbitrary user paths.

### Other mutations

Extend `trashPaths` with token and progress parameters, checking between paths
and publishing completed counts after each successful `moveToTrash`. Completed
items stay in Trash after cancellation; restoring them is separate product work.
Single running atomic mutations retain their current APIs and finish normally.
All still support removal from the queue before dispatch.

## Progress delivery and QML integration

The current 200 ms throttle applies to byte updates, but file starts, entry
completion, and other forced reports bypass it. A folder with many tiny files
can therefore flood the event loop despite small byte volume.

- Coalesce worker progress before posting to the protocol thread: retain the
  latest snapshot with at most one pending delivery per job, targeting about
  five ordinary updates per second. Bound filesystem-to-QML work as well as
  stdout writes; an output-only throttle still permits queued-callback growth.
- Keep lifecycle/cancellation transitions prompt, suppress redundant per-entry
  forced updates, and prevent pending timers/callbacks from emitting after a
  terminal response. Counters accumulate even when intermediate events are skipped.
- Maintain logical source paths during staging; never display `/proc/self/fd`
  traversal paths or temporary names as the active filename. Recovery paths are
  an intentional exception in explicit error details.
- Add `BackendClient.cancelOperation(id, backendInstance, ...)`, with per-operation
  pending-cancel state. Do not call `forget()`, remove the row, decrement the
  mutation lease, or delete the original callback on a cancel click/acknowledgement.
- If cancellation acknowledgement times out, refresh `operations.list` and keep
  the original mutation tracked. Clear local cancellation state on terminal
  completion/backend exit; do not replay a cancellation against a new instance.
- Preserve snapshot/event ordering and ensure terminal handling removes a tracked
  operation even when its initiating callback is absent. Closing the initiating
  BrowserSession must not implicitly cancel mutations or lose shared queue state.
- Update `BrowserSession` cancellation notices without losing completed/partial
  accounting. Adjust selection/clipboard only for affected original items, keep
  unprocessed items available, and retain the existing clipboard revision guard.
  Refresh affected listings after staging restoration or recovery failure even
  when `completed` and `partial` are empty.
- Route terminal activity notices/recovery records through shared operation state
  so a surviving window can report a cancellation requested there after the
  initiating window closes. Retain recovery details until dismissed; these records
  must not retain a backend operation lease or appear as running work.
- Extract a small `OperationProgress.qml` presentation component if needed and
  register it in `qml/components/qmldir`. Prefer existing `Format`/`Theme` helpers.
  Keep timers and connections as explicit properties when owned by `QtObject`.

## Whole-folder percentage

The implementation includes a cancellable backend `Scanning…` phase that totals
regular-file bytes without following symlinks. It runs on the mutation worker,
preserves traversal safety, and reports activity during scanning. QML never scans
the filesystem.

Define how changed sources invalidate totals: a live filesystem is not a frozen
snapshot. Mark totals as estimates or return to indeterminate progress when they
become unreliable; do not freeze at 100% while copying added content. Filesystem
renames and empty/zero-byte trees need item/phase fallback rather than division by
zero. Scanning doubles traversal costs on many trees and may be expensive on
removable or network-backed local mounts. ETA and transfer speed can follow once
byte/phase semantics are stable; pause/resume, conflict resolution, persistent
queues and crash recovery are separate features.

## Implementation sequence and completion gates

1. **Expose progress already available.** Update Activity rows and formatting,
   current-file counter reset semantics, and progress coalescing. Done when one
   large file and one recursive tree show honest, responsive progress without
   changing normal operation outcomes. This can ship independently.
2. **Add cancellation protocol and queue ownership.** Implement per-job controls,
   `operations.cancel`, capability snapshots, and finalization. First enable queued
   cancellation. Done when cancelled queued jobs never touch disk and all job
   counts/leases and subsequent FIFO dispatch remain correct.
3. **Implement safe running cancellation.** Add transfer checkpoints, staging
   recovery, protected commit/cleanup phases, Trash boundaries and structured
   outcomes. Enable running cancellation capabilities only when these paths pass
   their tests. Cross-device recovery is the highest-risk part of the work.
4. **Connect controls and result UX.** Add Cancel buttons, shared pending state,
   normal cancellation notices, persistent recovery details and session refresh/
   clipboard handling. Done when any window can cancel and observe an operation
   without losing its result or ending the backend prematurely.
5. **Verify and document.** Complete the matrix below and update
   `docs/architecture.md` to replace its current “future extension” description
   with the implemented protocol and cancellation boundaries.

## Verification plan

Use temporary fixture directories and an interactive protocol driver that sends
cancellation after an observed progress event. Reuse the existing
`FILESAIL_DEV_TRANSFER_DELAY_MS` development hook for reproducible mid-copy tests.
Use bounded, test-only synchronization/fault injection for exact commit, rollback,
partial-write and cleanup boundaries; avoid timing-only sleeps. Register any new
test executable/driver in `CMakeLists.txt` and keep the existing smoke suite.

| Area | Required cases and assertions |
| --- | --- |
| Protocol | Partial JSON framing, multiple interleaved requests, malformed/stale IDs, full-queue cancellation, duplicate cancellation, already-finished targets, preview cancellation unchanged; one original terminal response and no later progress. |
| Queue | Cancel middle/head/tail queued jobs; unaffected jobs preserve FIFO; repeated enqueue/cancel does not leak capacity; EOF and normal idle shutdown remain correct. |
| Large file/tree | Cancel midway through one large file and inside a single recursive folder; no final incomplete destination, source unchanged, owned staging removed, previous completed roots preserved. |
| Filesystem boundaries | Empty files/directories, symlinks including dangling links, many tiny files, deep trees, metadata/ACL preservation, partial writes, short writes, unreadable source, disk-full destination and hot unplug. Errors remain errors. |
| Safety regressions | Empty/relative/non-local paths, filesystem root protection, self/descendant transfers, collisions, source replacement, unsupported entries and no-follow protections remain intact. |
| Moves | Same-filesystem cancellation between items; cross-device cancellation after source staging and mid-copy; source-name collision during rollback; final commit race; cancellation during source cleanup; destination committed but cleanup fails. |
| Recovery | Inject staging removal/rollback failures; surviving source or destination is identifiable; structured recovery paths are correct; no unrelated entry is removed or overwritten; cleanup is not cancelled recursively. |
| Other mutations | Trash stops between items and leaves completed items in Trash; all queued mutation types are cancellable; running atomic methods report unsupported cancellation accurately. |
| Progress/order | Aggregate byte counters are monotonic, current-file counters reset, current paths remain logical, missing/zero/large values render safely, tiny-file event delivery is bounded, stale snapshots/callbacks cannot resurrect completed jobs. |
| Lifecycle/UI | Cancel while collapsed/expanded; narrow sidebar, scrolling and keyboard access; Cancel never navigates; two windows, initiating-window closure, backend exit/restart, acknowledgement timeout and completion racing with cancellation. |
| Volume integration | Removal stays blocked during transfer cancellation/rollback/cleanup and becomes eligible only after terminal finalization. |

Cross-device tests must use distinct filesystem devices (for example a temporary
directory and available tmpfs), verify device IDs, and explicitly report skips
when that fixture is unavailable. Exercise this path in an environment where it
is available before considering running-move cancellation complete.

Run the repository checks after implementation:

```sh
cmake --build build
ctest --test-dir build --output-on-failure
qmllint -I /usr/lib/qt6/qml -I qml qml/core/*.qml qml/components/*.qml shell.qml
qmllint -I /usr/lib/qt6/qml -I qml integrations/noctalia/*.qml
```

For QML changes, run a bounded standalone launch to `Configuration Loaded`, then
manually inspect a deliberately slowed file/folder transfer and cancellation.
This briefly creates a Wayland window; terminate only the test instance and
verify that no test Quickshell/backend processes remain. Repeat through the
Noctalia standalone launcher and verify theme scaling and square corners.

The feature is complete when every queue entry has an accurate status, long
transfers visibly advance, queued jobs cancel without side effects, supported
running jobs stop at documented safe boundaries, and users can distinguish clean
cancellation, completed work, and filesystem recovery that still needs attention.
