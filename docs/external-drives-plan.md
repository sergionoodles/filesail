# External drives and removable media: implementation plan

Status: draft for review. This document proposes future work; it does not
implement runtime support.

## Objective

Give USB storage, SD/MMC cards, and removable data media first-class behavior in
FileSail:

- discover hot-plugged devices and reflect changes without restarting;
- show mounted, unmounted, locked, read-only, unsupported, and busy states in the
  sidebar;
- mount or unlock a volume on demand and navigate to it only after the directory
  loads successfully;
- unmount one filesystem or safely remove the complete physical drive;
- surface useful, stable errors for busy devices, authorization failures, missing
  filesystem support, disappearing hardware, and partial safe-removal attempts;
- coordinate with FileSail's own directory watches, previews, and file operations;
- preserve the existing architecture, path-validation rules, Trash-only deletion,
  preview-only second pane, and separate-window model.

The implementation is Linux-specific, as FileSail already is. It must behave the
same in the standalone host whether opened directly or through Noctalia. No
compositor-specific storage integration belongs in the shared UI.

## Product decisions and boundaries

Use UDisks2 on the system D-Bus as the single authority for discovery, mounting,
unmounting, unlocking, locking, ejecting, and powering off. Call its D-Bus API
directly through Qt DBus; do not parse `lsblk`, `/proc/mounts`, `udisksctl`, or
localized command output, and do not invoke `mount`, `umount`, or `eject` as root.
Qt DBus is already a backend dependency, so a direct implementation does not need
`libudisks2` at build time.

The complete baseline covers:

- USB thumb drives and externally attached disks;
- SD, SDHC, SDXC, MMC, and common USB card readers;
- drives containing one filesystem, multiple partitions, or no mountable
  filesystem;
- read-only filesystems and read-only media;
- LUKS-encrypted removable volumes, including unlock, mount, unmount, and lock as
  part of safe removal;
- mount points established or removed by another application;
- data-bearing optical media when UDisks2 exposes a filesystem, plus eject-only
  presentation for blank/audio media;
- a graceful unavailable state when UDisks2 is absent or stops.

Not included in this feature are formatting, partitioning, filesystem repair,
changing labels, changing encryption passphrases, automatic mounting on insertion,
remembered passphrases, network shares, phones/cameras using MTP or PTP, iSCSI,
RAID/LVM administration, or forcing a busy unmount. Those are distinct products
with different safety and interaction requirements. FileSail should reflect media
that another desktop component auto-mounted, but it should only initiate a mount,
unlock, unmount, or removal in response to a user action.

Never send UDisks2's `force` unmount option in this baseline. A failed normal
unmount leaves the device mounted and recoverable. Adding force later requires a
separate product decision and explicit data-loss warning.

### Required platform services

First-class actions require the host system's D-Bus, the UDisks2 daemon and
policies, and filesystem drivers/helpers for the formats being mounted. A desktop
polkit authentication agent is needed only when policy asks for credentials.
FileSail itself remains an unprivileged user process and must not install a custom
polkit rule that grants broader access. The backend should verify the UDisks
manager/API version at runtime and degrade cleanly when a compatible v2 service is
not available.

## Current implementation and gaps

- `PlacesModel.qml` contains static XDG locations and notes that volume entries are
  future work. Its current row contract assumes every item has a usable `path`, so
  it cannot represent an unmounted, locked, or failed volume.
- `Sidebar.qml` renders a single flat Places list with navigation as the only row
  action. It has no per-device progress, status, context actions, or accessible
  safe-removal control.
- `BackendClient.qml` already owns the long-lived newline-delimited JSON connection
  and asynchronous backend events. It can carry additive volume requests and
  snapshots without putting native D-Bus code in Quickshell.
- `filesail-backend` already links Qt DBus but currently uses it only indirectly in
  other features. It has no system-bus object manager or removable-device model.
- `BrowserSession` and `DirectoryModel` own navigation, watches, previews, and file
  operations. Several sessions can reference the same mount, so removal cannot be
  treated as an isolated sidebar button click.
- `NoticeBanner` is brief and single-line. Busy-device and partial-removal failures
  need a persistent, actionable error surface with optional technical details.
- Backend failures currently guarantee a human-readable top-level `error` string.
  Volume support needs additive structured codes while preserving that field for
  protocol compatibility.

## User experience contract

### Sidebar presentation

