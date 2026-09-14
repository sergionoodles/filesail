# Desktop file clipboard: implementation plan

Status: detailed implementation draft, revised 2026-09-14 against the current
checkout. Context menus already exist. This document proposes clipboard work;
it does not claim that the bridge or its tests have been implemented.

Audience: a coding agent implementing one bounded task at a time. Follow the
task cards below in order. Each card identifies inputs, concrete changes, and
an exit check. Do not infer completion from the presence of a filename or a
passing mock test. Keep a progress checklist and record outstanding desktop
verification separately.

## Goal and scope

Make Ctrl+C / Ctrl+X in one FileSail window followed by Ctrl+V in another
behave as expected, including separate FileSail processes and transfers to/from
Nautilus. Copy remains available for repeated pastes; Cut moves files only when
Paste runs. Navigation and selection remain window-local.

Integrate with the implemented context menu. Include existing
shortcuts, toolbar/menu actions, clipboard status, packaging, and tests. New
context-menu targets, Copy Path(s), drag-and-drop, remote files, conflict dialogs,
and a general clipboard history manager are outside this change.

`docs/context-menu-plan.md` is an older design document, not an accurate inventory
of current code: its statements that the list/grid have no menus are stale.
For this task, use the existing components and the baseline below. Do not
reimplement the context-menu system or attempt every feature in that document.

### Implemented context-menu baseline

| File | Current behavior | Required clipboard change |
| --- | --- | --- |
| `qml/components/FileListView.qml` | Right-click and keyboard menu requests; right-click preserves an existing multi-selection. | Preserve gesture behavior; regression-test Copy/Cut from an item menu. |
| `qml/components/FileGridView.qml` | Right-button handler and keyboard menu requests. | Same as list; do not replace the selection/marquee implementation. |
| `qml/components/FileBrowserPane.qml` | Background right-click clears selection; forwards list/grid menu signals. | Correctly classify keyboard requests with a null entry as background if needed. Both loader handlers currently pass `false` unconditionally. |
| `qml/components/FileSailView.qml` | Selects a right-clicked item if needed, maps coordinates, opens the existing menu. | Continue using this single menu instance; supply only the clipboard context data needed below. |
| `qml/components/ContextMenu.qml` | Item Copy/Cut, background Paste, and other existing actions; records `targetDirectory`; closes on committed path change. | Reuse commands, capture file-action context, update enabled state, and pass the captured background destination to Paste. |
| `qml/components/BrowserActions.qml` | Central actions; Ctrl+C/X/V still use the local buffer. | Switch to shared clipboard readiness and safe shortcut scope. Keep action property names compatible. |

The existing menu does not offer Paste Into Folder on a selected folder. Keep
that product behavior unchanged in this task. Its `targetDirectory` also serves
Terminal and New Window; do not repurpose it globally or change those actions.
The item menu already says Cut, whereas `moveAction.text` says Move; normalize
the shared label to Cut and reuse it in the menu.

## Findings and architecture decision

`BrowserSession.qml` currently owns `clipboardPaths`, mode, and revision.
`copySelection()` only changes those properties. `BrowserActions.qml` enables
Paste from that session's buffer. Every `FileSailView` creates a separate session,
even though normal standalone windows share a QML engine and backend.

