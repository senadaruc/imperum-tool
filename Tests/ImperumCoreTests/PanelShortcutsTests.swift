import XCTest
@testable import ImperumCore

final class PanelShortcutsTests: XCTestCase {
    private let cmd = PanelShortcuts.command, shift = PanelShortcuts.shift, opt = PanelShortcuts.option, ctrl = PanelShortcuts.control
    private let fn: UInt = 1 << 23, numpad: UInt = 1 << 21

    func testModifierBitsMatchNSEvent() {
        XCTAssertEqual(cmd, 1 << 20); XCTAssertEqual(shift, 1 << 17); XCTAssertEqual(opt, 1 << 19); XCTAssertEqual(ctrl, 1 << 18)
        XCTAssertEqual(PanelShortcuts.normalize(cmd | fn | numpad | (1 << 16)), cmd)
    }

    func testDefaultsMatchTodaysKeys() {
        let d = PanelShortcuts.defaults
        XCTAssertEqual(d.combo(for: .openPanel), KeyCombo(keyCode: 9, modifiers: cmd | shift, display: "⌘⇧V"))
        XCTAssertEqual(d.combo(for: .up), KeyCombo(keyCode: 126, modifiers: 0, display: "↑"))
        XCTAssertEqual(d.combo(for: .down), KeyCombo(keyCode: 125, modifiers: 0, display: "↓"))
        XCTAssertEqual(d.combo(for: .previousCategory), KeyCombo(keyCode: 123, modifiers: 0, display: "←"))
        XCTAssertEqual(d.combo(for: .nextCategory), KeyCombo(keyCode: 124, modifiers: 0, display: "→"))
        XCTAssertEqual(d.combo(for: .paste), KeyCombo(keyCode: 36, modifiers: 0, display: "↩"))
        XCTAssertEqual(d.combo(for: .pin), KeyCombo(keyCode: 35, modifiers: cmd, display: "⌘P"))
        XCTAssertEqual(d.combo(for: .delete), KeyCombo(keyCode: 51, modifiers: 0, display: "⌫"))
        XCTAssertEqual(d.combo(for: .close), KeyCombo(keyCode: 53, modifiers: 0, display: "⎋"))
        XCTAssertEqual(d.quickPickModifiers, cmd)
        XCTAssertEqual(d.quickPickDisplay, "⌘1–9")
        XCTAssertTrue(d.conflictingActions.isEmpty)
        XCTAssertEqual(PanelAction.inPanel, [.up, .down, .previousCategory, .nextCategory, .paste, .pin, .delete, .close])
    }

    func testLookupIgnoresFunctionAndNumericPadNoiseOnArrows() {
        let d = PanelShortcuts.defaults
        XCTAssertEqual(d.action(keyCode: 126, modifiers: fn | numpad), .up)
        XCTAssertEqual(d.action(keyCode: 35, modifiers: cmd), .pin)
        XCTAssertNil(d.action(keyCode: 35, modifiers: cmd | shift))
        XCTAssertNil(d.action(keyCode: 126, modifiers: cmd), "⌘↑ is not ↑")
        XCTAssertNil(d.action(keyCode: 9, modifiers: cmd | shift), "openPanel is never an in-panel action")
    }

    func testSetNormalisesModifiersAndFirstActionWinsOnTie() {
        var s = PanelShortcuts.defaults
        s.set(KeyCombo(keyCode: 2, modifiers: cmd | fn, display: "⌘D"), for: .delete)   // 2 = D
        XCTAssertEqual(s.combo(for: .delete), KeyCombo(keyCode: 2, modifiers: cmd, display: "⌘D"))
        s.set(KeyCombo(keyCode: 2, modifiers: cmd, display: "⌘D"), for: .close)
        XCTAssertEqual(s.action(keyCode: 2, modifiers: cmd), .delete, ".delete precedes .close in PanelAction order")
        XCTAssertEqual(s.conflictingActions, [.delete, .close])
        XCTAssertEqual(s.conflicts(for: .delete), ["Close"])
        XCTAssertEqual(s.conflicts(for: .close), ["Delete"])
        XCTAssertEqual(s.conflicts(for: .pin), [])
    }