Add a `DEVICES` section below the built-in places in the Places page. Back it with
a dedicated `VolumeModel.qml`; do not mix stateful device rows into
`PlacesModel.qml` or make shared components import host APIs.

The backend snapshot is drive-centric and may contain several logical volumes.
The UI flattens it predictably:

- a drive with one user-visible volume gets one compact row;
- a drive with several volumes gets a drive heading followed by indented volume
  rows, so one physical eject action is not confused with one partition;
- inserted media with no mountable filesystem gets a disabled volume row with an
  explanatory status instead of silently disappearing;
- empty card readers are hidden until media is inserted, unless an actionable
  eject state exists;
- system/internal disks, ignored UDisks objects, loop devices, and devices on a
  different seat are hidden by default.

Volume labels use this fallback order: `Block.HintName`, `Block.IdLabel`,
partition name, drive vendor/model, preferred device basename, then a translated
generic name such as “External Drive” or “SD Card”. Duplicate visible labels gain
a stable disambiguator such as capacity or partition number. Treat every label and
system error as untrusted plain text.

Use UDisks media and bus hints to choose Lucide icons already available to the
shared UI: USB drive, memory card, optical disc, encrypted volume, or generic
drive. Do not depend on the host's private icon theme. All row surfaces and menus
continue using `Theme`, including the square-corner radius tokens.

Each volume row exposes label, optional capacity/free-space detail, and one of
these states:

| State | Primary row activation | Trailing status/action |
| --- | --- | --- |
| Mounted | Navigate to its selected mount point | Safely remove drive |
| Unmounted and mountable | Mount, then navigate | Mount affordance |
| Locked | Ask for passphrase, unlock, mount, then navigate | Lock indicator |
| Mounting/unlocking | No duplicate activation | Spinner and operation label |
| Read-only | Navigate or mount normally | Read-only indicator |
| Unsupported/unformatted | No navigation | Persistent reason/details |
| No media | No navigation | “No media” when the row is intentionally shown |
| Error | Retry the valid action | Error indicator and persistent details |

The icon-only trailing control must have an action-specific accessible name such
as “Safely remove Backup Drive”; its tooltip must not merely say “Eject”. A
context menu supplies the complete distinction:

- Open or Mount and Open;
- Unmount Volume, when only this filesystem should be detached;
- Unlock and Open for locked media;
- Safely Remove Drive for USB storage;
- Eject Media when the hardware reports ejectable removable media;
- Properties, using the eventual shared properties implementation.

The prominent inline removal action always targets the physical drive and all its
volumes. A partition-only unmount remains explicit in the context menu. This
avoids showing a device as safely removable while a sibling partition is still
mounted.

### Feedback and recovery

Mount/unlock navigation shows inline progress and disables only conflicting
actions. Safe removal changes the row status through “Preparing”, “Unmounting”,
“Locking”, and “Powering off” or “Ejecting”. Do not report success until the
relevant D-Bus method has returned and the observed object state agrees.

Success notices are precise:

- “Backup mounted” after mount, before or alongside navigation completion;
- “Backup unmounted” for a partition-only action;
- “Backup can now be safely removed” when unmounting is the strongest available
  operation;
- “Backup safely removed” after successful power-off/eject.

Errors use a persistent dialog or anchored panel with a short summary, suggested
recovery, `Retry` when still applicable, `Cancel`, and an expandable plain-text
Details field. Examples:

- busy: “The drive is in use. Close files and applications using it, then try
  again.” Preserve the mounted state and never imply it is safe to unplug;
- authorization dismissed: “Authentication was cancelled. The drive was not
  unmounted.”;
- unsupported filesystem: name the filesystem type when known and explain that a
  system driver/tool may be missing;
- device vanished: “The drive was disconnected before the operation finished.”;
- partial removal: list volumes already unmounted and the volume that remains
  busy. Do not automatically remount completed volumes.

Expose the sanitized UDisks message and remote error name under Details because
driver-specific mount failures often contain the only actionable diagnosis. The
friendly summary must derive from a stable internal error code, never by parsing
the localized message.

UDisks does not provide a portable list of processes holding a filesystem busy.
Do not guess an offender or add privileged `lsof`/`fuser` scraping to this feature.
The baseline gives accurate retry guidance and exposes the system detail; richer
process diagnostics can be designed separately if a safe, bounded source exists.

