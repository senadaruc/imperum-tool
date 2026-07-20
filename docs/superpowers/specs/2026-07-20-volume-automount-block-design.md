# Volume Auto-Mount Blocking — Design

## Goal

Port MountMate's "prevent this specific external volume from auto-mounting
when connected" capability into WSMonitor, so a single external SSD (e.g. one
built into a docking station) can be kept from auto-mounting without needing
MountMate running just for that.

Motivation: consolidate to one fewer always-running menu-bar app.

## Scope

In scope:
- A list of currently-connected external volumes in Settings, each with a
  "Block auto-mount" toggle.
- A list of currently-blocked volumes (including ones not currently
  connected), each removable.
- Enforcement via DiskArbitration mount-approval dissent, persisted across
  launches.

Out of scope (deliberately, to keep this additive and small):
- Mount / unmount / eject UI — WSMonitor does not become a disk manager.
  MountMate remains the tool for that.
- A "manual mount despite block" approval mechanism. To mount a blocked
  volume, the user untoggles "Block auto-mount" first, then mounts normally
  (Finder / Disk Utility / reconnect). This is simpler than MountMate's
  temporary-approval window because WSMonitor has no mount button of its own
  to whitelist.
- Protect/ignore volume lists, network shares, RAID/APFS container
  modeling, free-space stats — none of that is needed just to identify and
  block a volume by UUID.

## Architecture

Four new pieces, following WSMonitor's existing conventions (pure/testable
logic in `WSCore`, system-framework glue in the `WSMonitor` executable
target).

### 1. Volume discovery — `WSCore/ExternalVolume.swift`

A pure, testable parser mirroring the existing split in `CPUSampler`
(`sample(rows:wanted:now:)` = pure core vs `sample(pids:)` = thin subprocess
wrapper):

```swift
public struct ExternalVolume: Identifiable, Equatable {
    public var id: String { compositeID }
    public let name: String
    public let deviceIdentifier: String
    public let diskUUID: String?
    public let volumeUUID: String
    public let busProtocol: String?

    public var compositeID: String { "\(diskUUID ?? "NONE")-\(volumeUUID)" }
}

public func parseExternalVolumes(diskutilPlist: Data, infoPlists: [String: Data]) -> [ExternalVolume]
```

- Filters to non-internal, non-RAID-member, non-EFI volumes only (no
  partition tree, no APFS container nesting, no free-space math — none of
  that is needed here).
- `compositeID` scheme (`diskUUID-volumeUUID`, defaulting to `"NONE"` when
  `diskUUID` is absent) intentionally matches MountMate's, so an ID is
  recognizable if ever cross-referenced between the two apps.

A thin `runDiskutil()` wrapper shells out via `Process` with
`executableURL`/`arguments` array (`/usr/sbin/diskutil`, `["list", "-plist"]`
etc.) — **not** a shell string. This matches how `CPUSampler.runPS()` already
invokes `/bin/ps` in this codebase, and avoids the shell-string-interpolation
pattern used in MountMate's `Shell.swift`.

### 2. Block list persistence — `WSCore/VolumeBlockStore.swift`

```swift
public struct BlockedVolume: Codable, Identifiable, Equatable {
    public let compositeID: String
    public let name: String
    public var id: String { compositeID }
}

public final class VolumeBlockStore: ObservableObject {
    @Published public private(set) var blocked: [BlockedVolume]
    public func block(_ volume: ExternalVolume)
    public func unblock(_ compositeID: String)
    public func isBlocked(_ compositeID: String) -> Bool
}
```

`UserDefaults`-backed JSON array under one key
(`wsmonitor_blockedVolumes_v1`), same encode/decode pattern as MountMate's
`PersistenceManager`, scoped to just this one list.

### 3. DiskArbitration enforcement — `WSMonitor/VolumeAutoMountBlocker.swift`

A near-1:1 port of MountMate's `DiskMounter`, simplified:

- Owns a `DASession`, created once and kept alive for the app's entire
  lifetime (started in `AppController.start()`, not tied to Settings window
  visibility).
