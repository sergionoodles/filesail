# FileSail control CLI

`filesail-cli` is a stateless client for the `filesail.control.v1` Quickshell
IPC endpoint. It emits exactly one compact JSON document on stdout, writes
diagnostics to stderr, and exits nonzero when `ok` is false.

## Targeting and lifecycle

Use `windows list` to discover opaque window IDs. A command without `--window`
is accepted only when exactly one window is eligible; otherwise it returns
`no_window` or `ambiguous_target`. `--host` accepts an exact or unique-prefix
Quickshell instance ID or host-generation token, and also accepts a host kind
when that selects one host.

Inspection commands never launch FileSail. `windows ensure` returns the sole
window, creates one when none exists, and rejects ambiguity. `windows create`
always requests a new standalone window. An untargeted `navigate` creates a
window at the requested location when none exists. Startup goes through the
normal per-user launcher lock and its atomic ensure operation.

Window IDs contain 128 random bits encoded as 22 base64url characters. They are
valid only while the view exists. Host generations and retained request results
are invalidated by a host restart.

## Commands

```text
windows list
windows ensure [--location LOCATION]
windows create [--location LOCATION]
state
capabilities
entries [--limit 1..500] [--cursor REVISION:OFFSET]
navigate --location LOCATION
back | forward | up | refresh
select --path PATH [--path PATH...] [--mode replace|add|remove] [--primary PATH]
clear-selection
preview show | preview hide
filter --value TEXT
hidden show | hidden hide
view-mode list | view-mode grid
sort --field name|size|modified [--descending] [--folders-first true|false]
events [--since SEQUENCE] [--limit 1..256]
result REQUEST_ID
```

Global options are `--window`, `--host`, `--request-id`,
`--expected-revision`, `--timeout` (milliseconds), and `--no-wait`. Named
locations are `home`, `desktop`, `documents`, `downloads`, `music`, `pictures`,
`videos`, `templates`, `publicshare`, and `trash`; absolute local directory
paths are also accepted. Resolution and existence validation happen in the
backend.

## Results and events

Accepted commands retain either a `pending`, `succeeded`, or `failed` record in
the host. The CLI waits by polling that record with a bounded deadline, so a
notification race cannot hang it. A timeout means the request may still finish;
query the returned `requestId`. Reusing a retained ID with identical input is a
deduplicated lookup; using it with different input returns
`request_id_conflict`.

State contains committed and pending paths, loading/error state, selection,
modal state, revision, visibility/focus knowledge, view preferences, and
separate requested/actual/provider preview state. Entry cursors include the
directory snapshot revision and stale cursors fail instead of mixing pages.
Events contain a host generation and increasing sequence. `event_gap` means the
bounded history expired and the caller must take a fresh state snapshot.

Navigation and selection belong to one window. The filter is window-local.
Sort, hidden-file display, preview visibility, and view mode retain their
existing host-shared persisted scope. A state-changing agent command is
serialized per window, while inspection remains available. Conflicting user
navigation or selection supersedes pending agent work. Modal confirmations are
never clicked automatically and return `requires_user_input`.

Common errors include `window_not_found`, `no_window`, `ambiguous_target`,
`stale_state`, `busy`, `invalid_path`, `item_not_visible`,
`preview_unavailable`, `requires_user_input`, `superseded`, `timeout`, and
`host_disconnected`.

## Transport validation

The wrapper was validated against Quickshell 0.3.1 with exact instance routing,
multiple fresh CLI processes, two live windows, delayed navigation results,
event listening and catch-up, host termination, and concurrent cold-start
ensures. On the development machine, 20 complete `state` invocations averaged
about 75 ms each (including process startup, instance discovery, and two IPC
calls); a committed local navigation took about 154 ms end to end. That is
adequate for semantic agent control, so v1 retains Quickshell IPC rather than
adding a resident socket service.