If a mounted drive disappears without a successful FileSail removal or an
observed external unmount, show one warning in each affected FileSail session and
move affected sessions to Home. Do not label a UDisks service restart itself as
unsafe physical removal.

## Device identity, discovery, and filtering

Create `src/backend/volumeservice.{h,cpp}`. It owns a system-bus connection to
`org.freedesktop.UDisks2`, obtains the initial graph with
`org.freedesktop.DBus.ObjectManager.GetManagedObjects`, and subscribes to:

- `InterfacesAdded` and `InterfacesRemoved`;
- `org.freedesktop.DBus.Properties.PropertiesChanged`;
- D-Bus owner changes for `org.freedesktop.UDisks2`;
- UDisks `Job` objects only to decorate operations that affect catalog objects.

Coalesce graph changes for roughly 50–100 ms because a newly inserted partition,
block interface, filesystem interface, and drive properties may arrive as separate
signals. Build an immutable, monotonically revisioned snapshot after each settled
change. A service owner change resets the object graph and operation associations,
then performs a fresh enumeration.

Validate D-Bus signatures and bound object counts, labels, mount-point counts, and
error text before serializing them. A malformed or unexpectedly large system reply
must produce a degraded/error snapshot rather than exhausting the backend or
breaking newline framing.

Model the relationships instead of treating `/dev/sdX` names as identity:

- `Drive` represents physical hardware and provides vendor/model, connection bus,
  removability, ejectability, power-off capability, media state, and `SiblingId`;
- `Block` provides the relationship to a drive, label/UUID/type, size, read-only
  state, and visibility hints;
- `Filesystem` provides the current mount-point byte strings and mount/unmount
  methods;
- `Encrypted` links the locked container to its cleartext block object;
- `Partition` supplies partition number/name where useful for presentation.

Issue opaque runtime `driveId` and `volumeId` values scoped to the current backend
instance. Keep UDisks object paths and device nodes private to the backend. A
replug may produce a new runtime ID even when a filesystem UUID repeats. Never use
UUID alone: cloned filesystems and multi-path devices can collide. Every action
resolves its opaque ID against the current graph, rechecks eligibility and
capabilities, and rejects stale IDs with `device_removed`.

An object is eligible for the sidebar only when it is not `Block.HintIgnore`, is
associated with a real drive, and belongs to the active seat. Classify it as
external/removable using the complete drive hints (`Removable`, `ConnectionBus`,
`MediaCompatibility`, `Ejectable`, and `CanPowerOff`) rather than one property.
Treat `HintSystem` as a protection boundary: if a block or any relevant encrypted/
cleartext ancestor is a system device, it remains hidden and cannot be acted on
through the volume protocol even if a crafted request supplies an ID. Add fixture
tests before freezing the exact classification policy, since USB enclosures and
built-in SD readers report different combinations.

Mount points arrive as byte arrays. Convert them with the platform filename
encoding, reject NUL or non-absolute results, normalize path separators, and only
expose JSON strings that can round-trip safely. A volume with an unrepresentable
mount path remains removable by opaque ID but is not navigable; report
`path_unrepresentable`. Use boundary-aware containment checks so `/run/media/a`
never matches `/run/media/ab`.

Use `Block.Size` as the cheap unmounted capacity hint. For mounted filesystems,
`QStorageInfo` may provide capacity and free space asynchronously; these values are
informational and may be unknown. Do not poll `Filesystem.Size`, which can cause
device I/O, merely to decorate a sidebar row.

## Backend and protocol design

`VolumeService` stays in the native helper and uses asynchronous D-Bus calls on
the backend event loop. Do not block the protocol thread or dispatch Qt D-Bus
objects to the filesystem worker pools. The existing backend process boundary
keeps this native and privileged integration outside Quickshell.

Add these protocol methods:

| Method | Parameters | Successful result |
| --- | --- | --- |
| `volumes.list` | none | availability, backend instance, revision, drive snapshot |
| `volumes.mount` | `volumeId` | resolved `mountPath`, volume state |
| `volumes.prepareRemoval` | target kind and ID, intended action | short-lived reservation ID, mount points, affected siblings |
| `volumes.unmount` | `volumeId`, `reservationId` | final volume state |
| `volumes.cancelRemoval` | `reservationId` | released reservation state |
| `volumes.unlock` | `volumeId`, `passphrase` | cleartext `volumeId` and mounted path when requested |
| `drives.safeRemove` | `driveId`, `reservationId` | performed final action and completed volume steps |

