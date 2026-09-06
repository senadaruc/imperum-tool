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
/// Pure and synchronous — call `fetchExternalVolumes()` (ImperumCore's thin
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

    // Container disks (e.g. disk9) are resolved via their parent's
    // Apple_APFS partition below; they must be excluded from independent
    // root-disk processing here, since their own identifier is never
    // inside anyone's "Partitions" array (only their underlying store's
    // identifier is), so the childDeviceIDs filter above doesn't catch
    // them. This is a positive, order-independent exclusion — it does not
    // depend on which entry `AllDisksAndPartitions` happens to list first.
    var containerIdentifiersResolvedViaPartition = Set<String>()
    for diskData in rootDisks {
        guard let partitions = diskData["Partitions"] as? [[String: Any]] else { continue }
        for partitionData in partitions where partitionData["Content"] as? String == "Apple_APFS" {
            let storeID = partitionData["DeviceIdentifier"] as? String ?? ""
            if let containerData = findAPFSContainer(forStore: storeID),
               let containerID = containerData["DeviceIdentifier"] as? String {
                containerIdentifiersResolvedViaPartition.insert(containerID)
            }
        }
    }

    var results: [ExternalVolume] = []

    for diskData in rootDisks {
        guard let physicalIdentifier = diskData["DeviceIdentifier"] as? String else { continue }
        if containerIdentifiersResolvedViaPartition.contains(physicalIdentifier) { continue }
        let diskInfo = parsedInfo(for: physicalIdentifier)
        if isRAIDMember(diskInfo) { continue }
        if (diskInfo?["Internal"] as? Bool) ?? false { continue }
        let isVirtual = (diskInfo?["VirtualOrPhysical"] as? String) == "Virtual"
        if isVirtual && !isRAIDMaster(diskInfo) { continue } // disk image

        let busProtocol = diskInfo?["BusProtocol"] as? String

        func appendVolume(_ volumeData: [String: Any]) {
            guard let deviceIdentifier = volumeData["DeviceIdentifier"] as? String else { return }
            let contentType = volumeData["Content"] as? String
            if contentType == "Apple_RAID" || contentType == "Apple_RAID_Offline" { return }
            // Read per-volume, not from the whole-disk `diskInfo` above: this
            // must match VolumeAutoMountBlocker's DA callback, which reads
            // kDADiskDescriptionMediaUUIDKey from the specific mounting
            // volume's own DA description — a per-volume value, not a
            // per-physical-disk one. (busProtocol above is genuinely a
            // whole-disk property, correctly shared across all its volumes.)
            let volumeDiskUUID = volumeData["DiskUUID"] as? String
            let volumeUUID = volumeData["VolumeUUID"] as? String ?? deviceIdentifier
            let volumeName = volumeData["VolumeName"] as? String ?? contentType ?? deviceIdentifier
            results.append(ExternalVolume(
                name: volumeName, deviceIdentifier: deviceIdentifier,
                diskUUID: volumeDiskUUID, volumeUUID: volumeUUID, busProtocol: busProtocol))
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

    // Defensive backstop only: the containerIdentifiersResolvedViaPartition
    // exclusion above already prevents container disks from being
    // double-processed, order-independently. This trailing dedup no longer
    // carries the correctness burden — it just guards against any other
    // unforeseen source of duplicate device identifiers.
    var seenDeviceIDs = Set<String>()
    return results.filter { seenDeviceIDs.insert($0.deviceIdentifier).inserted }
}