    func testQuickPickModifiersConflictWithDigitBinding() {
        var s = PanelShortcuts.defaults
        s.set(KeyCombo(keyCode: 18, modifiers: cmd, display: "⌘1"), for: .pin)   // 18 = "1"
        XCTAssertEqual(s.conflicts(for: .pin), ["Quick pick"])
        XCTAssertEqual(s.conflictingActions, [.pin])
        s.quickPickModifiers = cmd | opt | fn
        XCTAssertEqual(s.quickPickModifiers, cmd | opt)
        XCTAssertTrue(s.conflictingActions.isEmpty)
        XCTAssertEqual(s.quickPickDisplay, "⌥⌘1–9")
        XCTAssertEqual(PanelShortcuts.modifierGlyphs(ctrl | opt | shift | cmd), "⌃⌥⇧⌘")
    }

    func testProblems() {
        XCTAssertEqual(PanelShortcuts.problem(with: KeyCombo(keyCode: 9, modifiers: 0, display: "V"), for: .openPanel), .hotkeyNeedsModifier)
        XCTAssertEqual(PanelShortcuts.problem(with: KeyCombo(keyCode: 9, modifiers: shift, display: "⇧V"), for: .openPanel), .hotkeyNeedsModifier)
        XCTAssertNil(PanelShortcuts.problem(with: KeyCombo(keyCode: 9, modifiers: ctrl, display: "⌃V"), for: .openPanel))
        XCTAssertNil(PanelShortcuts.problem(with: KeyCombo(keyCode: 105, modifiers: 0, display: "F13"), for: .openPanel))
        XCTAssertEqual(PanelShortcuts.problem(with: KeyCombo(keyCode: 35, modifiers: 0, display: "P"), for: .pin), .printableNeedsModifier)
        XCTAssertEqual(PanelShortcuts.problem(with: KeyCombo(keyCode: 49, modifiers: 0, display: "Space"), for: .paste), .printableNeedsModifier)
        XCTAssertEqual(PanelShortcuts.problem(with: KeyCombo(keyCode: 35, modifiers: shift, display: "⇧P"), for: .pin), .printableNeedsModifier)
        XCTAssertNil(PanelShortcuts.problem(with: KeyCombo(keyCode: 117, modifiers: 0, display: "⌦"), for: .delete))
        XCTAssertNil(PanelShortcuts.problem(with: KeyCombo(keyCode: 48, modifiers: 0, display: "⇥"), for: .nextCategory))
        XCTAssertNil(PanelShortcuts.problem(with: KeyCombo(keyCode: 122, modifiers: 0, display: "F1"), for: .close))
        XCTAssertNil(PanelShortcuts.problem(with: KeyCombo(keyCode: 2, modifiers: cmd, display: "⌘D"), for: .delete))
        XCTAssertEqual(ShortcutProblem.hotkeyNeedsModifier.message, "Use ⌘, ⌃ or ⌥, or a function key")
        XCTAssertEqual(ShortcutProblem.printableNeedsModifier.message, "Add ⌘, ⌃ or ⌥ so typing in search still works")
    }

    func testDeleteYieldsToSearchFieldOnlyForBareDeleteKeys() {
        var s = PanelShortcuts.defaults
        XCTAssertTrue(s.deleteYieldsToSearchField(queryEmpty: false))
        XCTAssertFalse(s.deleteYieldsToSearchField(queryEmpty: true))
        s.set(KeyCombo(keyCode: 117, modifiers: 0, display: "⌦"), for: .delete)
        XCTAssertTrue(s.deleteYieldsToSearchField(queryEmpty: false))
        s.set(KeyCombo(keyCode: 2, modifiers: cmd, display: "⌘D"), for: .delete)
        XCTAssertFalse(s.deleteYieldsToSearchField(queryEmpty: false))
        s.set(KeyCombo(keyCode: 51, modifiers: cmd, display: "⌘⌫"), for: .delete)
        XCTAssertFalse(s.deleteYieldsToSearchField(queryEmpty: false))
    }

