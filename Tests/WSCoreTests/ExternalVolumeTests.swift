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

    func testResolvesAPFSContainerVolumesRegardlessOfListingOrder() {
        // Same fixture as testResolvesAPFSContainerVolumesWithoutDuplicates,
        // but with disk9 (the container) listed BEFORE disk8 (its parent) in
        // "AllDisksAndPartitions". Correctness must not depend on which
        // entry AllDisksAndPartitions happens to list first: without the
        // order-independent exclusion, the disk9-processed-as-its-own-root
        // entry (with diskUUID defaulting to "NONE") would win the trailing
        // dedup instead of the correctly-resolved disk8-parented entry.
        let list: [String: Any] = ["AllDisksAndPartitions": [
            ["DeviceIdentifier": "disk9",
             "APFSPhysicalStores": [["DeviceIdentifier": "disk8s2"]],
             "APFSVolumes": [
                ["DeviceIdentifier": "disk9s1", "Content": "APFS",
                 "VolumeName": "Dock-SSD", "VolumeUUID": "UUID-DOCKSSD"]
             ]],
            ["DeviceIdentifier": "disk8", "Partitions": [
                ["DeviceIdentifier": "disk8s1", "Content": "EFI", "VolumeName": "EFI"],
                ["DeviceIdentifier": "disk8s2", "Content": "Apple_APFS"],
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