`volumes.unlock` should support an explicit `mount: true` flag so unlock/mount/open
is one backend-owned state machine. Do not add public methods that accept arbitrary
D-Bus object paths, `/dev` paths, mount options, filesystem types, or force flags.
Pass an empty options dictionary to normal UDisks methods so administrator policy,
`fstab`, filesystem allowlists, and caller UID/GID handling remain authoritative.
Omit `auth.no_user_interaction` for user-initiated actions, allowing the desktop's
existing polkit agent to authenticate when required. FileSail does not implement
or embed a polkit agent.

Illustrative snapshot shape; exact names may be refined before implementation:

```json
{
  "id": 12,
  "ok": true,
  "available": true,
  "backendInstance": "…",
  "revision": 7,
  "drives": [{
    "driveId": "drive-…",
    "label": "Portable SSD",
    "kind": "usb",
    "sizeBytes": "1000204886016",
    "removable": true,
    "ejectable": false,
    "canPowerOff": true,
    "siblingGroup": "…",
    "operation": null,
    "volumes": [{
      "volumeId": "volume-…",
      "label": "Backup",
      "filesystemType": "exfat",
      "sizeBytes": "1000202788864",
      "mountPoints": ["/run/media/user/Backup"],
      "mounted": true,
      "locked": false,
      "readOnly": false,
      "mountable": true,
      "status": "mounted"
    }]
  }]
}
```

Encode 64-bit byte counts as decimal strings, matching JavaScript's integer
precision constraints. Snapshots must not contain passphrases, raw configuration
secrets, or serial numbers unnecessary for presentation.

Emit `volumesChanged` with the complete snapshot and revision. Full snapshots are
small, make object-graph convergence easier, and let QML replace its model
atomically. `VolumeModel` ignores older revisions and resets when
`backendInstance` changes. A consumer first calls `volumes.list`; events and the
response carry enough revision information to resolve the subscribe/list race.

Volume operation responses preserve the existing envelope:

```json
{
  "id": 13,
  "ok": false,
  "error": "The filesystem is busy",
  "errorCode": "device_busy",
  "details": {
    "remoteError": "org.freedesktop.UDisks2.Error.DeviceBusy",
    "systemMessage": "…",
    "driveId": "drive-…",
    "volumeId": "volume-…",
    "completedVolumeIds": []
  }
}
```

Keep `error` as a string for current `BackendClient` callers. Bound and sanitize
the system message before returning it. Never include a passphrase in logging,
errors, operation snapshots, pending-request diagnostics, crash context, or test
fixtures.

Map UDisks and transport failures to stable codes including `device_busy`,
`not_authorized`, `authentication_required`, `authentication_cancelled`,
`mounted_by_other_user`, `option_not_permitted`, `already_mounted`, `not_mounted`,
`already_unmounting`, `already_in_progress`, `would_wake`, `unsupported`,
`timeout`, `cancelled`, `service_unavailable`, `device_removed`,
`path_unrepresentable`, `filesail_operation_active`, `reservation_expired`,
`still_mounted`, `unlock_failed`, and `system_error`. Map by D-Bus error name plus
operation context, not English text. Treat “already mounted” and “not mounted” as
idempotent success only after the refreshed graph confirms the desired state.

Removal reservations are opaque, bound to one backend instance and exact target,
and expire automatically after a short documented deadline if the UI disappears.
Creating one atomically checks active/queued FileSail mutations and blocks new
mutations beneath its mount points. Only the matching unmount/safe-remove request
can consume it. Cancellation, failure, timeout, device removal, and backend
shutdown release it. A caller cannot use the reservation to broaden its target.

Use explicit, longer D-Bus deadlines suitable for a polkit prompt and treat a
timeout as an unknown outcome. Re-enumerate the target before enabling retry; do
not automatically repeat an operation that may have succeeded. A pending volume
request holds a backend operation lease so the helper cannot exit mid-call.

## Operation workflows

### Mount and open

1. Snapshot the current `volumeId` and UI generation; disable duplicate actions.
2. The backend resolves the current Filesystem interface and eligibility.
3. If already mounted, choose the preferred usable mount point. Otherwise call
   `Filesystem.Mount` asynchronously with default options.
4. Validate the returned path and reconcile it with `Filesystem.MountPoints` or a
   bounded property refresh.
5. Return the path to the initiating session, which calls its normal
   `navigate(path)` path. Navigation history commits only when `DirectoryModel`
   successfully loads the directory.