- Registers a `DADiskMountApprovalCallback` matching mountable volumes.
- On callback: reads the disk's volume/media UUID from
  `DADiskCopyDescription`, builds the same composite ID scheme, checks
  `VolumeBlockStore.isBlocked(_:)` (synced into a local `Set<String>` via a
  `Combine` sink on `$blocked`, mirroring `DiskMounter`'s
  `PersistenceManager.shared.$blockedVolumes.sink`), dissents
  (`DADissenterCreate` with `kDAReturnNotPermitted`) if blocked.
- No "approve manual mount" grace window (unlike MountMate) — not needed
  since WSMonitor has no mount button to whitelist against.
- No global "block all USB" toggle — per-volume blocking only, matching the
  narrowed scope.

### 4. Settings UI — new section in `Settings.swift`'s `SettingsView`

Added as a `Form` `Section("External Volumes")`, between "Spike thresholds"
and "About" (no `TabView` currently exists in WSMonitor's Settings, unlike
MountMate, so this stays a Form section rather than a new tab).

```
Section("External Volumes") {
  Connected                                    [↻ refresh]
  ─────────────────────────────────────────────────────
  Dock-SSD                              [ ] Block
  Samsung SSD 970 EVO Plus              [ ] Block

  Blocked (not currently connected)
  ─────────────────────────────────────────────────────
  (empty, or) OldBackupDrive                  [🗑]

  "Blocked volumes won't auto-mount when connected.
   Untoggle here, or use Disk Utility, to mount them."
}
```

- Toggle next to a connected volume → `store.block(volume)` /
  `store.unblock(volume.compositeID)`.
- Trash icon next to a disconnected-but-blocked entry → `store.unblock(_:)`.
- Manual refresh button re-runs volume discovery.

## Data Flow

1. **App start**: `AppController.start()` constructs `VolumeBlockStore()`
   (loads persisted IDs) and `VolumeAutoMountBlocker(store:)` (starts the
   `DASession` immediately). Lives for the whole app run.
2. **Settings opens**: the new section's `onAppear` triggers
   `refreshConnectedVolumes()` (background queue: `diskutil list -plist` +
   per-disk `diskutil info -plist`) → `parseExternalVolumes()` → published to
   the view on the main thread. Subscribes to
   `NSWorkspace.didMountNotification` / `didUnmountNotification` (debounced)
   to auto-refresh while the window stays open; unsubscribes on disappear.
3. **Toggle "Block" on a connected volume**: `VolumeBlockStore.block(_:)`
   appends + saves immediately. No need to refresh the connected list —
   blocking only affects future auto-mount attempts.
4. **New disk arrives** (e.g. dock powers on): DA mount-approval callback
   fires per volume before the OS mounts it → checked against the in-memory
   blocked-ID set → dissented if blocked.
5. **Unblock**: removed from the store; takes effect on the next mount
   attempt for that volume (no restart needed, since the callback re-checks
   the live set each time).

## Error Handling

- `diskutil list -plist` failing/empty → connected-volumes list shows an
  inline "No external volumes found" / error text. This is a best-effort,
  non-critical-path listing (unlike MountMate's `DriveManager`, which retries
  because a failed enumeration there breaks the whole app) — no retry loop.
- DiskArbitration session failing to start → logged via `NSLog` (matching
  `AppController`'s existing logging style); the Settings list still lets you
  view/edit the block list, it just isn't enforced until the session comes
  up. No user-facing alert — this is a background convenience feature, not a
  primary workflow.
- No shell-injection surface: composite IDs and device identifiers come only
  from `diskutil`'s plist output and DiskArbitration's description
  dictionary, never from user-typed strings. `Process` is invoked with an
  argument array, never an interpolated shell string.

## Testing

Following `WSCoreTests`' existing convention (pure-logic unit tests, no
subprocess/system calls in tests):

- `parseExternalVolumes(diskutilPlist:infoPlists:)` — fixture plist strings
  inline in the test file. Covers: filtering out internal disks, RAID
  members, EFI partitions; correct `compositeID` construction, including the
  `"NONE"` fallback when `diskUUID` is absent.
- `VolumeBlockStore` — block/unblock/isBlocked round-trips against an
  isolated in-memory `UserDefaults(suiteName:)` instance per test (no
  pollution of real prefs).
- `VolumeAutoMountBlocker`'s DiskArbitration callback itself is not
  unit-tested (system framework callback — MountMate leaves the equivalent
  `DiskMounter` untested too) — verified manually by connecting/reconnecting
  the docking station.
