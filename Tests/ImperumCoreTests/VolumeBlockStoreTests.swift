import XCTest
@testable import ImperumCore

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
