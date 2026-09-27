import XCTest
@testable import ImperumCore

final class ClipboardSettingsTests: XCTestCase {
    private func isolatedDefaults() -> UserDefaults {
        let name = "ClipboardSettingsTests.\(UUID().uuidString)"
        let d = UserDefaults(suiteName: name)!
        d.removePersistentDomain(forName: name)
        return d
    }

    func testDefaultsMatchSpec() {
        let s = ClipboardSettings()
        XCTAssertTrue(s.enabled)
        XCTAssertEqual(s.trigger, .doubleTap)
        XCTAssertEqual(s.doubleTapMs, 300)
        XCTAssertEqual(s.maxStack, 500)
        XCTAssertEqual(s.retentionDays, 30)
        XCTAssertFalse(s.clearOnQuit)
        XCTAssertTrue(s.showBadge)
        XCTAssertFalse(s.showFavicons)
        XCTAssertFalse(s.paused)
        XCTAssertTrue(s.terminalPicker)
        XCTAssertTrue(s.allowCLI)
        XCTAssertEqual(s.cmuxSocketPassword, "")
        XCTAssertEqual(s.excludedBundleIDs, ["com.1password.1password", "com.agilebits.onepassword7",
                                             "com.bitwarden.desktop", "com.apple.keychainaccess"])
        XCTAssertEqual(s.excludedHosts, [])
        XCTAssertEqual(s.limits, ClipLimits(maxStack: 500, retentionDays: 30))
    }

    func testStorePersistsAndReloads() {
        let d = isolatedDefaults()
        let store = ClipboardSettingsStore(defaults: d)
        store.settings.maxStack = 42
        store.settings.trigger = .both
        let again = ClipboardSettingsStore(defaults: d)
        XCTAssertEqual(again.settings.maxStack, 42)
        XCTAssertEqual(again.settings.trigger, .both)
    }

    func testDecodingOlderJSONWithMissingKeysUsesDefaults() throws {
        let json = #"{"enabled":false,"maxStack":99}"#.data(using: .utf8)!
        let s = try JSONDecoder().decode(ClipboardSettings.self, from: json)
        XCTAssertFalse(s.enabled)
        XCTAssertEqual(s.maxStack, 99)
        XCTAssertEqual(s.retentionDays, 30)
        XCTAssertEqual(s.trigger, .doubleTap)
        XCTAssertTrue(s.terminalPicker)
        XCTAssertTrue(s.allowCLI)
        XCTAssertEqual(s.cmuxSocketPassword, "")
        XCTAssertEqual(s.excludedHosts, [])
    }

    func testTerminalPickerAndAllowCLIRoundTrip() throws {
        var s = ClipboardSettings()
        s.terminalPicker = false
        s.allowCLI = false
        s.cmuxSocketPassword = "s3cret"
        s.excludedHosts = ["mybank.com"]
        let data = try JSONEncoder().encode(s)
        let decoded = try JSONDecoder().decode(ClipboardSettings.self, from: data)
        XCTAssertFalse(decoded.terminalPicker)
        XCTAssertFalse(decoded.allowCLI)
        XCTAssertEqual(decoded.cmuxSocketPassword, "s3cret")
        XCTAssertEqual(decoded.excludedHosts, ["mybank.com"])
    }

    func testClampsOutOfRangeValues() {
        var s = ClipboardSettings()
        s.doubleTapMs = 10;  XCTAssertEqual(s.doubleTapMs, 200)
        s.doubleTapMs = 900; XCTAssertEqual(s.doubleTapMs, 400)
        s.maxStack = 1;      XCTAssertEqual(s.maxStack, 20)
        s.maxStack = 9999;   XCTAssertEqual(s.maxStack, 2000)
        s.retentionDays = 0; XCTAssertEqual(s.retentionDays, 1)
        s.retentionDays = 999; XCTAssertEqual(s.retentionDays, 365)
    }

    // MARK: Per-category limits

    func testCategoryLimitsClampAndDropInvalidKeys() {
        var s = ClipboardSettings()
        s.categoryLimits = ["images": 5, "links": 9999, "all": 50, "bogus": 30]
        XCTAssertEqual(s.categoryLimits, ["images": 10, "links": 2000])
        XCTAssertEqual(s.limits.perCategory, [.images: 10, .links: 2000])
        XCTAssertEqual(ClipboardSettings.categoryLimitRange, 10...2000)
        XCTAssertEqual(ClipboardSettings.categoryLimitDefault, 100)
    }

    func testCategoryLimitsAbsentFromOlderJSONMeansOff() throws {
        let json = #"{"enabled":true}"#.data(using: .utf8)!
        let s = try JSONDecoder().decode(ClipboardSettings.self, from: json)
        XCTAssertEqual(s.categoryLimits, [:])
        XCTAssertEqual(s.limits.perCategory, [:])
    }

    func testCategoryLimitsRoundTripAndSanitizeOnDecode() throws {
        var s = ClipboardSettings()
        s.categoryLimits = ["text": 40]
        let data = try JSONEncoder().encode(s)
        XCTAssertEqual(try JSONDecoder().decode(ClipboardSettings.self, from: data).categoryLimits, ["text": 40])
        let hand = #"{"categoryLimits":{"videos":1,"all":7}}"#.data(using: .utf8)!
        XCTAssertEqual(try JSONDecoder().decode(ClipboardSettings.self, from: hand).categoryLimits, ["videos": 10])
    }

    // MARK: Shortcuts

    func testShortcutsDefaultAndDecodeWhenAbsent() throws {
        XCTAssertEqual(ClipboardSettings().shortcuts, .defaults)
        let s = try JSONDecoder().decode(ClipboardSettings.self, from: #"{"maxStack":99}"#.data(using: .utf8)!)
        XCTAssertEqual(s.shortcuts, .defaults)
    }

    func testCorruptShortcutsLeaveOtherSettingsIntact() throws {
        let json = #"{"maxStack":99,"shortcuts":"nonsense","categoryLimits":{"text":40}}"#.data(using: .utf8)!
        let s = try JSONDecoder().decode(ClipboardSettings.self, from: json)
        XCTAssertEqual(s.maxStack, 99)
        XCTAssertEqual(s.categoryLimits, ["text": 40])
        XCTAssertEqual(s.shortcuts, .defaults)
    }

    func testShortcutsRoundTripThroughStore() {
        let d = isolatedDefaults()
        let store = ClipboardSettingsStore(defaults: d)
        store.settings.shortcuts.set(KeyCombo(keyCode: 2, modifiers: PanelShortcuts.command, display: "⌘D"), for: .delete)
        store.settings.shortcuts.quickPickModifiers = PanelShortcuts.command | PanelShortcuts.option
        let again = ClipboardSettingsStore(defaults: d)
        XCTAssertEqual(again.settings.shortcuts.combo(for: .delete), KeyCombo(keyCode: 2, modifiers: PanelShortcuts.command, display: "⌘D"))
        XCTAssertEqual(again.settings.shortcuts.quickPickDisplay, "⌥⌘1–9")
    }
}