The installed Quickshell QML metadata exposes `clipboardText`, with no public
general MIME clipboard API found. Its [documented API](https://quickshell.org/docs/v0.3.0/types/Quickshell/Quickshell/)
also notes Wayland focus restrictions on reading clipboard text. Plain text is
insufficient for file-transfer interoperability. An ordinary unfocused helper
using QClipboard must not be assumed to solve the Wayland connection/focus issue.

Proposed implementation: a dedicated, long-lived `filesail-clipboard` helper
under `src/clipboard`, using Qt Core for lifecycle/JSON and a Wayland data-control
adapter for clipboard transport. Prefer `ext-data-control-v1`, with a
`zwlr_data_control_manager_v1` fallback where available. Negotiate capabilities;
do not branch on compositor names. Keep native code outside Quickshell and keep
the filesystem backend a Qt Core service independent of display availability.

The [ext-data-control protocol](https://raw.githubusercontent.com/wayland-mirror/wayland-protocols/main/staging/ext-data-control/ext-data-control-v1.xml)
provides selection observation/ownership and MIME offers. Its availability and
permission must be proven on the supported Niri and Hyprland configurations
before committing to this transport. This is the first implementation gate.
Do not use hidden focus-stealing windows or silently fall back to text paths.
If data control is unavailable, expose a clear capability error; support for
other clipboard transports is a separate adapter decision.

Add `qml/core/FileClipboard.qml` as a singleton that owns the helper connection
and exposes a normalized current snapshot. The desktop selection is authoritative;
the singleton is a cache/coordinator, not a second independent clipboard.
Separate FileSail hosts communicate through the desktop selection naturally.
Shared UI imports only the core service, never Wayland/compositor APIs.

## Implementation sequence

### 1. Prove transport and interoperability

- Build a minimal helper that advertises multiple MIME types in one selection,
  receives offers, serves/reads payloads asynchronously, and releases ownership.
  Probe both protocol variants and report the selected capability.
- Exercise it with FileSail focused, Nautilus focused, and after changing focus
  between windows. Confirm there is no helper window and no focus change.
- Verify seat selection on the target desktops. Start with one explicitly
  resolved seat; report ambiguity rather than silently reading another seat.
- Capture offered formats from the installed Nautilus and record application,
  compositor, Quickshell, and protocol versions in the test notes.
- Prove multi-MIME publication/receipt on an available target compositor before
  integrating the UI. Keep tests for the other compositor pending if unavailable;
  codec, protocol, coordinator, and UI work can proceed. Release acceptance
  still requires bidirectional multi-file Copy/Cut on Niri and Hyprland.

### 2. Define codec and helper protocol

Publish all supported representations from one immutable payload:

| MIME representation | Meaning |
| --- | --- |
| `text/uri-list` | Encoded local file URIs; default to Copy when no recognized operation metadata exists. |
| `x-special/gnome-copied-files` | `copy` or `cut`, followed by newline-separated file URIs. |

The latter matches [Nautilus's clipboard implementation](https://raw.githubusercontent.com/GNOME/nautilus/main/src/nautilus-clipboard.c).
Generate URI lists with the appropriate line endings and native URL encoding;
do not construct shell commands. Consider KDE cut metadata only after verifying
its current format and testing a consumer; it is not required for the first
Nautilus acceptance gate.

Decode MIME data, never arbitrary clipboard text. Preserve spaces, Unicode,
literal percent signs, hashes, and encoded line breaks. Validate strict URI
syntax, decode exactly once, accept only absolute local file paths, and define
localhost handling consistently with FileSail's existing URI resolver. Reject
remote authorities, non-file schemes, NULs, malformed escapes, and mixed
supported/unsupported lists as a whole with a useful reason. Preserve symlink
paths rather than resolving them during clipboard import. Reject unrepresentable
filenames explicitly instead of lossy conversion.

Specify precedence: recognized GNOME metadata supplies mode and paths; URI-only
offers mean Copy. Reject malformed recognized metadata or conflicting advertised
file lists instead of silently turning Cut into Copy. De-duplicate identical
paths while retaining order. Filesystem existence and destination safety remain
authoritative backend checks at execution time.

Use a versioned NDJSON protocol with request IDs and unsolicited change events:

- `capabilities`: availability, transport, seat, limits, and error reason.
- `snapshot`: readiness, offer token, mode, paths, supported status/reason.
- `writeFiles`: validated paths/mode; respond after publication is submitted,
  handling immediate cancellation without claiming durable ownership.
- `replaceIfCurrent`: expected offer token and replacement file payload or clear;
  permitted only for a selection currently owned by this helper.
- `changed`: new generation and capability/readiness state.

Use a helper-instance nonce plus monotonically increasing offer generation.
Invalidate pending reads when the offer changes, even if its bytes are identical.
Bound protocol frames, MIME bytes, item counts, individual paths, and read/write
durations; select documented limits compatible with backend request limits.
Handle partial frames, multiple requests, slow/disappearing owners, broken pipes,
and compositor disconnects without blocking the event loop. Do not log clipboard
contents or persist arbitrary external clipboard data.

### 3. Wire shared state and actions

- Register `FileClipboard` in `qml/core/qmldir`. Give it explicit object properties
  for processes/connections/timers, plus bounded restart/backoff behavior.
- Replace session-owned buffers with read-only service bindings. Copy/Cut capture
  the selected paths immediately and publish through the service; show success
  only after the helper responds successfully. Rename the existing Move action
  to Cut while retaining Ctrl+X.
- Paste snapshots the current offer and the successfully loaded destination at
  activation. Revalidate the offer after asynchronous reads; reject a stale
  snapshot instead of pasting a previous selection. Subsequent navigation must
  not change the submitted destination.
- Expose unavailable, reading, empty, unsupported, and ready states. Update
  shortcut, toolbar, context menu, and status bar consistently. Clipboard changes
  in text fields or another application must invalidate previous file content.
- Audit shortcut focus: address/search/filter/dialog text editing keeps normal
  text Copy/Cut/Paste; file actions apply only in the browser context. Ensure one
  keypress triggers only the focused window's action.
- Keep clipboard publication and MIME I/O asynchronous. Existing backend copy
  and move requests remain responsible for filesystem work and validation.

### 4. Handle completion, cancellation, and races centrally

Track each submitted paste by backend-instance ID, operation ID, immutable
source list, destination, mode, and clipboard offer token. Finalization belongs
to the shared coordinator, observing `BackendClient.mutationTerminated`; it must
run exactly once even if the initiating view is destroyed. Session callbacks
continue to handle local selection and notices, not global clipboard mutation.

- Copy leaves its clipboard payload intact, including after partial failure or
  cancellation, so repeating a Copy remains possible.
- Cut removes only sources confirmed fully moved. Keep untouched/failed sources.
  Interpret the backend's ordered `completed` destination list against the
  captured source list; do not confuse destinations with original source paths.
- A `partial` destination committed with source cleanup failure is not a completed
  move. Preserve the source/recovery information and prevent blind automatic
  retry of that conflicted item. Show the existing recovery details; do not
  discard it using the current `completed + partial` slicing logic.
- Reconcile clipboard content only if the original offer is still current.
  A newer Copy/Cut or external text selection must survive operation completion.
  Apply the same condition when pruning paths after volume removal.
- Process volume invalidation once in the singleton, not once per BrowserSession.
  Do not alter unrelated external clipboard payloads.
- Suppress repeated in-flight pastes of the same Cut generation within one host.
  Across independent applications, rely on backend path/collision validation;
  do not promise a distributed move lock.

Data-control has no general atomic compare-and-swap for desktop selections.
The helper should process pending selection events before a conditional
replacement and abort on observed ownership changes. Document and test the
remaining cross-client race rather than claiming tokens make it atomic.
Concrete policy: never rewrite an external offer automatically, including an
offer owned by another FileSail process. Record consumed/blocked entries locally
against that offer token. Only a still-owned offer may be conditionally rewritten.
External applications do not provide a universal transfer-completion acknowledgment.

### 5. Define lifecycle, package, and document

The helper stays alive when the source window closes while another FileSail
window, operation, or bounded clipboard-finalization request remains. Update
the host's idle/quit guard so it cannot exit between a mutation result and the
clipboard reconciliation response. On last-window exit, normal clipboard persistence
depends on a desktop clipboard manager; do not promise persistence without one
or introduce an immortal clipboard daemon as an incidental change. Test closing
the initiating window during Copy and Cut and shutting down after completion.

On helper restart, invalidate old tokens and read the current desktop selection;
never restore cached paths over a newer selection. A missing helper or denied
protocol produces a clipboard-specific unavailable state without preventing
directory browsing or unrelated backend operations.

Update CMake build/install rules, development and installed helper discovery,
AppImage bundling and dependency checks, and packaging documentation. Include
Wayland client/scanner and protocol XML dependencies with appropriate licenses
and reproducible generation. Do not load a native QML extension into Quickshell.
Update `docs/architecture.md`, README behavior/limitations, and link the clipboard
section of `docs/context-menu-plan.md` to this implementation plan.

## Verification and completion criteria

| Layer | Required checks |
| --- | --- |
| Codec/protocol | Round trips for unusual names; malformed/nonlocal/mixed URI rejection; mode precedence; size limits; partial framing; multiple requests; stale generations; interrupted MIME reads/writes. |
| Coordinator | A copies and B pastes; repeated Copy; Cut consumed once; newer clipboard survives old completion; initiator closes; helper/backend restart; cancellation; completed vs partial/recovery; volume removal. |
| Filesystem | Existing empty/relative path, self/descendant, collision, symlink, cross-device, and cancellation protections continue passing. Clipboard input never bypasses them. |
| Desktop | FileSail A to B, separate hosts, FileSail to Nautilus and reverse, for Copy and Cut, on Niri and Hyprland; external text replacement; focus changes; text-field shortcuts; owner exit; clipboard manager present/absent. |
| Packaging/runtime | Installed and AppImage helper discovery; unavailable protocol behavior; bounded standalone launch reaches Configuration Loaded; no test processes left running. |

Run `cmake --build build`, `ctest --test-dir build --output-on-failure`, and the
shared/standalone and Noctalia qmllint commands in `AGENTS.md`. Use temporary
directories for transfer tests. Run clipboard integration tests in an isolated
desktop/seat where possible so they do not replace the user's working clipboard.
Record real desktop tests separately from mocks; unit tests cannot demonstrate
Wayland ownership or Nautilus interoperability.

Done means the original two-window Ctrl+C/Ctrl+V workflow and bidirectional
Nautilus Copy/Cut pass on both target desktops, lifecycle/race cases have explicit
tested behavior, and both installed and packaged builds contain the bridge.

## Detailed contracts: use these before writing integration code

These contracts refine the overview above. If implementation evidence requires a
change, update the relevant contract and tests together. Do not silently replace
MIME interoperability with an internal singleton or text clipboard fallback.

### File and ownership map

Proposed new files (split further only when a file becomes hard to understand):

| File | Responsibility |
| --- | --- |
| `src/clipboard/main.cpp` | QCoreApplication, `--serve` argument, process exit and signal policy. |
| `src/clipboard/clipboardserver.{h,cpp}` | Bounded NDJSON input/output, validation, request dispatch, response/event envelopes. |
| `src/clipboard/fileclipboardcodec.{h,cpp}` | Pure file-path/MIME encode/decode and limits; no Wayland, backend, or filesystem mutations. |
| `src/clipboard/clipboardtransport.h` | Small transport interface usable by real and test implementations. |
| `src/clipboard/waylandclipboard.{h,cpp}` | Registry/seat/protocol ownership, MIME offer/source lifecycle, nonblocking descriptor I/O. |
| `src/clipboard/protocols/` | Pinned protocol XML and provenance/license notes if system XML cannot provide the required fallback. |
| `qml/core/FileClipboard.qml` | Helper client, cached snapshot, local filtering, paste registration/finalization, helper lifetime. |
| `qml/core/ClipboardTransfer.js` | Pure result-accounting helpers, if needed to keep the singleton readable and directly testable. |
| `tests/clipboard-codec-test.cpp` | Native deterministic codec cases. |
| `tests/clipboard-protocol-test.cpp` | Server with injected fake transport; exercises real framing and dispatch. |
| `tests/clipboard/shell.qml` | QML integration harness with two sessions/views and injectable services. |
| `tests/clipboard-smoke.py` | Launch/drive/clean up the QML harness with bounded subprocesses. |
| `docs/clipboard-verification.md` | Reproducible desktop scenarios and actual results, versions, skips, and limitations. |

The helper may read clipboard bytes and validate paths; it never copies, moves,
deletes, opens, or stats an entire tree. All filesystem transfers still go
through `BackendClient.copyPaths` / `movePaths` and existing backend validation.
Do not add clipboard methods to `filesail-cli` or the agent control surface.

### Normalized data model

Use JSON-compatible immutable snapshots. Assign fresh objects/arrays in QML so
bindings update; do not mutate an array in place and hope observers notice.

```json
{
  "state": "ready",
  "token": "helper-nonce:17",
  "owned": false,
  "mode": "move",
  "paths": ["/tmp/source/a.txt", "/tmp/source/b.txt"],
  "reasonCode": "",
  "reason": ""
}
```

Internal mode is always `copy` or `move`; the MIME codec alone converts `move`
to/from the literal GNOME word `cut`. Do not introduce a third internal `cut`
mode that can accidentally become a backend method name.

`state` is one of `unavailable`, `reading`, `empty`, `unsupported`, `ready`.
Use `paths: []` and `mode: "copy"` for non-ready snapshots. A nonempty token
identifies the current observed selection epoch even when unsupported/empty;
unavailable has no valid token. Readiness never proves source existence or
destination writability. `owned` means owned by this helper, not merely that
the data looks like FileSail output.

Keep the raw current snapshot separate from these derived per-offer sets:

- `consumedPaths`: fully moved by this host from an external Cut offer.
- `blockedPaths`: partial/recovery/unknown-outcome or removed-volume paths.
- `inFlight`: Cut paste already submitted for this token.

For an external Cut offer, effective paths exclude consumed entries. If any
remaining entry is blocked, disable another paste of this offer and explain
that a fresh selection must be copied/cut after resolving the problem. Do not
silently omit a conflicted item and move the rest. An offer change clears the
offer-local sets; durable recovery information remains in Activity.

### Exact helper protocol shape

Requests: `{"version":1,"id":1,"method":"capabilities","params":{}}`.
IDs are positive integers; QML allocates monotonically for the process lifetime.
Do not reuse an outstanding ID. Each accepted request gets one terminal response.

Success: `{"version":1,"id":1,"ok":true,"result":{...}}`.
Failure: `{"version":1,"id":1,"ok":false,"errorCode":"...","error":"..."}`.
For a malformed envelope without a usable ID, use `id: null`; never guess an ID.
Events have no `id`: `{"version":1,"event":"changed","snapshot":{...}}`.

| Method | Params | Successful result |
| --- | --- | --- |
| `capabilities` | `{}` | `available`, `transport`, `seat`, `limits`, `reasonCode`, `reason`. |
| `snapshot` | Optional `expectedToken` string. | A normalized snapshot; mismatched expected token is `stale_offer`. |
| `writeFiles` | Nonempty `paths` array, `mode`. | Published snapshot with helper token; publication is not a durability guarantee. |
| `replaceIfCurrent` | `expectedToken`, `mode`, `paths` (empty means clear). | New snapshot, or `stale_offer` / `not_owner` without writing. |

For a newly advertised supported offer, emit `reading` immediately, request its
required MIME representations, then emit a terminal ready/unsupported state for
the same token. A snapshot request may return `reading`; the UI must not dispatch
files from a previous cached ready snapshot. At Paste, request `snapshot` with
the token shown as ready; reject stale/reading/non-ready results. Do not wait
indefinitely or automatically paste a newer selection when this check fails.

Start with these concrete limits, exposed by `capabilities` and tested at their
boundaries: 8 MiB NDJSON frame excluding newline; 4 MiB per MIME payload; 4,096
paths; 4,096 UTF-8 bytes per decoded path; 5-second MIME I/O deadline; 7-second
QML helper request deadline; 32 concurrent incoming requests; bounded outgoing
queue of 16 MiB. Reject excess with `limit_exceeded`; never truncate a transfer
list. Before sending a backend mutation, verify its serialized UTF-8 JSON frame
is at most the backend's existing 8 MiB limit. JSON escaping can expand input.

Errors: `invalid_request`, `unsupported_version`, `unknown_method`,
`limit_exceeded`, `invalid_uri`, `unsupported_uri`, `conflicting_formats`,
`unavailable`, `stale_offer`, `not_owner`, `io_timeout`, `io_error`.
Malformed individual requests must not crash the process. An overlong unfinished
line may close the protocol connection to bound memory; document this choice.
Stdout is protocol only, stderr is diagnostics without path/payload dumps.

### MIME parsing algorithm

1. Inspect offered MIME names without reading unrelated text/image contents.
2. If GNOME format is present, read it; if URI list is also present, read that
   too from the same offer. Otherwise read URI list alone. No supported format
   means unsupported, except a null selection which means empty.
3. Validate byte limits and UTF-8 before constructing QStrings. Reject invalid
   UTF-8; replacement characters must not silently change a filename.
4. GNOME: exact first line `copy` or `cut`, then one URI per nonempty line.
   Publish LF separators without a trailing blank record. URI list: publish
   CRLF-terminated records; accept LF/CRLF, comments beginning with `#`, and
   blank records as prescribed for a URI list. Do not apply comment handling
   to GNOME format. A recognized payload with no usable files is unsupported.
5. Parse each URI strictly with QUrl; reject bad percent escapes explicitly if
   QUrl repairs them. Reject user info, ports, query, fragment, non-file schemes,
   remote hosts, relative paths, NUL, and non-round-trippable local filenames.
   Empty host and case-insensitive `localhost` are local. Normalize localhost
   to the local form before `toLocalFile()` so it does not create a UNC-like path.
6. Do not trim path/URI lines, call `canonicalFilePath`, or resolve symlinks.
   Follow the backend's existing lexical normalization policy; document any
   difference from the optional FileManager1 resolver. Use that resolver as a
   reference, not a dependency on the optional D-Bus build.
7. De-duplicate exact validated paths in order. If both MIME forms exist,
   require their normalized ordered lists to agree. A failed required MIME
   read or malformed GNOME payload is not permission to downgrade to Copy.
8. Check the offer token again after reads; discard data from a superseded offer.

### Transfer accounting: existing backend response shapes

These are observed in `src/backend/fileoperations.cpp`, not proposed protocol
changes. Successful transfer response uses `paths`; failure uses `completed`.

```json
{"id":41,"ok":true,"paths":["/tmp/dest/a.txt","/tmp/dest/b.txt"]}
```

```json
{"id":42,"ok":false,"error":"...","completed":["/tmp/dest/a.txt"],
 "partial":[{"source":"/tmp/source/b.txt","destination":"/tmp/dest/b.txt",
             "state":"destinationCommittedSourceRemovalFailed"}]}
```

The transfer loop stops on the first failing top-level item. For a valid success,
all captured sources completed. For a failure, only the first `completed.length`
sources completed. Validate count bounds and expected destination correspondence
against the captured request; malformed accounting makes the outcome uncertain,
not successful. A `partial.source` is blocked, never counted as completed.
Any `recovery` record must retain its full backend data and block automatic retry
of the affected source; if mapping is uncertain, block the remaining offer.

| Result for Cut sources `[A,B,C]` | Local result | Still-owned desktop offer | External desktop offer |
| --- | --- | --- | --- |
| Full success | All consumed. | Conditional clear. | Leave desktop untouched; effective list empty. |
| Failure/cancel with no completion or recovery | Nothing consumed. | Retain all. | Retain all. |
| A complete, B ordinary failure/cancel, C untouched | Consume A; B/C remain. | Conditional replace with B/C. | Keep desktop; effective list B/C. |
| A complete, B partial/recovery, C untouched | Consume A; block B (or whole remainder if ambiguous). | May prune A, retain B/C, disable this resulting local offer. | Keep desktop; effective B/C blocked from Paste. |
| Backend disconnect/unknown result | No inferred completions; block retry. | No automatic clear/rewrite. | No rewrite. |
| Clipboard changed to newer token | Finish operation bookkeeping only. | No write to new selection. | No write to new selection. |

When a conditional rewrite produces a new token, carry the operation's blocked
state to that new token only if the helper response/event proves it is the
rewrite's result. An unrelated external event must never inherit old blocks.
Copy never prunes its payload on ordinary failure/cancellation; a recovery or
unknown outcome may block automatic retry locally without changing desktop data.

## Task cards for implementation

### T0 — Establish the baseline and a work log

Read `AGENTS.md`, `docs/architecture.md`, this document, and current versions of
all files in the context-menu baseline. Inspect `git status --short` before edits.
At drafting time, `qml/components/OperationQueue.qml` and
`src/backend/backendserver.cpp` already contain user changes. Preserve them;
do not restore, format wholesale, or overwrite them from an earlier snapshot.

Create the verification document with checklist entries T0–T10 and columns for
automated result, desktop result, and outstanding limitation. Record installed
versions and whether each target compositor is actually available. Read public
Quickshell metadata again before implementing; if a general MIME API has become
available, document evidence and assess it against the out-of-process constraint
before changing the transport decision.

Exit: baseline recorded, no unrelated edits, implementation order understood.

### T1 — Implement the pure codec first

Create the codec and native unit-test target. Use plain C++ structs for mode,
paths, and structured error; keep JSON envelope and Wayland objects out of it.
Implement both encode and decode using the algorithm above and enforce limits
on input and output. Define one shared header for codec/protocol limits.

Test exact MIME bytes, two-way round trips, localhost, symlinks as lexical paths,
duplicates, leading/trailing spaces, `%`, `#`, tabs/newlines, Unicode, invalid
UTF-8, malformed percent encodings, remote/mixed inputs, and disagreement between
formats. Include size-boundary cases and JSON expansion exceeding the mutation
frame limit. Test literal `%2F` in a filename is not decoded twice.

Exit: codec tests run without a Wayland session or Quickshell and pass. Neither
filesystem mutation code nor existing context-menu behavior has changed.

### T2 — Implement transport and prove the target protocol

Create the transport interface with signals/callbacks for capability changes,
selection epochs, MIME readiness, and source cancellation. The interface owns
asynchronous request handles and defines who closes each file descriptor.
Inject a fake transport for subsequent protocol tests; do not ship a fake-mode
environment switch in the production helper.

Implement registry discovery, version-capped bindings, one-seat selection, and
ext-first/wlr-fallback choice. Add optional `FILESAIL_CLIPBOARD_SEAT` matching
the advertised seat name; without it accept exactly one seat. No seat, missing
protocol, ambiguous seat, disconnect, or protocol `finished` must invalidate
readiness. Operate only on the regular clipboard; ignore primary selection.

Integrate the Wayland socket with Qt's event loop using nonblocking readiness
notifications. Correctly pair prepared reads with read/cancel, dispatch pending
events, flush writes, and handle EAGAIN; use a documented event-loop pattern,
not periodic blocking roundtrips. Initial discovery must also be bounded.
Generated protocol C may require enabling the C language in CMake; keep generated
files in the build tree. Pin/check XML sources and licenses.

Each published source advertises both formats before setting selection and
retains immutable bytes until cancelled/destroyed. Serve concurrent requests
with per-descriptor offsets, nonblocking writes and deadlines; handle EPIPE
without terminating the helper. Reads accumulate with limits, complete on EOF,
and close descriptors on completion, cancellation, timeout, and teardown.
Never read a clipboard-owned pipe synchronously in the UI or Qt event callback.

Run the available-compositor prototype in isolated test clipboard state. Verify
both MIME targets can be requested in either order and repeatedly, including
after focus changes. Capture Nautilus bytes and compare them with codec tests.
Record unavailable target testing honestly and continue independent tasks.

Exit: multi-format transport works on an available target, fake transport exists,
and all descriptor/source ownership paths have explicit cleanup.

### T3 — Add the helper server and framing tests

Implement the exact envelopes above in `clipboardserver`. Separate request
parsing from method execution. Use the codec for `writeFiles` and external reads.
Validate versions, IDs, method, parameter types, path arrays, mode, and limits.
Generate a random helper nonce at startup and never accept tokens from a previous
instance. Ownership changes advance generation even for identical payloads.

Serialize writes through the helper. Associate a local write/rewrite token with
its published source so the later selection notification does not accidentally
invalidate the write's own response. On cancellation report the latest observed
state. Never replay a write after reconnect, timeout, or stale result.

For `replaceIfCurrent`, check token and source ownership after dispatching pending
events; if either fails, return without altering selection. Limit the method to
local ownership even when external bytes happen to equal the old payload.
Return the rewrite's resulting token so the QML coordinator can correlate events.

Test fragmented/multiple lines, malformed input, invalid versions/types, duplicate
outstanding IDs, queue bounds, read timeout, transport loss, same-bytes-new-token,
write cancellation, stale rewrite, external-owner rewrite refusal, and stdout
purity. Keep protocol unit tests display-independent through injection.

Exit: helper builds; deterministic protocol tests pass; all accepted requests
finish or are explicitly failed when their connection terminates.

### T4 — Build the QML service and shared lifetime

Register the singleton and implement the public surface:

```text
snapshot, effectivePaths, mode, state, reason, canCopy, canPaste, pendingCount
acquireSession() / releaseSession()
writeFiles(paths, mode, success, failure)
readForPaste(expectedToken, success, failure)
trackPaste(operationKey, frozenContext)
finalizePaste(operationKey, result)
```

Use an injectable helper-client object or small test-only harness module for
tests. Use `Quickshell.Io.Process` with an argument array and an explicit property
inside the singleton. Parse JSON defensively and ignore stale responses from
previous process instances. Match each response to one pending callback, then
remove it. Never log serialized clipboard lines. Use existing logger conventions.

Acquire/release from BrowserSession lifecycle. Track bounded request/finalization
leases separately from clipboard ownership: owning clipboard bytes alone must
not keep FileSail running forever. Run while sessions, tracked transfers, or
bounded requests exist. Retry unexpected helper failure after 250 ms, 1 s, then
4 s; stop automatic retries after those attempts and expose unavailable. A new
explicit clipboard action can trigger one retry. Never replay the original write
or paste implicitly. On successful reconnect, read current state afresh.

`WindowRegistry.quitIfIdle()` currently checks only window count and backend
operation leases. Include FileClipboard's pending/transfer work and connect its
lease-change signal so the registry reevaluates after finalization. Once no
windows, backend operations, or bounded clipboard work remain, terminate the
helper and host; never wait indefinitely for a clipboard manager handoff.

Exit: two test sessions observe the same fake-helper snapshot; external change,
helper failure/restart, delayed response, and session destruction tests pass.

### T5 — Centralize transfer registration and finalization

Before changing actions, move clipboard completion logic out of
`BrowserSession.runOperation`. Remove its `clipboardRevisionAtStart`,
`usesClipboard`, success clearing, and failed-result clipboard slicing. Retain
local selection/refresh/notices. Preserve the function's existing positional
signature during migration (including the now-unused clear-clipboard argument)
or update every caller in the same task; do not shift boolean arguments silently.

Inspect `BackendClient.complete`: it emits `mutationTerminated` before invoking
the initiating callback and before releasing the operation lease. Register the
paste immediately when its backend request ID is allocated, before any terminal
response can be dispatched. If necessary, add an optional request-registration
hook to BackendClient; do not try to reconstruct context from the current UI.

Use a BackendClient connection-generation counter as part of operation identity,
incremented per backend process start, plus the request ID. Retain the native
backend instance ID when available; it may not yet be hydrated from
`operations.list` at request allocation. Do not use an empty native instance ID
as a globally unique key. Queue/register context against the local connection
generation before writing; do not attach old jobs to a restarted backend.

Capture `{sources, targetDirectory, mode, offerToken, owned, originWindowId}`
as values, with array copies. Track result finalization once through the service.
`backendStopped` must also finalize tracked operations as unknown outcomes:
`BackendClient.rejectAll` does not currently emit mutationTerminated for each
request. A progress event or disappearance from `operations.list` is never proof
of successful completion. Never automatically resubmit after restart.

Apply the accounting table above. Reserve a Cut token before asynchronous
snapshot validation so two rapid invocations cannot both submit. Release it on
stale/error or after final accounting; ordinary failures permit retry of the
remaining effective sources. Copy jobs need independent immutable snapshots and
do not share the Cut reservation. All callbacks owned by the coordinator must
survive an initiating BrowserSession being destroyed.

Connect the singleton to `VolumeModel.removalFinished` (success only) and
`mountPointsLost` for lost mounts. Remove only clipboard pruning from each
session's `finishMountRemoval`; preserve navigation/history and preview behavior.
Invalidation is idempotent if both volume signals describe the same loss.
Use `VolumeModel.isWithin`, not a bare string prefix. Never prune on removal
preparation that might later be cancelled. For foreign offers, block removed
paths locally; for owned offers, conditionally prune and carry necessary blocks.

Exit: tests cover every accounting-table row, duplicate terminal notifications,
initiator destruction, backend restart, and idempotent volume invalidation.

### T6 — Integrate existing actions, menu targets, and focus

Add `BrowserSession.copyPaths(paths, mode)` as the single command implementation.
`copySelection(mode)` calls it with a fresh ordered selected-path snapshot.
Provide `pasteTo(targetDirectory)`; keep `paste()` as a wrapper for the current
loaded directory. Both wrappers use the service and existing backend operations.
Keep `clipboardPaths`/`clipboardMode` as read-only aliases/bindings during the
status-bar migration; remove all remaining assignments to them.

Add a dedicated successful-load flag to DirectoryModel if needed. `path` starts
as HOME before the first load, and `revision` also changes on local sorting,
so neither proves successful loading. Set the flag only on accepted list success.
For this change, enable Paste only when a directory has loaded successfully,
is not loading/removal-paused, has no active error, and clipboard service is ready
with nonempty effective paths and no Cut reservation/block. Capture that path
when invoked. If loading/navigation/removal changes before backend submission,
fail the invocation without silently retargeting it. Navigation after submission
does not change the job's captured destination.

In `ContextMenu.openAt`, additionally capture:

```text
clipboardTargetPaths: copied selected-path array for item Copy/Cut
clipboardSelectionRevision: current session selection revision
clipboardDirectoryPath: current loaded directory
clipboardDirectoryRevision: current directory revision
```

Use clipboard-specific fields; retain existing `entry`, `backgroundContext`,
and `targetDirectory` for other menu actions. Item Copy/Cut execute through the
same session command with the captured paths. Validate the captured selection
and directory generation or close the menu when they change. A stale selection
must never silently substitute new paths. Clipboard changes alone keep the menu
open and update Paste availability; choose the clipboard snapshot at activation.
Background Paste calls `pasteTo(clipboardDirectoryPath)` and validates the saved
directory context. Do not add folder-item Paste or duplicate keyboard shortcuts
inside menu items. Closing/reopening the menu creates a fresh context.

Keep `copyAction`, `moveAction`, `pasteAction` property names so toolbar and key
help bindings continue working; set `moveAction.text` to Cut and reference it
from the menu. Keep mouse command enablement separate from shortcut eligibility.
For example, pass explicit browser/text-editing focus state from FileSailView
and suppress the Action shortcut binding while an editable field owns focus;
do not disable the command just because a popup temporarily owns focus. If
standalone Shortcut objects are necessary, clear corresponding Action shortcuts
and preserve displayed shortcut labels separately. Never register both.

Audit actual focus paths in location/filter fields, dialogs, list/grid, and the
menu. Scope file shortcuts to the focused host window. Do not infer editable
focus from C++ class-name strings. Verify toolbar/menu invocation still works
when the browser delegate no longer has active focus.

Fix the null-entry keyboard-background forwarding in FileBrowserPane if the
test reproduces it: pass `entry === null` (or equivalent nullish check) as the
background flag from both loaders. This is a bounded correction to expose the
existing background Paste action, not a context-menu rewrite.

Exit: real menu and shortcut harness tests pass for both views, multi-selection,
background/empty folder, clipboard change while open, and stale context.

### T7 — Finish status, errors, and refresh behavior

Update BrowserStatusBar and its FileSailView bindings to show effective shared
file count/mode. Remove misleading per-window Copy/Move buffer wording. Show
brief unavailable/unsupported/busy explanations through existing notice/tooltip
surfaces; avoid opening a modal merely because someone copies text elsewhere.
Copy/Cut publication failure must not show “Copied selection”.

For completed/partial transfers verify visible source and destination directories
refresh through existing watches. If an explicit fallback is needed, emit
affected-directory values from the coordinator and refresh only matching live
sessions; do not navigate them or clear unrelated selection. Closing the origin
must not prevent other windows seeing filesystem results.

Retain recovery records for both `recovery` and `partial` results. BackendClient
currently retains only `recovery` entries in `retainRecovery`; add an additive,
tested representation for partial source/destination details if Activity would
otherwise lose them after the initiating window closes. Inspect and preserve
the user's current OperationQueue changes. A partial source must remain visible
in recovery information even if its cut offer is later replaced.

Use existing Theme tokens, square surfaces, translations, and notice patterns.
Do not add a general clipboard inspector or history UI.

Exit: errors/readiness are understandable, recovery details survive source-window
closure, and affected directory views update without unrelated selection changes.

### T8 — Install and package the helper

Add the clipboard executable to normal CMake install targets, linking Qt Core
and Wayland client dependencies. Do not add Qt Gui to filesail-backend. Add
generated protocol compilation and configure-time dependency checks. A normal
supported Linux build includes the helper; optional protocol availability at
runtime is handled as a capability state.

Use `FILESAIL_CLIPBOARD` as an executable-path override, analogous to
`FILESAIL_BACKEND` (one executable path, not a shell command string).

- `scripts/run.sh`: default to `build/filesail-clipboard` and export the path.
- `packaging/filesail.in`: use configured bindir normally and
  `$APPDIR/usr/bin/filesail-clipboard` for AppImage; honor the override.
- `scripts/build-appimage.sh`: include the executable in dependency deployment
  and verify required Wayland libraries are bundled/resolvable.
- `tests/launcher-smoke.sh`: extend fixtures/assertions for the helper path and
  preserve existing single-host activation behavior.

A missing clipboard helper must produce a clipboard-specific failure after
launch, not prevent browsing; distinguish a broken installation from a missing
runtime compositor protocol in diagnostics. Follow existing quoting rules for
configured paths. Test a prefix containing spaces and explicit helper overrides.

Exit: build-tree, temporary install-prefix, and AppImage launches discover the
correct helper; an invalid override leaves browsing operational.

### T9 — Run deterministic and desktop acceptance tests

Run focused tests after each card, then the full repository-required checks after
integration. QML harness tests must execute the real service/session/menu code;
use fakes only at helper/backend boundaries. Use delayed responses to force
races deterministically. Run headless/offscreen harnesses where supported and
an actual bounded Wayland launch for runtime verification.

Each desktop scenario uses disposable source/destination directories and asserts
contents and source existence, not just toast text:

1. A selects two files, Ctrl+C; B Ctrl+V; both files appear and sources remain.
2. Repeat Copy into C without recopying; same files appear.
3. A item-menu Cut; B background-menu Paste; destination contents match, sources
   disappear, same host cannot paste the consumed Cut again.
4. Repeat 1 and 3 in list and grid, including existing multi-selection.
5. Repeat across `--new-instance` hosts; document external-offer consumption rules.
6. Nautilus to FileSail and FileSail to Nautilus, both Copy and Cut, multi-file and
   nested directory cases. Verify content and operation semantics in both apps.
7. Copy text elsewhere; FileSail Paste disables and does not reuse old file paths.
8. Copy files, open B's background menu, change clipboard externally; enablement
   follows the new offer and activation never uses the old cached payload.
9. Open item menu, change selection/directory; old command closes/rejects rather
   than copying a different selection. Empty-folder Menu/Shift+F10 exposes Paste.
10. Ctrl+C/X/V in location/filter/dialog text fields edits text without a file job;
    invoking toolbar/menu afterwards still works.
11. Slow a transfer using the existing development delay, close the origin window,
    then check correct completion and Cut accounting in the remaining window.
12. During that transfer copy a newer file/text payload; completing the old job
    does not overwrite the observed newer selection.
13. Cancel after one top-level completion; verify the accounting table. Exercise
    collision, partial cross-device cleanup failure, and recovery with controlled
    fixtures/fault injection, not arbitrary user directories or drive removal.
14. Kill only the test helper/backend; pending work gets an explicit uncertain
    result and no write/mutation is replayed. A fresh clipboard action can recover.
15. Close all windows during an operation; finalization completes within its
    deadline, then the owned test processes exit. Test last-window clipboard
    availability separately with a manager present/absent; record actual behavior.
16. Unsupported protocol/seat ambiguity/missing helper leaves browsing usable
    and clipboard actions give the correct reason.

Run scenarios on both target compositors and record pass/fail/not run individually.
Use a nested/isolated compositor or test seat when available. Never restore a
saved clipboard over a user's newer clipboard on test teardown. Terminate only
PIDs created by the harness, not every Quickshell process on the desktop.

Required final commands:

```sh
cmake --build build
ctest --test-dir build --output-on-failure
qmllint -I /usr/lib/qt6/qml -I qml qml/core/*.qml qml/components/*.qml shell.qml
qmllint -I /usr/lib/qt6/qml -I qml integrations/noctalia/*.qml
git diff --check
```

If new dependencies/targets require reconfiguration, run `cmake -S . -B build`
first, preserving existing intended configuration options. Record the bounded
standalone launch reaching `Configuration Loaded` and its clean termination.
Do not mark a skipped real-compositor test as passing because a mock passed.

### T10 — Reconcile documentation and review the final diff

Update `docs/architecture.md` with the helper boundary, shared service, and
clipboard-finalization lease. Update README with Copy/Cut interoperability and
actual supported transports/lifetime limits. Amend the stale current-state
section of `docs/context-menu-plan.md` to acknowledge implemented menus and link
here for clipboard work; do not mark unrelated Open With/restore features complete.

Review all remaining references to `clipboardPaths`, `clipboardMode`,
`clipboardRevision`, and `clearClipboardOnSuccess`. There must be no writable
session-local transfer buffer and no completion callback that changes clipboard
from live mutable selection. Review all `paste()` callers and every Ctrl+C/X/V
registration for consistent targeting and focused-window behavior.

Exit: final diff contains only scoped implementation, test, build, and documentation
changes; the verification document states what actually passed and what remains.
If a compositor is unavailable, deliver completed code with that exact remaining
verification limitation instead of claiming full release acceptance.
