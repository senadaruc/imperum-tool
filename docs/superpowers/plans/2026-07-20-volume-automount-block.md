# Volume Auto-Mount Blocking Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let a user block a specific external volume (e.g. an SSD built into a docking station) from auto-mounting when connected, managed from a new "External Volumes" section in Imperum Tool's (WSMonitor's) Settings window.

**Architecture:** A pure/testable `diskutil`-plist parser and a `UserDefaults`-backed block-list store live in `WSCore` (mirroring the pure-logic-vs-thin-subprocess-wrapper split already used by `CPUSampler`). A DiskArbitration mount-approval callback (`VolumeAutoMountBlocker`, ported from MountMate's `DiskMounter`) lives in the `WSMonitor` executable target, started once at app launch and running for the app's whole life. A new Settings section lists currently-connected external volumes with block toggles, plus any blocked-but-disconnected volumes with a remove button.

**Tech Stack:** Swift, SwiftUI, DiskArbitration, `Process`/`diskutil`, `UserDefaults`, XCTest.

## Global Constraints

- No shell-string interpolation for subprocesses — use `Process` with `executableURL` + `arguments` array (per the design's error-handling section and the existing `CPUSampler.runPS()` convention).
- Pure parsing/store logic goes in `WSCore` and is unit-tested; system-framework glue (DiskArbitration) goes in the `WSMonitor` executable target and is not unit-tested (matches `WSCoreTests`' existing scope).
- No mount/unmount/eject UI, no global "block all USB" toggle, no manual-mount-approval grace window — out of scope per the approved design doc (`docs/superpowers/specs/2026-07-20-volume-automount-block-design.md`).
- `compositeID` scheme is `"\(diskUUID ?? "NONE")-\(volumeUUID)"`, matching MountMate's identifier convention exactly.
- Disk images (mounted `.dmg` volumes) are never listed as blockable and are never dissented, even if a stale blocked entry somehow references one.

---

### Task 1: `ExternalVolume` model + pure `diskutil`-plist parser

**Files:**
- Create: `Sources/WSCore/ExternalVolume.swift`
- Test: `Tests/WSCoreTests/ExternalVolumeTests.swift`

**Interfaces:**
- Produces: `public struct ExternalVolume: Identifiable, Equatable, Hashable { name: String, deviceIdentifier: String, diskUUID: String?, volumeUUID: String, busProtocol: String?; var compositeID: String; var id: String }`
- Produces: `public func parseExternalVolumes(listPlist: Data, infoPlists: [String: Data]) -> [ExternalVolume]`

- [ ] **Step 1: Write the failing tests**

Create `Tests/WSCoreTests/ExternalVolumeTests.swift`:

```swift
import XCTest
@testable import WSCore

private func plistData(_ dict: [String: Any]) -> Data {
    try! PropertyListSerialization.data(fromPropertyList: dict, format: .xml, options: 0)
}

final class ExternalVolumeTests: XCTestCase {
    func testExcludesInternalDisk() {
        let list: [String: Any] = ["AllDisksAndPartitions": [
            ["DeviceIdentifier": "disk0", "Partitions": [
                ["DeviceIdentifier": "disk0s1", "Content": "Apple_APFS"]
            ]]
        ]]
        let info: [String: Any] = ["Internal": true, "VirtualOrPhysical": "Physical"]
        let volumes = parseExternalVolumes(
            listPlist: plistData(list), infoPlists: ["disk0": plistData(info)])
        XCTAssertTrue(volumes.isEmpty)
    }

    func testIncludesSimpleExternalVolume() {
        let list: [String: Any] = ["AllDisksAndPartitions": [
            ["DeviceIdentifier": "disk4", "Partitions": [
                ["DeviceIdentifier": "disk4s1", "Content": "Windows_FAT_32",
                 "VolumeName": "BACKUP", "VolumeUUID": "UUID-BACKUP"]
            ]]
        ]]
        let info: [String: Any] = ["Internal": false, "VirtualOrPhysical": "Physical",
                                    "BusProtocol": "USB", "DiskUUID": "UUID-DISK4"]
        let volumes = parseExternalVolumes(
            listPlist: plistData(list), infoPlists: ["disk4": plistData(info)])
        XCTAssertEqual(volumes.count, 1)
        XCTAssertEqual(volumes[0].name, "BACKUP")
        XCTAssertEqual(volumes[0].compositeID, "UUID-DISK4-UUID-BACKUP")
    }

    func testExcludesDiskImage() {
        let list: [String: Any] = ["AllDisksAndPartitions": [
            ["DeviceIdentifier": "disk6", "Partitions": [
                ["DeviceIdentifier": "disk6s1", "Content": "Apple_HFS",
                 "VolumeName": "Installer", "VolumeUUID": "UUID-DMG"]
            ]]
        ]]
        let info: [String: Any] = ["Internal": false, "VirtualOrPhysical": "Virtual"]
        let volumes = parseExternalVolumes(
            listPlist: plistData(list), infoPlists: ["disk6": plistData(info)])
        XCTAssertTrue(volumes.isEmpty)
    }

    func testExcludesRAIDMember() {
        let list: [String: Any] = ["AllDisksAndPartitions": [
            ["DeviceIdentifier": "disk5", "Partitions": [
                ["DeviceIdentifier": "disk5s1", "Content": "Apple_HFS",
                 "VolumeName": "RAIDPart", "VolumeUUID": "UUID-RAID"]
            ]]
        ]]
        let info: [String: Any] = ["Internal": false, "VirtualOrPhysical": "Physical", "RAIDMember": true]
        let volumes = parseExternalVolumes(
            listPlist: plistData(list), infoPlists: ["disk5": plistData(info)])
        XCTAssertTrue(volumes.isEmpty)
    }

    func testResolvesAPFSContainerVolumesWithoutDuplicates() {
        // Mirrors a docking-station SSD: a physical disk with an EFI partition
        // and an Apple_APFS "store" partition (disk8s2) whose container is a
        // separately-listed disk9 entry (linked via disk9's own
        // APFSPhysicalStores), whose APFSVolumes holds the actual mountable
        // volume. This is the "Dock-SSD" case from the original bug report.
        // disk9 also independently satisfies the root-disk scan (its own
        // identifier never appears inside anyone's "Partitions" array), so
        // this test also guards against double-counting disk9's volumes.
        let list: [String: Any] = ["AllDisksAndPartitions": [
            ["DeviceIdentifier": "disk8", "Partitions": [
                ["DeviceIdentifier": "disk8s1", "Content": "EFI", "VolumeName": "EFI"],
                ["DeviceIdentifier": "disk8s2", "Content": "Apple_APFS"],
            ]],
            ["DeviceIdentifier": "disk9",
             "APFSPhysicalStores": [["DeviceIdentifier": "disk8s2"]],
             "APFSVolumes": [
                ["DeviceIdentifier": "disk9s1", "Content": "APFS",
                 "VolumeName": "Dock-SSD", "VolumeUUID": "UUID-DOCKSSD"]
             ]],
        ]]
        let diskInfo: [String: Any] = ["Internal": false, "VirtualOrPhysical": "Physical",
                                        "BusProtocol": "USB", "DiskUUID": "UUID-DISK8"]
        let volumes = parseExternalVolumes(
            listPlist: plistData(list), infoPlists: ["disk8": plistData(diskInfo)])

        XCTAssertEqual(volumes.count, 2)
        XCTAssertEqual(volumes.map(\.name).sorted(), ["Dock-SSD", "EFI"])
        let dockSSD = volumes.first { $0.name == "Dock-SSD" }
        XCTAssertEqual(dockSSD?.compositeID, "UUID-DISK8-UUID-DOCKSSD")
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter ExternalVolumeTests`
Expected: FAIL to build — `ExternalVolume` / `parseExternalVolumes` not defined.

- [ ] **Step 3: Write the implementation**

Create `Sources/WSCore/ExternalVolume.swift`:

```swift
import Foundation

/// An external volume identified for auto-mount blocking. Deliberately
/// carries only identity fields — no size/free-space/snapshot data — since
/// blocking only needs to recognize a volume, not describe it fully.
public struct ExternalVolume: Identifiable, Equatable, Hashable {
    public let name: String
    public let deviceIdentifier: String
    public let diskUUID: String?
    public let volumeUUID: String
    public let busProtocol: String?

    /// Matches MountMate's identifier scheme exactly (`diskUUID-volumeUUID`,
    /// defaulting to "NONE" when `diskUUID` is absent) so a blocked ID is
    /// recognizable if ever cross-referenced between the two apps.
    public var compositeID: String { "\(diskUUID ?? "NONE")-\(volumeUUID)" }
    public var id: String { compositeID }

    public init(name: String, deviceIdentifier: String, diskUUID: String?, volumeUUID: String, busProtocol: String?) {
        self.name = name
        self.deviceIdentifier = deviceIdentifier
        self.diskUUID = diskUUID
        self.volumeUUID = volumeUUID
        self.busProtocol = busProtocol
    }
}

private func isRAIDMaster(_ info: [String: Any]?) -> Bool {
    guard let info else { return false }
    if let v = info["RAIDMaster"] as? Bool { return v }
    if let v = info["RAIDMaster"] as? String { return ["yes", "true"].contains(v.lowercased()) }
    return false
}

private func isRAIDMember(_ info: [String: Any]?) -> Bool {
    guard let info, !isRAIDMaster(info) else { return false }
    if let v = info["RAIDMember"] as? Bool { return v }
    if let v = info["RAIDMember"] as? String { return ["yes", "true"].contains(v.lowercased()) }
    if let master = info["RAIDMaster"] as? String, master.hasPrefix("disk") { return true }
    return false
}

/// Parses `diskutil list -plist` output (`listPlist`) plus one
/// `diskutil info -plist <id>` result per root disk identifier
/// (`infoPlists`, keyed by `DeviceIdentifier`) into the external volumes
/// eligible for auto-mount blocking.
///
/// Excludes: internal disks, RAID members, disk images (mounting a `.dmg`
/// isn't the "auto-mount on connect" annoyance this feature targets), and
/// `Apple_RAID`/`Apple_RAID_Offline` placeholder entries. EFI partitions are
/// included (matching MountMate, which lists them too — they're harmless to
/// offer blocking for even though they rarely auto-mount).
///
/// Pure and synchronous — call `fetchExternalVolumes()` (WSCore's thin
/// subprocess wrapper) instead of shelling out yourself.
public func parseExternalVolumes(listPlist: Data, infoPlists: [String: Data]) -> [ExternalVolume] {
    guard
        let root = try? PropertyListSerialization.propertyList(from: listPlist, options: [], format: nil) as? [String: Any],
        let allDisksAndPartitions = root["AllDisksAndPartitions"] as? [[String: Any]]
    else { return [] }

    func parsedInfo(for identifier: String) -> [String: Any]? {
        guard let data = infoPlists[identifier] else { return nil }
        return (try? PropertyListSerialization.propertyList(from: data, options: [], format: nil)) as? [String: Any]
    }

    var childDeviceIDs = Set<String>()
    for diskData in allDisksAndPartitions {
        if let partitions = diskData["Partitions"] as? [[String: Any]] {
            partitions.forEach { childDeviceIDs.insert($0["DeviceIdentifier"] as? String ?? "") }
        }
    }
    let rootDisks = allDisksAndPartitions.filter { !childDeviceIDs.contains($0["DeviceIdentifier"] as? String ?? "") }

    func findAPFSContainer(forStore storeID: String) -> [String: Any]? {
        allDisksAndPartitions.first { disk in
            guard let stores = disk["APFSPhysicalStores"] as? [[String: Any]] else { return false }
            return (stores.first?["DeviceIdentifier"] as? String) == storeID
        }
    }

    var results: [ExternalVolume] = []

    for diskData in rootDisks {
        guard let physicalIdentifier = diskData["DeviceIdentifier"] as? String else { continue }
        let diskInfo = parsedInfo(for: physicalIdentifier)
        if isRAIDMember(diskInfo) { continue }
        if (diskInfo?["Internal"] as? Bool) ?? false { continue }
        let isVirtual = (diskInfo?["VirtualOrPhysical"] as? String) == "Virtual"
        if isVirtual && !isRAIDMaster(diskInfo) { continue } // disk image

        let diskUUID = diskInfo?["DiskUUID"] as? String
        let busProtocol = diskInfo?["BusProtocol"] as? String

        func appendVolume(_ volumeData: [String: Any]) {
            guard let deviceIdentifier = volumeData["DeviceIdentifier"] as? String else { return }
            let contentType = volumeData["Content"] as? String
            if contentType == "Apple_RAID" || contentType == "Apple_RAID_Offline" { return }
            let volumeUUID = volumeData["VolumeUUID"] as? String ?? deviceIdentifier
            let volumeName = volumeData["VolumeName"] as? String ?? contentType ?? deviceIdentifier
            results.append(ExternalVolume(
                name: volumeName, deviceIdentifier: deviceIdentifier,
                diskUUID: diskUUID, volumeUUID: volumeUUID, busProtocol: busProtocol))
        }

        if let partitions = diskData["Partitions"] as? [[String: Any]] {
            for partitionData in partitions {
                if partitionData["Content"] as? String == "Apple_APFS" {
                    let storeID = partitionData["DeviceIdentifier"] as? String ?? ""
                    if let containerData = findAPFSContainer(forStore: storeID),
                       let apfsVolumes = containerData["APFSVolumes"] as? [[String: Any]] {
                        apfsVolumes.forEach(appendVolume)
                    }
                } else {
                    appendVolume(partitionData)
                }
            }
        } else if let apfsVolumes = diskData["APFSVolumes"] as? [[String: Any]] {
            apfsVolumes.forEach(appendVolume)
        }
    }

    // A container disk (e.g. disk9) can independently satisfy the root-disk
    // scan above (its own identifier is never inside anyone's "Partitions"
    // array — only its underlying store's identifier is) in addition to
    // being discovered via its parent's Apple_APFS partition. De-duplicate
    // by device identifier so its volumes aren't counted twice.
    var seenDeviceIDs = Set<String>()
    return results.filter { seenDeviceIDs.insert($0.deviceIdentifier).inserted }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter ExternalVolumeTests`
Expected: PASS (5 tests)

- [ ] **Step 5: Commit**

```bash
cd ~/WSMonitor
git add Sources/WSCore/ExternalVolume.swift Tests/WSCoreTests/ExternalVolumeTests.swift
git commit -m "feat: add pure diskutil-plist parser for external volumes"
```

---

### Task 2: `diskutil` subprocess wrapper

**Files:**
- Create: `Sources/WSCore/DiskutilRunner.swift`

**Interfaces:**
- Consumes: `parseExternalVolumes(listPlist:infoPlists:) -> [ExternalVolume]` (Task 1)
- Produces: `public func fetchExternalVolumes() -> [ExternalVolume]` — synchronous, shells out; callers must invoke off the main thread.

Not unit-tested (matches `CPUSampler.runPS()`'s untested-subprocess-wrapper convention) — verified manually in Task 6 once the Settings UI can display its result.

- [ ] **Step 1: Write the implementation**

Create `Sources/WSCore/DiskutilRunner.swift`:

```swift
import Foundation

/// Thin subprocess wrappers around `diskutil`, using `Process` with an
/// argument array (never an interpolated shell string). Kept separate from
/// `parseExternalVolumes` so the parsing logic stays pure and testable
/// without spawning a process — mirrors `CPUSampler`'s `runPS()` split.
enum DiskutilRunner {
    static func listPlist() -> Data? {
        run(arguments: ["list", "-plist"])
    }

    static func infoPlist(for identifier: String) -> Data? {
        run(arguments: ["info", "-plist", identifier])
    }

    private static func run(arguments: [String]) -> Data? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/sbin/diskutil")
        p.arguments = arguments
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = Pipe()
        do { try p.run() } catch { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return data.isEmpty ? nil : data
    }
}

/// Runs `diskutil list -plist` plus one `diskutil info -plist` per root disk
/// identifier found in the list, and returns the parsed external volumes.
/// Synchronous and shells out — call from a background queue.
public func fetchExternalVolumes() -> [ExternalVolume] {
    guard
        let listData = DiskutilRunner.listPlist(),
        let root = try? PropertyListSerialization.propertyList(from: listData, options: [], format: nil) as? [String: Any],
        let allDisksAndPartitions = root["AllDisksAndPartitions"] as? [[String: Any]]
    else { return [] }

    var infoPlists: [String: Data] = [:]
    for diskData in allDisksAndPartitions {
        guard let identifier = diskData["DeviceIdentifier"] as? String else { continue }
        if let data = DiskutilRunner.infoPlist(for: identifier) {
            infoPlists[identifier] = data
        }
    }

    return parseExternalVolumes(listPlist: listData, infoPlists: infoPlists)
}
```

- [ ] **Step 2: Build to verify it compiles**

Run: `swift build`
Expected: `Build complete!`

- [ ] **Step 3: Commit**

```bash
cd ~/WSMonitor
git add Sources/WSCore/DiskutilRunner.swift
git commit -m "feat: add diskutil subprocess wrapper for external volume discovery"
```

---

### Task 3: `VolumeBlockStore` persistence

**Files:**
- Create: `Sources/WSCore/VolumeBlockStore.swift`
- Test: `Tests/WSCoreTests/VolumeBlockStoreTests.swift`

**Interfaces:**
- Consumes: `ExternalVolume` (Task 1, for `.block(_:)`'s parameter)
- Produces: `public struct BlockedVolume: Codable, Identifiable, Equatable { compositeID: String, name: String; var id: String }`
- Produces: `public final class VolumeBlockStore: ObservableObject { @Published private(set) var blocked: [BlockedVolume]; init(defaults: UserDefaults = .standard); func isBlocked(_ compositeID: String) -> Bool; func block(_ volume: ExternalVolume); func unblock(_ compositeID: String) }`

- [ ] **Step 1: Write the failing tests**

Create `Tests/WSCoreTests/VolumeBlockStoreTests.swift`:

```swift
import XCTest
@testable import WSCore

final class VolumeBlockStoreTests: XCTestCase {
    private func makeDefaults() -> UserDefaults {
        let suiteName = "VolumeBlockStoreTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }

    private func makeVolume(name: String = "Dock-SSD") -> ExternalVolume {
        ExternalVolume(name: name, deviceIdentifier: "disk9s1",
                       diskUUID: "UUID-DISK", volumeUUID: "UUID-VOL", busProtocol: "USB")
    }

    func testStartsEmpty() {
        let store = VolumeBlockStore(defaults: makeDefaults())
        XCTAssertTrue(store.blocked.isEmpty)
    }

    func testBlockAddsAndPersists() {
        let defaults = makeDefaults()
        let volume = makeVolume()
        VolumeBlockStore(defaults: defaults).block(volume)

        let reloaded = VolumeBlockStore(defaults: defaults)
        XCTAssertTrue(reloaded.isBlocked(volume.compositeID))
        XCTAssertEqual(reloaded.blocked.first?.name, "Dock-SSD")
    }

    func testBlockIsIdempotent() {
        let store = VolumeBlockStore(defaults: makeDefaults())
        let volume = makeVolume()
        store.block(volume)
        store.block(volume)
        XCTAssertEqual(store.blocked.count, 1)
    }

    func testUnblockRemoves() {
        let defaults = makeDefaults()
        let volume = makeVolume()
        let store = VolumeBlockStore(defaults: defaults)
        store.block(volume)
        store.unblock(volume.compositeID)

        XCTAssertFalse(store.isBlocked(volume.compositeID))
        XCTAssertTrue(VolumeBlockStore(defaults: defaults).blocked.isEmpty)
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter VolumeBlockStoreTests`
Expected: FAIL to build — `VolumeBlockStore` / `BlockedVolume` not defined.

- [ ] **Step 3: Write the implementation**

Create `Sources/WSCore/VolumeBlockStore.swift`:

```swift
import Combine
import Foundation

public struct BlockedVolume: Codable, Identifiable, Equatable {
    public let compositeID: String
    public let name: String
    public var id: String { compositeID }

    public init(compositeID: String, name: String) {
        self.compositeID = compositeID
        self.name = name
    }
}

/// Persists which external volumes are blocked from auto-mounting. Backed by
/// `UserDefaults`, injected so tests can use an isolated suite instead of the
/// app's real preferences.
public final class VolumeBlockStore: ObservableObject {
    @Published public private(set) var blocked: [BlockedVolume]

    private let defaults: UserDefaults
    private static let key = "wsmonitor_blockedVolumes_v1"

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: Self.key),
           let decoded = try? JSONDecoder().decode([BlockedVolume].self, from: data) {
            self.blocked = decoded
        } else {
            self.blocked = []
        }
    }

    public func isBlocked(_ compositeID: String) -> Bool {
        blocked.contains { $0.compositeID == compositeID }
    }

    public func block(_ volume: ExternalVolume) {
        guard !isBlocked(volume.compositeID) else { return }
        blocked.append(BlockedVolume(compositeID: volume.compositeID, name: volume.name))
        save()
    }

    public func unblock(_ compositeID: String) {
        blocked.removeAll { $0.compositeID == compositeID }
        save()
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(blocked) else { return }
        defaults.set(data, forKey: Self.key)
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter VolumeBlockStoreTests`
Expected: PASS (4 tests)

- [ ] **Step 5: Commit**

```bash
cd ~/WSMonitor
git add Sources/WSCore/VolumeBlockStore.swift Tests/WSCoreTests/VolumeBlockStoreTests.swift
git commit -m "feat: add UserDefaults-backed volume block-list store"
```

---

### Task 4: `VolumeAutoMountBlocker` (DiskArbitration enforcement)

**Files:**
- Create: `Sources/WSMonitor/VolumeAutoMountBlocker.swift`
- Modify: `Package.swift` (only if the build fails to link DiskArbitration — see Step 3)

**Interfaces:**
- Consumes: `VolumeBlockStore` (Task 3) — reads `$blocked` via Combine.
- Produces: `final class VolumeAutoMountBlocker { init(store: VolumeBlockStore) }` — no other public API; it's a fire-and-forget background enforcer owned by `AppController` (Task 5).

Not unit-tested — a live DiskArbitration callback registered with the system daemon, same as MountMate's equivalent `DiskMounter` is left untested. Verified manually in Task 5's manual-test step.

- [ ] **Step 1: Write the implementation**

Create `Sources/WSMonitor/VolumeAutoMountBlocker.swift`:

```swift
import Combine
import DiskArbitration
import Foundation
import WSCore

/// Dissents automatic OS mounts for volumes present in a `VolumeBlockStore`,
/// via a DiskArbitration mount-approval callback. Started once at app
/// launch and lives for the whole run, independent of Settings window
/// visibility — a docking station can connect anytime.
///
/// Unlike MountMate's equivalent `DiskMounter`, there is no "approve this one
/// manual mount" grace window: Imperum Tool has no mount button to whitelist
/// against, so to mount a blocked volume the user unblocks it first (in
/// Settings), then mounts it normally (Finder / Disk Utility / reconnect).
final class VolumeAutoMountBlocker {
    private var session: DASession?
    private var blockedIDs: Set<String> = []
    private var cancellable: AnyCancellable?

    init(store: VolumeBlockStore) {
        blockedIDs = Set(store.blocked.map(\.compositeID))
        cancellable = store.$blocked
            .receive(on: DispatchQueue.main)
            .sink { [weak self] blocked in
                self?.blockedIDs = Set(blocked.map(\.compositeID))
            }
        startSession()
    }

    deinit {
        stopSession()
    }

    private func startSession() {
        guard session == nil else { return }
        guard let session = DASessionCreate(kCFAllocatorDefault) else {
            NSLog("Imperum Tool: failed to create DiskArbitration session — auto-mount blocking is inactive until the app restarts.")
            return
        }
        self.session = session

        let callback: DADiskMountApprovalCallback = { (disk, context) -> Unmanaged<DADissenter>? in
            guard let context else { return nil }
            let this = Unmanaged<VolumeAutoMountBlocker>.fromOpaque(context).takeUnretainedValue()

            guard let desc = DADiskCopyDescription(disk) as? [String: Any] else { return nil }

            // Disk images (mounted .dmg files) are never blocked — you mount
            // those by explicitly opening them, so there's no "auto-mount on
            // connect" annoyance to prevent here.
            if let model = desc[kDADiskDescriptionDeviceModelKey as String] as? String, model == "Disk Image" {
                return nil
            }

            guard let rawVolumeUUID = desc[kDADiskDescriptionVolumeUUIDKey as String] as CFTypeRef?,
                  CFGetTypeID(rawVolumeUUID) == CFUUIDGetTypeID()
            else { return nil }
            let volumeUUID = CFUUIDCreateString(nil, (rawVolumeUUID as! CFUUID)) as String

            let diskUUID: String
            if let rawDiskUUID = desc[kDADiskDescriptionMediaUUIDKey as String] as CFTypeRef?,
               CFGetTypeID(rawDiskUUID) == CFUUIDGetTypeID() {
                diskUUID = CFUUIDCreateString(nil, (rawDiskUUID as! CFUUID)) as String
            } else {
                diskUUID = "NONE"
            }

            let compositeID = "\(diskUUID)-\(volumeUUID)"
            guard this.blockedIDs.contains(compositeID) else { return nil }

            NSLog("Imperum Tool: dissenting auto-mount for blocked volume \(compositeID)")
            let dissenter = DADissenterCreate(kCFAllocatorDefault, DAReturn(kDAReturnNotPermitted), nil)
            return Unmanaged.passRetained(dissenter)
        }

        let matching: [String: Any] = [kDADiskDescriptionVolumeMountableKey as String: kCFBooleanTrue!]
        let context = Unmanaged.passUnretained(self).toOpaque()
        DARegisterDiskMountApprovalCallback(session, matching as CFDictionary, callback, context)
        DASessionSetDispatchQueue(session, DispatchQueue.main)
    }

    private func stopSession() {
        guard let session else { return }
        DASessionSetDispatchQueue(session, nil)
        self.session = nil
    }
}
```

- [ ] **Step 2: Build to verify it compiles and links**

Run: `swift build`
Expected: `Build complete!`

- [ ] **Step 3: If linking fails with an undefined-symbol/framework error**

Read `Package.swift`, find the `.executableTarget(name: "WSMonitor", ...)` entry, and add:

```swift
        .executableTarget(
            name: "WSMonitor",
            dependencies: ["WSCore"],
            linkerSettings: [.linkedFramework("DiskArbitration")]
        ),
```

Then re-run `swift build` and confirm `Build complete!`.

- [ ] **Step 4: Commit**

```bash
cd ~/WSMonitor
git add Sources/WSMonitor/VolumeAutoMountBlocker.swift
# also `git add Package.swift` here if Step 3's change was needed
git commit -m "feat: add DiskArbitration auto-mount blocker"
```

---

### Task 5: Wire the blocker into `AppController`

**Files:**
- Modify: `Sources/WSMonitor/AppController.swift`

**Interfaces:**
- Consumes: `VolumeBlockStore()` (Task 3), `VolumeAutoMountBlocker(store:)` (Task 4)
- Produces: `AppController.volumeBlockStore: VolumeBlockStore` (a new property Task 6's Settings section will read via the `SettingsView` initializer)

- [ ] **Step 1: Add the store and blocker as owned properties**

In `Sources/WSMonitor/AppController.swift`, add two properties alongside the existing ones (near `private let config = AppConfig()`, around line 11):

```swift
    private let config = AppConfig()
    private let volumeBlockStore = VolumeBlockStore()
    private lazy var volumeAutoMountBlocker = VolumeAutoMountBlocker(store: volumeBlockStore)
```

- [ ] **Step 2: Force the blocker to start at launch, not on first Settings open**

`lazy var` only evaluates on first access. In `start()` (the existing method that already does `buildMainMenu()`, `makeWindow()`, etc.), add a line that forces evaluation immediately:

```swift
    func start() {
        model.onPause = { [weak self] pid, name in self?.pauseSuspect(pid: pid, name: name) }
        model.onToggleHelper = { [weak self] in self?.toggleHelper() }
        model.onOpenSettings = { [weak self] in self?.showSettings() }
        config.onChange = { [weak self] in self?.applyConfig() }
        spikes.config = config.spikeConfig
        _ = volumeAutoMountBlocker   // force the DiskArbitration session to start now, not on first Settings open
        buildMainMenu()
        statusItem.button?.action = #selector(toggleWindow)
        statusItem.button?.target = self
        makeWindow()
        tick()
        startTimer()
        showWindow()   // show on launch so there is always a visible UI
    }
```

- [ ] **Step 3: Pass the store into `SettingsView`**

Find `showSettings()` (around line 77) and update the `SettingsView` construction to pass `volumeBlockStore` (the view itself gains this parameter in Task 6):

```swift
    @objc private func showSettings() {
        if settingsWindow == nil {
            let host = NSHostingController(rootView: SettingsView(config: config, blockStore: volumeBlockStore))
            let win = NSWindow(contentViewController: host)
            win.title = "Imperum Tool Settings"
            win.styleMask = [.titled, .closable]
            win.isReleasedWhenClosed = false
            win.center()
            settingsWindow = win
        }
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
    }
```

- [ ] **Step 4: Build to verify it compiles**

Run: `swift build`
Expected: Build FAILS at this point — `SettingsView(config:blockStore:)` doesn't exist yet. That's expected; Task 6 adds the `blockStore` parameter. Confirm the failure is specifically about the missing `blockStore:` argument in `SettingsView`'s initializer, and not some other error, before moving on.

- [ ] **Step 5: Commit**

```bash
cd ~/WSMonitor
git add Sources/WSMonitor/AppController.swift
git commit -m "feat: start volume auto-mount blocker at app launch"
```

---

### Task 6: "External Volumes" Settings section

**Files:**
- Create: `Sources/WSMonitor/ExternalVolumesSettingsSection.swift`
- Modify: `Sources/WSMonitor/Settings.swift`

**Interfaces:**
- Consumes: `VolumeBlockStore` (Task 3), `ExternalVolume` + `fetchExternalVolumes()` (Tasks 1–2)
- Produces: `struct ExternalVolumesSettingsSection: View { @ObservedObject var blockStore: VolumeBlockStore }`, and `SettingsView`'s initializer becomes `SettingsView(config: AppConfig, blockStore: VolumeBlockStore)`

- [ ] **Step 1: Create the new section view**

Create `Sources/WSMonitor/ExternalVolumesSettingsSection.swift`:

```swift
import SwiftUI
import WSCore

/// Settings section listing currently-connected external volumes with a
/// block-auto-mount toggle each, plus any blocked volumes that aren't
/// currently connected (so they remain manageable/removable).
struct ExternalVolumesSettingsSection: View {
    @ObservedObject var blockStore: VolumeBlockStore

    @State private var connected: [ExternalVolume] = []
    @State private var isRefreshing = false
    @State private var refreshWorkItem: DispatchWorkItem?

    private var disconnectedBlocked: [BlockedVolume] {
        blockStore.blocked.filter { blocked in
            !connected.contains { $0.compositeID == blocked.compositeID }
        }
    }

    var body: some View {
        Section("External Volumes") {
            HStack {
                Text("Connected").font(.subheadline).foregroundStyle(.secondary)
                Spacer()
                Button(action: refresh) {
                    if isRefreshing {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: "arrow.clockwise")
                    }
                }
                .buttonStyle(.borderless)
                .disabled(isRefreshing)
            }

            if connected.isEmpty {
                Text(isRefreshing ? "Scanning…" : "No external volumes found.")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                ForEach(connected) { volume in
                    Toggle(volume.name, isOn: Binding(
                        get: { blockStore.isBlocked(volume.compositeID) },
                        set: { isOn in
                            if isOn { blockStore.block(volume) } else { blockStore.unblock(volume.compositeID) }
                        }
                    ))
                }
            }

            if !disconnectedBlocked.isEmpty {
                Text("Blocked (not currently connected)").font(.subheadline).foregroundStyle(.secondary)
                ForEach(disconnectedBlocked) { blocked in
                    HStack {
                        Text(blocked.name)
                        Spacer()
                        Button(role: .destructive) {
                            blockStore.unblock(blocked.compositeID)
                        } label: {
                            Image(systemName: "trash")
                        }
                        .buttonStyle(.borderless)
                    }
                }
            }

            Text("Blocked volumes won't auto-mount when connected. Untoggle here, or use Disk Utility, to mount them.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .onAppear(perform: refresh)
        .onReceive(NotificationCenter.default.publisher(for: NSWorkspace.didMountNotification)) { _ in scheduleRefresh() }
        .onReceive(NotificationCenter.default.publisher(for: NSWorkspace.didUnmountNotification)) { _ in scheduleRefresh() }
    }

    private func refresh() {
        isRefreshing = true
        DispatchQueue.global(qos: .userInitiated).async {
            let volumes = fetchExternalVolumes()
            DispatchQueue.main.async {
                self.connected = volumes
                self.isRefreshing = false
            }
        }
    }

    /// Debounces bursts of mount/unmount notifications (e.g. a
    /// multi-partition dock connecting fires one per volume) into a single
    /// refresh.
    private func scheduleRefresh() {
        refreshWorkItem?.cancel()
        let work = DispatchWorkItem(block: refresh)
        refreshWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0, execute: work)
    }
}
```

- [ ] **Step 2: Wire it into `SettingsView`**

In `Sources/WSMonitor/Settings.swift`, change the `SettingsView` struct (it currently starts with `struct SettingsView: View { @ObservedObject var config: AppConfig ...`) to accept and render the new section:

```swift
struct SettingsView: View {
    @ObservedObject var config: AppConfig
    @ObservedObject var blockStore: VolumeBlockStore

    var body: some View {
        Form {
            Section("General") {
                Toggle("Launch at login", isOn: $config.launchAtLogin)
                if config.loginNeedsApproval {
                    HStack(alignment: .top, spacing: 6) {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                        VStack(alignment: .leading, spacing: 4) {
                            Text("macOS needs you to approve this. Enable “Imperum Tool” under Allow in the Background / Open at Login.")
                                .font(.caption)
                            Button("Open Login Items settings…") { config.openLoginItemsSettings() }
                                .controlSize(.small)
                        }
                    }
                } else {
                    Text("Start Imperum Tool automatically when you log in.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }

            Section("Sampling") {
                Stepper(value: $config.intervalSeconds, in: 2...30, step: 1) {
                    Text("Refresh every \(Int(config.intervalSeconds)) s")
                }
                Text("How often WindowServer, displays and processes are sampled. Lower = more responsive, slightly more overhead.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Spike thresholds") {
                Stepper(value: $config.cpuThreshold, in: 20...100, step: 5) {
                    Text("Flag when WindowServer CPU > \(Int(config.cpuThreshold))%")
                }
                Stepper(value: $config.gpuThreshold, in: 20...100, step: 5) {
                    Text("Flag when global GPU > \(Int(config.gpuThreshold))%")
                }
                Text("Crossing either threshold turns the menu-bar gauge red and records a spike.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            ExternalVolumesSettingsSection(blockStore: blockStore)

            Section("About") {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 10) {
                        Image(systemName: "gauge.with.dots.needle.bottom.50percent")
                            .font(.system(size: 26)).foregroundStyle(.tint)
                        VStack(alignment: .leading, spacing: 1) {
                            Text("Imperum Tool").font(.headline)
                            Text("Version \(appVersionString())").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    Text("Finds which app is driving WindowServer CPU / RAM / GPU spikes — sudoless detection, live correlation, a pause-and-test causation check, and (optionally) powermetrics Energy Impact.")
                        .font(.caption).foregroundStyle(.secondary)
                    Text("Per-app GPU% isn't exposed on Apple Silicon; Imperum Tool works around that with proxy ranking and causation tests.")
                        .font(.caption2).foregroundStyle(.secondary)
                    Text("Developer ID: Imperum B.V.")
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 440, height: 560)
        .onAppear { config.refreshLoginStatus() }
    }
}
```

(This replaces the existing `SettingsView` body 1:1 — same content, plus the `blockStore` property and the `ExternalVolumesSettingsSection(blockStore: blockStore)` line inserted between "Spike thresholds" and "About".)

- [ ] **Step 3: Build to verify everything compiles**

Run: `swift build`
Expected: `Build complete!`

- [ ] **Step 4: Run the full test suite**

Run: `swift test`
Expected: All tests pass (the pre-existing ~30 plus this plan's 9 new ones).

- [ ] **Step 5: Manual verification**

Run: `swift run WSMonitor`
Then:
1. Open Settings (⌘,) and confirm the new "External Volumes" section appears between "Spike thresholds" and "About", listing your currently-connected external volumes (if any are attached).
2. Toggle "Block" on a connected volume, quit the app, disconnect and reconnect that volume, and confirm Finder does *not* auto-mount it.
3. Reopen Settings and confirm the volume still shows as blocked (now under "Blocked (not currently connected)" if it's not currently connected, or still toggled on if it is).
4. Untoggle it (or use Disk Utility to mount it directly) and confirm it mounts normally.
5. Quit the app (⌘Q) to stop the background monitor.

- [ ] **Step 6: Commit**

```bash
cd ~/WSMonitor
git add Sources/WSMonitor/ExternalVolumesSettingsSection.swift Sources/WSMonitor/Settings.swift
git commit -m "feat: add External Volumes settings section for auto-mount blocking"
```