6. If mounting succeeds but navigation fails, leave the volume mounted and report
   the navigation error separately; do not claim the mount failed or silently
   unmount it.

When several mount points exist, prefer the path returned by this mount request,
then a path owned by the active user, then the shortest valid path. Preserve all
mount points in the model because safe removal must account for every one.

### Unlock, mount, and open

1. Show a FileSail password dialog with password echo disabled, no clipboard
   affordance, and no persistence. Clear the field immediately on submit/close.
2. Ensure the backend connection is running before accepting the prompt. Send the
   secret only in a direct request; secret-bearing requests must never enter the
   normal pending-line queue. `BackendClient` must redact the method from
   diagnostics and must not retain the serialized request after it is written.
3. The backend calls `Encrypted.Unlock`, tracks the returned cleartext object, and
   waits for the graph to expose its Filesystem interface.
4. Mount that cleartext volume, validate the returned path, and navigate through
   the normal successful-load path.
5. On failure, discard native buffers as soon as practical and return only a
   contextual `unlock_failed`/authorization error. QML strings cannot guarantee
   secure memory erasure, so the implementation review must document this limit.

Never store or echo the passphrase and never put it in an operation event. Keyring
or system secret-agent integration can be a later, separately reviewed feature.

### Unmount one volume

1. Request a removal reservation. The backend atomically resolves every mount
   point, rejects conflicting FileSail mutations, and reserves those paths.
2. The QML coordinator uses the returned mount points to notify all in-process
   BrowserSessions. They cancel scoped listings/previews and release directory
   watches while keeping their committed location unchanged.
3. Submit `Filesystem.Unmount` with the reservation ID and without force. If UI
   preparation cannot complete, cancel the reservation instead.
4. On failure, restore watches/refresh affected sessions and show the structured
   error. On success, sessions currently inside that volume navigate to Home and
   prune history entries under its former mount points.
5. Do not lock an encrypted container or power off its drive for this
   partition-only action.

### Safely remove a drive

Treat execution as one backend-owned, per-drive state machine, preceded by the
same two-phase QML preparation:

1. `volumes.prepareRemoval` freezes the current drive topology and reserves the
   drive/sibling group against concurrent mount, unmount, remove, and conflicting
   filesystem actions.
2. It detects queued or running FileSail mutations whose source, destination, parent,
   preview, or watched directory lies under any drive mount point. Return
   `filesail_operation_active` with operation IDs instead of racing the transfer.
3. `VolumeModel` asks BrowserSessions to release cancellable reads, previews, and
   watches, then calls `drives.safeRemove` with the reservation. The backend
   independently cancels registered cancellable jobs in scope and rejects new
   mutations beneath reserved mount points until the state machine finishes.
4. Unmount every mounted filesystem belonging to the drive in deterministic
   order. After each reply, reconcile `MountPoints`; if any remain, make only a
   bounded number of further normal unmount attempts and otherwise fail with
   `still_mounted`. Treat an externally completed step idempotently after
   reconciliation.
5. Lock each unlocked encrypted container after its cleartext filesystem is
   unmounted.
6. If `Drive.Ejectable` represents removable media, call `Drive.Eject`; otherwise
   call `Drive.PowerOff` when `CanPowerOff` is true. When neither operation is
   supported, completing all unmounts is success with the result
   `action: "unmount"` and the “can now be safely removed” message.
7. On success, redirect affected sessions to Home, prune stale history entries,
   release reservations, and wait for or reconcile the final graph change.

Before `PowerOff`, inspect `SiblingId`. If other present drives share the physical
device, the confirmation must name/count them because powering off one slot may
affect the whole multi-card reader. The safe-removal state machine includes every
affected sibling in its conflict check and result.

If step 4 fails partway through, stop immediately. Return
`completedVolumeIds`, `remainingMountedVolumeIds`, and the failed volume. Do not
power off/eject, do not call force, and do not remount completed volumes. Retry
rebuilds topology and operates only on what remains. If the final eject/power-off
step fails after all volumes are unmounted, report that the data volumes are
unmounted but the hardware action failed; never mislabel it as fully removed.

### External and unexpected state changes

- A mount or unmount performed by another application updates the sidebar from
  Properties/ObjectManager signals and refreshes affected sessions.
- Removal during an in-flight request completes it once with `device_removed`;
  late callbacks cannot recreate the row or navigate.