    func testCodableRoundTripAndLenientDecoding() throws {
        var s = PanelShortcuts.defaults
        s.set(KeyCombo(keyCode: 2, modifiers: cmd, display: "⌘D"), for: .delete)
        s.quickPickModifiers = cmd | opt
        let data = try JSONEncoder().encode(s)
        XCTAssertEqual(try JSONDecoder().decode(PanelShortcuts.self, from: data), s)

        let json = """
        {"bindings":{"pin":{"keyCode":35,"modifiers":0,"display":"P"},
                     "close":{"keyCode":"junk"},
                     "bogus":{"keyCode":1,"modifiers":0,"display":"S"},
                     "paste":{"keyCode":76,"modifiers":\(fn | numpad),"display":"⌤"}},
         "quickPickModifiers":0}
        """.data(using: .utf8)!
        let d = try JSONDecoder().decode(PanelShortcuts.self, from: json)
        XCTAssertEqual(d.combo(for: .pin), PanelShortcuts.defaults.combo(for: .pin), "invalid combo → default")
        XCTAssertEqual(d.combo(for: .close), PanelShortcuts.defaults.combo(for: .close), "garbage entry → default")
        XCTAssertEqual(d.combo(for: .paste), KeyCombo(keyCode: 76, modifiers: 0, display: "⌤"), "normalised on decode")
        XCTAssertEqual(d.combo(for: .up), PanelShortcuts.defaults.combo(for: .up), "missing → default")
        XCTAssertEqual(d.quickPickModifiers, cmd, "empty quick-pick modifiers → default")
        XCTAssertEqual(try JSONDecoder().decode(PanelShortcuts.self, from: "{}".data(using: .utf8)!), .defaults)
    }

    func testHotkeyRegistrationMessage() {
        XCTAssertNil(PanelShortcuts.hotkeyRegistrationMessage(status: 0))
        XCTAssertEqual(PanelShortcuts.hotkeyRegistrationMessage(status: -9878), "Already used by another app")
        XCTAssertEqual(PanelShortcuts.hotkeyRegistrationMessage(status: -50), "Could not register (error -50)")
    }

    func testQuickPickDigitResolvesByKeyCodeIgnoringShiftAndNoise() {
        var s = PanelShortcuts.defaults
        XCTAssertEqual(s.quickPickDigit(keyCode: 19, modifiers: cmd), 2)            // 19 = "2"
        XCTAssertEqual(s.quickPickDigit(keyCode: 18, modifiers: cmd | fn | numpad), 1)
        XCTAssertNil(s.quickPickDigit(keyCode: 19, modifiers: cmd | shift), "modifiers must match exactly")
        XCTAssertNil(s.quickPickDigit(keyCode: 2, modifiers: cmd), "D is not a digit")
        XCTAssertNil(s.quickPickDigit(keyCode: 29, modifiers: cmd), "0 is not a quick-pick digit")   // 29 = "0"
        s.quickPickModifiers = cmd | shift
        XCTAssertEqual(s.quickPickDigit(keyCode: 19, modifiers: cmd | shift), 2, "⇧ in the modifiers must not break the lookup")
        XCTAssertNil(s.quickPickDigit(keyCode: 19, modifiers: cmd))
    }

    func testQuickPickModifiersNeedARealModifier() {
        XCTAssertEqual(PanelShortcuts.quickPickProblem(modifiers: 0), .printableNeedsModifier)
        XCTAssertEqual(PanelShortcuts.quickPickProblem(modifiers: shift), .printableNeedsModifier)
        XCTAssertNil(PanelShortcuts.quickPickProblem(modifiers: cmd | shift))
        XCTAssertNil(PanelShortcuts.quickPickProblem(modifiers: opt | fn))
        let json = #"{"quickPickModifiers":\#(shift)}"#.data(using: .utf8)!
        XCTAssertEqual(try? JSONDecoder().decode(PanelShortcuts.self, from: json).quickPickModifiers, cmd, "⇧-only on decode → default")
    }
}
