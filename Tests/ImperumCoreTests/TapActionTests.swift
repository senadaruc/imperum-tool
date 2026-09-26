import XCTest
@testable import ImperumCore

final class TapActionTests: XCTestCase {
    func testCatalogHasFiftyPlusRealActions() {
        let real = TapAction.Kind.allCases.filter { $0 != .none }
        XCTAssertGreaterThanOrEqual(real.count, 50)
    }

    func testEveryKindHasNameAndCategoryAndUniqueName() {
        var names = Set<String>()
        for k in TapAction.Kind.allCases {
            XCTAssertFalse(k.displayName.isEmpty, "\(k)")
            XCTAssertTrue(names.insert(k.displayName).inserted, "duplicate name \(k.displayName)")
            XCTAssertTrue(ActionCategory.allCases.contains(k.category))
        }
    }

    func testCategoriesCoverAllKinds() {
        let covered = ActionCategory.allCases.flatMap { TapAction.Kind.inCategory($0) }
        XCTAssertEqual(Set(covered), Set(TapAction.Kind.allCases))
    }

    func testParameterisedSummaries() {
        XCTAssertEqual(TapAction(.pressShortcut).summary, "Press keyboard shortcut (not set)")
        XCTAssertFalse(TapAction(.pressShortcut).isConfigured)
        let combo = KeyCombo(keyCode: 8, modifiers: 1 << 20, display: "⌘C")
        XCTAssertEqual(TapAction(.pressShortcut, keyCombo: combo).summary, "Press ⌘C")
        XCTAssertEqual(TapAction(.openApplication, text: "/Applications/Safari.app").summary, "Open Safari")
        XCTAssertEqual(TapAction(.runShortcut, text: "Log water").summary, "Run Shortcut “Log water”")
        XCTAssertTrue(TapAction(.muteSound).isConfigured)
    }

    func testMapRoundTrip() throws {
        var map = TapMap.productDefault
        map[TapSlot(.right, 1)] = TapAction(.runShortcut, text: "Focus")
        map[TapSlot(.left, 3)] = TapAction(.pressShortcut, keyCombo: KeyCombo(keyCode: 49, modifiers: 1 << 20, display: "⌘Space"))
        let data = try JSONEncoder().encode(map)
        let back = try JSONDecoder().decode(TapMap.self, from: data)
        XCTAssertEqual(back, map)
        XCTAssertEqual(back.action(side: .left, count: 3).keyCombo?.display, "⌘Space")
    }

    func testDefaultMapMatchesProductPage() {
        let m = TapMap.productDefault
        XCTAssertEqual(m.action(side: .left, count: 1).kind, .muteSound)
        XCTAssertEqual(m.action(side: .left, count: 2).kind, .screenshotClipboard)
        XCTAssertEqual(m.action(side: .left, count: 3).kind, .flashlight)
        XCTAssertEqual(m.action(side: .right, count: 1).kind, .runShortcut)
        XCTAssertEqual(m.action(side: .right, count: 2).kind, .playPause)
        XCTAssertEqual(m.action(side: .right, count: 3).kind, .nextTrack)
        XCTAssertEqual(TapSlot.allCases.count, 6)
    }

    func testMissingSlotIsNone() {
        XCTAssertEqual(TapMap().action(side: .left, count: 2).kind, .none)
    }

    func testShowCopyStackActionExists() {
        let k = TapAction.Kind.showCopyStack
        XCTAssertEqual(k.displayName, "Show Copy Stack")
        XCTAssertEqual(k.category, .screenshotsClipboard)
        if case .none = k.parameter {} else { XCTFail("no parameter expected") }
        XCTAssertTrue(TapAction.Kind.inCategory(.screenshotsClipboard).contains(.showCopyStack))
    }
}

final class TapSettingsStoreTests: XCTestCase {
    private func isolatedDefaults() -> UserDefaults {
        let name = "TapSettingsStoreTests-\(UUID().uuidString)"
        let d = UserDefaults(suiteName: name)!
        d.removePersistentDomain(forName: name)
        return d
    }

    func testDefaultsWhenEmpty() {
        let s = TapSettingsStore(defaults: isolatedDefaults())
        XCTAssertFalse(s.settings.enabled)
        XCTAssertEqual(s.settings.map, .productDefault)
        XCTAssertNil(s.settings.calibration)
    }

    func testPersistsAcrossInstances() {
        let d = isolatedDefaults()
        let a = TapSettingsStore(defaults: d)
        a.settings.enabled = true
        a.settings.threshold = 0.1
        a.settings.calibration = SideCalibration(feature: .accelX, leftIsPositive: false, boundary: 0.01, separation: 3)
        a.settings.map[TapSlot(.left, 1)] = TapAction(.openURL, text: "https://imperum.io")
        let b = TapSettingsStore(defaults: d)
        XCTAssertEqual(b.settings, a.settings)
    }
}