- On unexpected removal, cancel work scoped to the lost mount. File mutations use
  their existing partial-result rules; never turn a partial move into success.
- Backend/UDisks restart changes the backend instance or availability and causes a
  fresh snapshot. The UI must not replay old mount/eject requests.
- Repeated clicks and commands are deduplicated per current drive/volume action.
  Unrelated drives may proceed concurrently; actions on the same physical or
  sibling group may not.

## Coordination with FileSail operations and navigation

Add path-scope metadata to active backend jobs so volume removal can identify
listings, previews, watches, Trash, rename, copy, and move work touching a mount.
Cancellable reads and previews may be stopped during preparation. Mutations are
never cancelled implicitly: a safe-removal request fails with
`filesail_operation_active` while a relevant mutation is queued or running.

The backend must also reject a new filesystem mutation that crosses into a mount
reserved for removal. This closes the race between preflight and unmount. Use the
same absolute-local-path validation and boundary-aware containment for both
source and destination paths. A second FileSail process or external application
cannot share this reservation; UDisks remains the final authority and returns
`DeviceBusy` when appropriate.

Create a host-independent QML coordinator, preferably the `VolumeModel` singleton,
with prepare/finished signals. Every `BrowserSession` registers for these signals.
Preparation releases session-scoped watches and cancels eligible requests; success
relocates sessions, while failure reattaches watches and refreshes. Keep the
coordination in shared QML/core rather than `shell.qml` or a compositor adapter.

When a mount disappears:

- an affected current or pending location navigates to Home using an internal
  origin and still commits only after Home loads successfully;
- back/forward entries contained by the removed mount points are pruned only after
  confirmed unmount/removal;
- selections are cleared, and transfer-clipboard items on the missing mount are
  invalidated by volume identity so reconnecting different media at the same path
  cannot reactivate them;
- previews are cancelled by request generation;
- bookmarks/projects retain their saved path and naturally show unavailable.

Trash behavior must be verified on removable filesystems. `QFile::moveToTrash`
should use a standards-compliant per-volume Trash when supported. Add tests and
manual checks for writable removable volumes, missing/invalid Trash directories,
read-only media, and unmounted-during-request failures. A Trash failure must remain
a failure; never fall back to permanent deletion. Restore-from-Trash remains its
own roadmap item, but its metadata design must include per-volume Trash roots.

## UI and source changes

Expected implementation touch points:

- `src/backend/volumeservice.{h,cpp}`: object graph, filtering, snapshots, async
  state machines, UDisks error mapping, and service-owner recovery;
- `src/backend/backendserver.{h,cpp}`: protocol routing, event forwarding,
  operation leases, and path-scope/reservation coordination;
- `src/backend/fileoperations.*` and preview/list job bookkeeping: expose touched
  path scopes without weakening existing validation or serialization;
- `qml/core/VolumeModel.qml`: singleton snapshot/model adapter, revision handling,
  actions, per-target state, and session coordination;
- `qml/core/BackendClient.qml`: typed volume helpers, no-timeout leases, event
  dispatch, structured errors, and secret-safe request handling;
- `qml/core/BrowserSession.qml`, `DirectoryModel.qml`, and
  `NavigationController.qml`: release/recover mount resources and prune confirmed
  stale history safely;
- `qml/components/Sidebar.qml` plus small device-row/list components: Devices
  section, states, actions, keyboard behavior, and accessibility;
- `qml/components/BrowserDialogs.qml` or focused new dialogs: LUKS prompt,
  sibling-device confirmation, and persistent operation errors;
- `qml/core/Theme.qml` only if a genuinely missing semantic state token is needed;
  reuse the contract rather than importing Noctalia tokens;
- `CMakeLists.txt`, `qml/core/qmldir`, packaging, README, and
  `docs/architecture.md`: source registration, runtime requirements, protocol,
  and supported/degraded behavior.

The Devices section must work at narrow widths, with long translated labels,
keyboard-only operation, screen-reader names, high scale factors, and while the
sidebar scrolls. Keep focus stable as hotplug events insert/remove rows. An action
must target its captured opaque ID, not a reusable delegate index.

## Packaging and deployment

- Add `udisks2` as a runtime dependency for packages that advertise removable
  storage support. The AppImage must use the host's system UDisks2 daemon and
  policies; do not bundle or start a privileged daemon inside the image.
- Document that an active polkit authentication agent is required only when local
  policy requests authentication. FileSail should still browse already-mounted
  media without one.
- At startup, absence of the system bus, UDisks2, or permission to enumerate it is
  nonfatal. The browser remains usable and the Devices section shows a restrained
  unavailable explanation with a retry after owner changes.
- Log operation type, opaque ID, state transition, remote error name, and elapsed
  time at appropriate levels. Never log device serials, passphrases, full raw
  object dumps, or user file lists merely for device discovery.
- Add a startup capability field/version so UI and backend mismatches disable
  device actions cleanly rather than sending unknown methods.

## Implementation sequence

### 1. Read-only discovery and model contract

- Build the injected/testable UDisks object graph and immutable snapshot schema.
- Implement eligibility, identity, name/icon/state derivation, owner recovery, and
  coalesced `volumesChanged` events.
- Add `volumes.list`, `VolumeModel`, and a read-only Devices section.
- Freeze protocol fixtures after validating them against USB sticks, USB SSDs,
  built-in and USB SD readers, multi-partition media, and no-media readers.

Exit condition: hotplug and externally changed mount states are accurately shown,
internal/ignored devices are protected, stale events are ignored, and no action is
enabled yet.

### 2. Mount, unmount, and structured errors

- Add async mount and partition-only unmount methods with revision reconciliation.
- Add per-target operation state, polkit-friendly deadlines, stable error mapping,
  persistent error UX, and mount-then-normal-navigation behavior.
- Add session watch/preview preparation and recovery.

Exit condition: mounted and unmounted filesystems can be opened and unmounted
without blocking QML; busy, authorization, unsupported, timeout, and hot-unplug
cases preserve truthful state and offer useful recovery.

### 3. Whole-drive safe removal

- Add path-scope conflict detection, removal reservations, multi-volume sequencing,
  encrypted-container locking hooks, and eject/power-off/unmount fallback.
- Add sibling-device confirmation and partial-result presentation.
- Redirect affected sessions and prune mount-scoped history only on confirmed
  state changes.

Exit condition: the inline action safely handles every volume on a physical drive,
never powers off after a failed unmount, never races FileSail mutations, and gives
an accurate safe-to-remove result.

### 4. Encrypted and special media

- Add the secret-safe unlock dialog/request path and unlock-mount-open state
  machine.
- Complete lock-on-removal, read-only media, multi-partition, unsupported media,
  and data/blank/audio optical presentation.
- Verify per-volume Trash behavior without adding permanent deletion.

Exit condition: encrypted removable volumes and the complete baseline matrix are
usable without secrets entering logs/state, and non-browsable media remains
truthfully visible and ejectable.

### 5. Packaging, documentation, and release hardening

- Update dependencies, AppImage limitations, README, architecture, translations,
  accessibility strings, and troubleshooting.
- Run automated suites and the physical-device matrix below.
- Gate release on no known path where the UI reports “safe to remove” while a
  filesystem remains mounted or an eject/power-off call failed.

## Verification strategy

### Automated backend tests

Do not require root or touch the developer's real disks. Make the D-Bus service
name/bus injectable in test builds and run a small fake ObjectManager on a private
test bus. Cover:

- initial enumeration and every ordering of Drive/Block/Partition/Filesystem/
  Encrypted interface arrival and removal;
- USB, SD/MMC, optical, multi-partition, empty-reader, ignored, system, loop,
  other-seat, cloned-UUID, and sibling-drive fixtures;
- property changes, external mount/unmount, service disappearance/reappearance,
  event coalescing, monotonic revisions, and subscribe/list races;
- valid byte-array mount paths, spaces/Unicode, invalid encoding, NUL, non-absolute
  paths, multiple mount points, and path-boundary containment;
- mount/unmount/unlock/lock/eject/power-off calls, default empty option dictionaries,
  method deadlines, job association, and object disappearance mid-call;
- every UDisks error-name mapping, bounded raw details, already-at-target
  reconciliation, unknown timeout outcomes, and stale opaque IDs;
- multi-volume safe removal success and failure at every step, including no
  power-off after a busy unmount and accurate partial arrays;
- active/queued FileSail operation conflicts, reservation creation/consumption/
  expiry races, unrelated-drive concurrency, and backend shutdown leases;
- password redaction from logs, events, snapshots, errors, and retained request
  bookkeeping.

Extend the newline-delimited protocol suite for partial framing, multiple requests,
malformed parameters, duplicate IDs/actions, backend restarts, and protocol-version
fallback. Keep all existing filesystem path and transfer edge-case tests.

### Automated QML tests

Feed `VolumeModel` recorded snapshots and failures. Verify:

- atomic replacement and stale revision rejection;
- single/multiple-volume row structure, labels, icons, state text, enabled actions,
  focus retention, and delegate reuse;
- click-to-mount/open and navigation commit only after successful directory load;
- double-click/repeated-action suppression and target capture by ID rather than row
  index;
- persistent busy/partial/auth errors, retry after a new snapshot, and plain-text
  treatment of hostile labels/messages;
- prepare/failure/success behavior for watches, previews, selection, clipboard, and
  navigation history across multiple BrowserSessions;
- keyboard, tooltip, accessible-name, compact-width, translation, and scale cases.

### Physical and desktop integration matrix

Run on both Niri and Hyprland hosts where available, including a standalone launch
started directly and from Noctalia. At minimum test:

- FAT32/exFAT USB stick, ext4 USB disk, NTFS media when a driver is installed, and
  a read-only/write-protected device;
- SD card in a built-in reader and a multi-slot USB reader;
- one multi-partition drive and one LUKS drive with correct, incorrect, and
  cancelled passphrase flows;
- a filesystem mounted by FileSail and one mounted by another desktop component;
- files open in FileSail, a terminal whose working directory is on the drive, an
  external application holding a file, and an active copy in each direction;
- unplug without unmount, unplug during mount, service restart, polkit approval,
  cancellation, denial, and absence of a polkit agent;
- ejectable optical media if hardware is available;
- the installed package and AppImage using the host daemon.

Confirm real mount paths, ownership, write access, read-only behavior, per-volume
Trash results, cross-device copy/move partial handling, and that the device truly
disappears or reports safe removal as expected. Never run destructive filesystem
tests on non-disposable media.

Run the repository checks appropriate to each implementation phase:

```sh
cmake --build build
ctest --test-dir build --output-on-failure
qmllint -I /usr/lib/qt6/qml -I qml qml/core/*.qml qml/components/*.qml shell.qml
qmllint -I /usr/lib/qt6/qml -I qml integrations/noctalia/*.qml
```

For QML changes, perform a bounded standalone launch that reaches
`Configuration Loaded`, note that it briefly creates a Wayland window, and leave
no test Quickshell instances running.

## Release acceptance criteria

The feature is complete only when all of the following are true:

- eligible USB/SD devices appear, update, and disappear live without exposing
  protected internal devices;
- every visible state has truthful text and only valid actions;
- mount/unlock/open honors normal navigation-load commit semantics;
- unmount and safe removal handle all partitions, encryption, siblings, FileSail
  operations, external busy state, partial completion, and hot-unplug safely;
- no code path uses forced unmount, permanent deletion, shell-parsed storage state,
  arbitrary device paths from QML, or logged/stored passphrases;
- UI, backend, and system state converge after success, failure, timeout, external
  changes, and daemon/backend restarts;
- degraded systems remain usable, packaging declares the host dependency, and all
  automated plus applicable hardware tests pass;
- `docs/architecture.md` and user-facing setup/troubleshooting describe the final
  protocol and behavior before release.

## Upstream API references

- [UDisks2 Filesystem interface](https://storaged.org/doc/udisks2-api/latest/gdbus-org.freedesktop.UDisks2.Filesystem.html)
- [UDisks2 Drive interface](https://storaged.org/doc/udisks2-api/latest/gdbus-org.freedesktop.UDisks2.Drive.html)
- [UDisks2 Block interface](https://storaged.org/doc/udisks2-api/latest/gdbus-org.freedesktop.UDisks2.Block.html)
- [UDisks2 Encrypted interface](https://storaged.org/doc/udisks2-api/latest/gdbus-org.freedesktop.UDisks2.Encrypted.html)
- [UDisks2 Job interface](https://storaged.org/doc/udisks2-api/latest/gdbus-org.freedesktop.UDisks2.Job.html)
- [UDisks2 error codes](https://storaged.org/doc/udisks2-api/latest/udisks2-UDisksError.html)
- [UDisks2 authorization model](https://storaged.org/doc/udisks2-api/latest/udisks-polkit-actions.html)
- [UDisks2 standard method options](https://storaged.org/doc/udisks2-api/latest/udisks-std-options.html)
