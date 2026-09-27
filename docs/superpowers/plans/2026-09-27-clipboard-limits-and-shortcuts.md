# Clipboard Per-Category Limits and Configurable Shortcuts Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let the user cap each clip category separately (oldest unpinned clips auto-dropped) and rebind the open-panel hotkey and every in-panel key from Settings › Clipboard.

**Architecture:** Pure, testable logic goes in `ImperumCore` (`ClipLimits.perCategory`, `ClipStore.enforce`, a new `PanelShortcuts` value), AppKit glue in `ImperumTool` (`CmdVTap` registers the recorded hotkey, `CopyStackPanel.route` consults the map, the settings tab edits both). Part A (Tasks 1–3) ships on its own; Part B (Tasks 4–8) builds on the same settings store. Task 9 is docs.

**Tech Stack:** Swift 5 language mode, SwiftPM, SwiftUI + AppKit, Carbon `RegisterEventHotKey`, XCTest.

**Spec:** `docs/superpowers/specs/2026-09-27-clipboard-limits-and-shortcuts-design.md`

## Global Constraints

- Platform floor `macOS 14` (`Package.swift`); `swift-tools-version: 5.9`; Swift 5 language mode.
- **Build and test only with the Xcode toolchain.** `xcode-select` on this Mac points at Command Line Tools, which lack XCTest and the SwiftUI macro plugin. Every `swift build` / `swift test` in this plan is prefixed with `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`.
- Baseline before Task 1: 158 ImperumCore + 264 CopyStackKit tests pass.
- Pure logic in `ImperumCore` (no AppKit import); AppKit only in `ImperumTool`.
- The terminal picker (`copystack`, `CopyStackKit`) is **not** touched.
- Modifier bits are raw `NSEvent.ModifierFlags`: ⌘ `1 << 20`, ⇧ `1 << 17`, ⌥ `1 << 19`, ⌃ `1 << 18`. Bindings store and compare only these four.
- Category-cap range `10…2000`, on-default `100`; a category absent from the dictionary has no cap; `ClipCategory.all` is never a key.
- Commit messages: `feat(clipboard): …` / `docs(clipboard): …`, each ending with
  ```
  Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>
  Claude-Session: https://claude.ai/code/session_01ShdyPRmtWu8jp5YzevBUD4
  ```
- Work on the current branch `feat/tap-gestures` (no worktree needed; the tree is clean).

## Review Focus

1. **Lowering a category cap in Settings while the stack already exceeds it** must drop the excess at once, including reporting dropped image blobs, not wait for the next copy. Pinned in Task 1 (`testLoweringCategoryCapViaEnforceDropsImmediatelyAndReportsBlobs`).
2. **Arrow keys arrive with `.function` and `.numericPad` set** on their own; a binding recorded as plain ↑ must still match. Pinned in Task 4 (`testLookupIgnoresFunctionAndNumericPadNoiseOnArrows`).
3. **Typing in the search field with Delete bound to bare ⌫** must edit the query, not delete the selected clip; any other Delete binding fires always. Pinned in Task 4 (`testDeleteYieldsToSearchFieldOnlyForBareDeleteKeys`).
4. **Corrupt or partial `shortcuts` JSON** (junk entry, unknown action, invalid combo, empty quick-pick modifiers, or not even an object) must fall back per action and never disturb the other clipboard settings. Pinned in Task 4 (`testCodableRoundTripAndLenientDecoding`) and Task 5 (`testCorruptShortcutsLeaveOtherSettingsIntact`).
5. **A hotkey another app already owns** must not silently do nothing: Settings shows why, and the panel stays reachable by double-tap, menu-bar item, Tap Gesture and `copystack`. The status→message mapping is pinned in Task 4 (`testHotkeyRegistrationMessage`); the UI and fallback are on Task 6's manual checklist.

---

## Part A — per-category limits

### Task 1: `ClipCategory(kind:)`, `ClipLimits.perCategory`, per-category enforcement

**Files:**
- Modify: `Sources/ImperumCore/ClipQuery.swift:3-40` (add `init(kind:)`)
- Modify: `Sources/ImperumCore/Clip.swift:62-66` (`ClipLimits`)
- Modify: `Sources/ImperumCore/ClipStore.swift:57-73` (`enforce`)
- Test: `Tests/ImperumCoreTests/ClipQueryTests.swift`, `Tests/ImperumCoreTests/ClipStoreTests.swift`

**Interfaces:**
- Produces: `ClipCategory.init(kind: ClipKind)`; `ClipLimits.perCategory: [ClipCategory: Int]` with `init(maxStack:retentionDays:perCategory:)` (default `[:]`, so every existing `ClipLimits(maxStack:retentionDays:)` call still compiles).

- [ ] **Step 1: Write the failing tests**

Append to `Tests/ImperumCoreTests/ClipQueryTests.swift`, inside `final class ClipQueryTests`:

```swift
    func testEveryKindMapsToOneCategoryForLimits() {
        XCTAssertEqual(ClipCategory(kind: .text), .text)
        XCTAssertEqual(ClipCategory(kind: .color), .text)
        XCTAssertEqual(ClipCategory(kind: .link), .links)
        XCTAssertEqual(ClipCategory(kind: .email), .emails)
        XCTAssertEqual(ClipCategory(kind: .image), .images)
        XCTAssertEqual(ClipCategory(kind: .video), .videos)
        XCTAssertEqual(ClipCategory(kind: .file), .files)
        for k in ClipKind.allCases { XCTAssertNotEqual(ClipCategory(kind: k), .all) }
    }
```

Append to `Tests/ImperumCoreTests/ClipStoreTests.swift`. First add a helper next to the existing `text(...)` helper at the top of the file (file scope, before the class):

```swift
private func clip(_ kind: ClipKind, _ title: String, at t: TimeInterval, pinned: Bool = false) -> Clip {
    Clip(kind: kind, capturedAt: base.addingTimeInterval(t), sourceAppName: "A", sourceBundleID: nil,
         isPinned: pinned, title: title, payload: .text(title))
}
```

Then inside `final class ClipStoreTests`:

```swift
    // MARK: Per-category limits

    func testCategoryCapDropsOldestUnpinnedInThatCategoryOnly() {
        let s = ClipStore()
        let l = ClipLimits(maxStack: 100, retentionDays: 30, perCategory: [.links: 2])
        s.insert(clip(.link, "l1", at: 1), limits: l, now: base)
        s.insert(clip(.text, "t1", at: 2), limits: l, now: base)
        s.insert(clip(.link, "l2", at: 3), limits: l, now: base)
        s.insert(clip(.text, "t2", at: 4), limits: l, now: base)
        s.insert(clip(.link, "l3", at: 5), limits: l, now: base)
        XCTAssertEqual(s.clips.map(\.title), ["l3", "t2", "l2", "t1"])
    }

    func testCategoryCapSkipsPinnedAndDoesNotCountThem() {
        let s = ClipStore()
        let l = ClipLimits(maxStack: 100, retentionDays: 30, perCategory: [.links: 1])
        let pinned = s.insert(clip(.link, "keep", at: 1), limits: l, now: base)
        s.togglePin(pinned.id)
        s.insert(clip(.link, "l2", at: 2), limits: l, now: base)
        s.insert(clip(.link, "l3", at: 3), limits: l, now: base)
        XCTAssertEqual(Set(s.clips.map(\.title)), ["keep", "l3"])
    }

    func testLegacyColorClipsCountTowardText() {
        let s = ClipStore()
        let l = ClipLimits(maxStack: 100, retentionDays: 30, perCategory: [.text: 1])
        s.insert(clip(.color, "#ff0000", at: 1), limits: l, now: base)
        s.insert(clip(.text, "hello", at: 2), limits: l, now: base)
        XCTAssertEqual(s.clips.map(\.title), ["hello"])
    }

    func testGlobalAndCategoryCapsBothApply() {
        let s = ClipStore()
        let l = ClipLimits(maxStack: 3, retentionDays: 30, perCategory: [.text: 1])
        for i in 1...3 { s.insert(clip(.link, "l\(i)", at: TimeInterval(i)), limits: l, now: base) }
        s.insert(clip(.text, "t1", at: 4), limits: l, now: base)
        s.insert(clip(.text, "t2", at: 5), limits: l, now: base)
        // Newest first: t2 fills the text cap, t1 goes; l3 and l2 fill the global cap of 3, l1 goes.
        XCTAssertEqual(s.clips.map(\.title), ["t2", "l3", "l2"])
    }

    func testLoweringCategoryCapViaEnforceDropsImmediatelyAndReportsBlobs() {
        let s = ClipStore()
        var dropped: [UUID] = []
        s.onBlobsDropped = { dropped += $0 }
        let none = ClipLimits(maxStack: 100, retentionDays: 30)
        let ids = (0..<3).map { _ in UUID() }
        for (i, id) in ids.enumerated() {
            s.insert(Clip(id: id, kind: .image, capturedAt: base.addingTimeInterval(TimeInterval(i)), sourceAppName: "P", sourceBundleID: nil,
                          title: "img\(i)", payload: .blob(id: id, utType: "public.png", width: i + 1, height: 1)), limits: none, now: base)
        }
        XCTAssertEqual(s.clips.count, 3)
        s.enforce(limits: ClipLimits(maxStack: 100, retentionDays: 30, perCategory: [.images: 1]), now: base)
        XCTAssertEqual(s.clips.map(\.title), ["img2"])
        XCTAssertEqual(Set(dropped), Set([ids[0], ids[1]]))
    }
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter 'ClipQueryTests|ClipStoreTests' 2>&1 | grep -E 'error:|Executed' | head`
Expected: compile errors — `ClipCategory` has no `init(kind:)`, `ClipLimits` has no `perCategory` argument.

- [ ] **Step 3: Implement**

In `Sources/ImperumCore/ClipQuery.swift`, inside `public enum ClipCategory`, after the `title` property:

```swift
    /// The category a clip of `kind` is counted under for per-category
    /// limits: the same rule the chips use, so a legacy `.color` clip is Text.
    public init(kind: ClipKind) {
        switch kind {
        case .text, .color: self = .text
        case .link: self = .links
        case .email: self = .emails
        case .image: self = .images
        case .video: self = .videos
        case .file: self = .files
        }
    }
```

Replace `ClipLimits` in `Sources/ImperumCore/Clip.swift`:

```swift
public struct ClipLimits: Equatable {
    public var maxStack: Int
    public var retentionDays: Int
    /// Optional cap per category (never `.all`). A category absent here has
    /// no cap of its own; the global `maxStack` still applies.
    public var perCategory: [ClipCategory: Int]
    public init(maxStack: Int, retentionDays: Int, perCategory: [ClipCategory: Int] = [:]) {
        self.maxStack = maxStack; self.retentionDays = retentionDays; self.perCategory = perCategory
    }
}
```

Replace `enforce` in `Sources/ImperumCore/ClipStore.swift`:

```swift
    /// Drop unpinned clips beyond `maxStack` (oldest first), unpinned clips
    /// older than `retentionDays`, and unpinned clips beyond their
    /// category's cap in `perCategory` (oldest in that category first).
    /// Pinned clips are kept and not counted. A clip stamped in the future
    /// is never "old".
    public func enforce(limits: ClipLimits, now: Date = Date(), notify: Bool = true) {
        let cutoff = now.addingTimeInterval(-TimeInterval(limits.retentionDays) * 86_400)
        var unpinnedSeen = 0
        var seenInCategory: [ClipCategory: Int] = [:]
        var dropped: [UUID] = []
        clips = clips.filter { c in
            if c.isPinned { return true }
            unpinnedSeen += 1
            let category = ClipCategory(kind: c.kind)
            let inCategory = (seenInCategory[category] ?? 0) + 1
            seenInCategory[category] = inCategory
            let underCategoryCap = limits.perCategory[category].map { inCategory <= $0 } ?? true
            let keep = unpinnedSeen <= limits.maxStack && c.capturedAt >= cutoff && underCategoryCap
            if !keep, let b = c.blobID { dropped.append(b) }
            return keep
        }
        if !dropped.isEmpty { onBlobsDropped?(dropped) }
        if notify { onChange?() }
    }
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter 'ClipQueryTests|ClipStoreTests' 2>&1 | grep -E 'error:|failed|Executed' | head`
Expected: `Executed N tests, with 0 failures` for both classes, N includes the 6 new tests.

- [ ] **Step 5: Commit**

```bash
git add Sources/ImperumCore/ClipQuery.swift Sources/ImperumCore/Clip.swift Sources/ImperumCore/ClipStore.swift Tests/ImperumCoreTests/ClipQueryTests.swift Tests/ImperumCoreTests/ClipStoreTests.swift
git commit -m "feat(clipboard): per-category caps in ClipLimits and ClipStore.enforce" -m "Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>" -m "Claude-Session: https://claude.ai/code/session_01ShdyPRmtWu8jp5YzevBUD4"
```

---

### Task 2: `ClipboardSettings.categoryLimits`

**Files:**
- Modify: `Sources/ImperumCore/ClipboardSettings.swift:11-58`
- Test: `Tests/ImperumCoreTests/ClipboardSettingsTests.swift`

**Interfaces:**
- Consumes: `ClipLimits(maxStack:retentionDays:perCategory:)` from Task 1.
- Produces: `ClipboardSettings.categoryLimits: [String: Int]` (keys are `ClipCategory.rawValue`, never `"all"`, values clamped to 10…2000 on set and on decode); `ClipboardSettings.categoryLimitRange: ClosedRange<Int>` (`10...2000`); `ClipboardSettings.categoryLimitDefault: Int` (`100`); `ClipboardSettings.limits.perCategory` populated from it.

- [ ] **Step 1: Write the failing tests**

Append inside `final class ClipboardSettingsTests` in `Tests/ImperumCoreTests/ClipboardSettingsTests.swift`:

```swift
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
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter ClipboardSettingsTests 2>&1 | grep -E 'error:|Executed' | head`
Expected: compile error — `ClipboardSettings` has no member `categoryLimits`.

- [ ] **Step 3: Implement**

In `Sources/ImperumCore/ClipboardSettings.swift`, inside `public struct ClipboardSettings`:

After the `retentionDays` line add:

```swift
    /// Optional cap per category, keyed by `ClipCategory.rawValue` (never
    /// "all"). Absent = no cap for that category. Values clamp to
    /// `categoryLimitRange`; unknown keys are dropped.
    public var categoryLimits: [String: Int] = [:] { didSet { categoryLimits = Self.sanitizedCategoryLimits(categoryLimits) } }
    public static let categoryLimitRange = 10...2000
    public static let categoryLimitDefault = 100

    static func sanitizedCategoryLimits(_ raw: [String: Int]) -> [String: Int] {
        var out: [String: Int] = [:]
        for (key, value) in raw {
            guard let c = ClipCategory(rawValue: key), c != .all else { continue }
            out[key] = min(categoryLimitRange.upperBound, max(categoryLimitRange.lowerBound, value))
        }
        return out
    }
```

Replace the `limits` computed property:

```swift
    public var limits: ClipLimits {
        var per: [ClipCategory: Int] = [:]
        for (key, value) in categoryLimits { if let c = ClipCategory(rawValue: key) { per[c] = value } }
        return ClipLimits(maxStack: maxStack, retentionDays: retentionDays, perCategory: per)
    }
```

Add `categoryLimits` to `CodingKeys` (after `retentionDays`), and in `init(from:)` after the `retentionDays` line:

```swift
        s.categoryLimits = try c.decodeIfPresent([String: Int].self, forKey: .categoryLimits) ?? [:]
```

(Assigning to `s.categoryLimits` runs `didSet`, so hand-edited JSON is clamped and filtered the same way the setter is.)

- [ ] **Step 4: Run the tests to verify they pass**

Run: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter ClipboardSettingsTests 2>&1 | grep -E 'error:|failed|Executed' | head`
Expected: all pass, including the pre-existing `testDefaultsMatchSpec` (default `perCategory` is `[:]`, so `ClipLimits(maxStack: 500, retentionDays: 30)` still compares equal).

- [ ] **Step 5: Commit**

```bash
git add Sources/ImperumCore/ClipboardSettings.swift Tests/ImperumCoreTests/ClipboardSettingsTests.swift
git commit -m "feat(clipboard): store per-category limits in ClipboardSettings" -m "Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>" -m "Claude-Session: https://claude.ai/code/session_01ShdyPRmtWu8jp5YzevBUD4"
```

---

### Task 3: "Limit per category" in the Clipboard settings tab

**Files:**
- Modify: `Sources/ImperumTool/ClipboardSettingsTab.swift:43-44` (after the "Maximum stack size" stepper) and the end of the file (new private view)

**Interfaces:**
- Consumes: `ClipboardSettings.categoryLimits`, `categoryLimitRange`, `categoryLimitDefault` (Task 2); `ClipCategory.allCases`, `.title`.

No unit test: this is SwiftUI in the app target (no test target). Verified by build + the `--snapshot-settings` dev hook.

- [ ] **Step 1: Add the disclosure group**

In `Sources/ImperumTool/ClipboardSettingsTab.swift`, directly after the line
`Stepper("Maximum stack size: \(store.settings.maxStack)", value: $store.settings.maxStack, in: 20...2000, step: 10)` insert:

```swift
                DisclosureGroup("Limit per category") {
                    ForEach(ClipCategory.allCases.filter { $0 != .all }, id: \.self) { c in
                        CategoryLimitRow(category: c, store: store)
                    }
                    Text("Pinned clips never count. The global maximum still applies.")
                        .font(.caption).foregroundStyle(.secondary)
                }
```

At the end of the file add:

```swift
/// One category's optional cap: a toggle, and a stepper while it is on.
/// Turning on writes the default; turning off removes the key (= no cap).
private struct CategoryLimitRow: View {
    let category: ClipCategory
    @ObservedObject var store: ClipboardSettingsStore

    private var enabled: Binding<Bool> {
        Binding(get: { store.settings.categoryLimits[category.rawValue] != nil },
                set: { on in
                    if on { store.settings.categoryLimits[category.rawValue] = ClipboardSettings.categoryLimitDefault }
                    else { store.settings.categoryLimits.removeValue(forKey: category.rawValue) }
                })
    }

    private var value: Binding<Int> {
        Binding(get: { store.settings.categoryLimits[category.rawValue] ?? ClipboardSettings.categoryLimitDefault },
                set: { store.settings.categoryLimits[category.rawValue] = $0 })
    }

    var body: some View {
        HStack {
            Toggle(category.title, isOn: enabled)
            Spacer()
            if enabled.wrappedValue {
                Stepper("\(value.wrappedValue) clips", value: value, in: ClipboardSettings.categoryLimitRange, step: 10)
            }
        }
    }
}
```

- [ ] **Step 2: Build**

Run: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift build 2>&1 | grep -E 'error:|Build complete'`
Expected: `Build complete!`

- [ ] **Step 3: Render the tab and look at it**

Run:
```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift run ImperumTool --snapshot-settings /private/tmp/claude-501/-Users-deepdark-WSMonitor/8de8f080-57d2-4efc-ac87-c5863445ca12/scratchpad/clipboard-tab.png clipboard
```
Then open the PNG with the Read tool. Expected: a "Limit per category" disclosure under "Maximum stack size". Expand it in a real run (`swift run ImperumTool`, Settings › Clipboard): six rows Text, Links, Emails, Images, Videos, Files; toggling Images on shows a "100 clips" stepper; the value survives reopening Settings.

- [ ] **Step 4: Run the whole suite**

Run: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test 2>&1 | grep -E "Test Suite '(ImperumCoreTests|CopyStackKitTests)\.xctest' (passed|failed)" -A1`
Expected: both bundles pass; ImperumCore count is 158 + 9 = 167.

- [ ] **Step 5: Commit**

```bash
git add Sources/ImperumTool/ClipboardSettingsTab.swift
git commit -m "feat(clipboard): Limit per category rows in the Clipboard settings tab" -m "Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>" -m "Claude-Session: https://claude.ai/code/session_01ShdyPRmtWu8jp5YzevBUD4"
```

---

## Part B — configurable shortcuts

### Task 4: `PanelShortcuts` model (pure)

**Files:**
- Create: `Sources/ImperumCore/PanelShortcuts.swift`
- Test: `Tests/ImperumCoreTests/PanelShortcutsTests.swift` (new)

**Interfaces:**
- Consumes: `KeyCombo` from `Sources/ImperumCore/TapAction.swift:17-24` (`keyCode: UInt16`, `modifiers: UInt`, `display: String`; `Codable, Equatable, Hashable`).
- Produces (all `public`):
  - `enum PanelAction: String, Codable, CaseIterable` — `openPanel, up, down, previousCategory, nextCategory, paste, pin, delete, close`; `title: String`; `static let inPanel: [PanelAction]` (all but `openPanel`, in declaration order).
  - `enum ShortcutProblem: Equatable` — `hotkeyNeedsModifier`, `printableNeedsModifier`; `message: String`.
  - `struct PanelShortcuts: Codable, Equatable`:
    - `static let command/shift/option/control: UInt`
    - `static func normalize(_ modifiers: UInt) -> UInt`
    - `static let defaults: PanelShortcuts`
    - `init(bindings: [PanelAction: KeyCombo], quickPickModifiers: UInt)`
    - `private(set) var bindings`; `var quickPickModifiers: UInt` (normalised on set)
    - `func combo(for: PanelAction) -> KeyCombo`
    - `mutating func set(_ combo: KeyCombo, for: PanelAction)`
    - `func action(keyCode: UInt16, modifiers: UInt) -> PanelAction?`
    - `static func problem(with: KeyCombo, for: PanelAction) -> ShortcutProblem?`
    - `func conflicts(for: PanelAction) -> [String]`; `var conflictingActions: Set<PanelAction>`
    - `func deleteYieldsToSearchField(queryEmpty: Bool) -> Bool`
    - `static func modifierGlyphs(_: UInt) -> String`; `var quickPickDisplay: String`
    - `static func hotkeyRegistrationMessage(status: Int32) -> String?`

- [ ] **Step 1: Write the failing tests**

Create `Tests/ImperumCoreTests/PanelShortcutsTests.swift`:

```swift
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
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter PanelShortcutsTests 2>&1 | grep -E 'error:' | head -3`
Expected: `cannot find 'PanelShortcuts' in scope`.

- [ ] **Step 3: Implement**

Create `Sources/ImperumCore/PanelShortcuts.swift`:

```swift
import Foundation

/// Everything the Copy Stack panel and its global hotkey can be bound to.
/// Order matters: on a tie between two in-panel bindings, the earlier case
/// wins (see `PanelShortcuts.action(keyCode:modifiers:)`).
public enum PanelAction: String, Codable, CaseIterable {
    case openPanel
    case up, down, previousCategory, nextCategory
    case paste, pin, delete, close

    public var title: String {
        switch self {
        case .openPanel: return "Open the copy stack"
        case .up: return "Move up"
        case .down: return "Move down"
        case .previousCategory: return "Previous category"
        case .nextCategory: return "Next category"
        case .paste: return "Paste"
        case .pin: return "Pin"
        case .delete: return "Delete"
        case .close: return "Close"
        }
    }

    /// The actions the panel's key monitor dispatches (all but the hotkey).
    public static let inPanel: [PanelAction] = allCases.filter { $0 != .openPanel }
}

public enum ShortcutProblem: Equatable {
    /// `openPanel` needs ⌘, ⌃ or ⌥, or an F-key: a bare key can't be a system-wide hotkey.
    case hotkeyNeedsModifier
    /// An in-panel binding on a bare printable key would make that key untypeable in search.
    case printableNeedsModifier

    public var message: String {
        switch self {
        case .hotkeyNeedsModifier: return "Use ⌘, ⌃ or ⌥, or a function key"
        case .printableNeedsModifier: return "Add ⌘, ⌃ or ⌥ so typing in search still works"
        }
    }
}

/// The user's key map for the Copy Stack. Modifiers are raw
/// `NSEvent.ModifierFlags` bits, masked to ⌘ ⇧ ⌥ ⌃ on the way in, so arrow
/// keys (which carry `.function` + `.numericPad` on their own) and F-keys
/// match a binding recorded without noise. Pure: no AppKit.
public struct PanelShortcuts: Codable, Equatable {
    public static let command: UInt = 1 << 20
    public static let shift: UInt = 1 << 17
    public static let option: UInt = 1 << 19
    public static let control: UInt = 1 << 18
    private static let kept: UInt = command | shift | option | control
    /// ⇧ alone doesn't count: ⇧P still types a P.
    private static let realModifiers: UInt = command | option | control

    public static let functionKeyCodes: Set<UInt16> = [122, 120, 99, 118, 96, 97, 98, 100, 101, 109, 103, 111,   // F1–F12
                                                        105, 107, 113, 106, 64, 79, 80]                            // F13–F19
    /// Keys that never type a character into the search field.
    public static let nonPrintingKeyCodes: Set<UInt16> = functionKeyCodes.union(
        [36, 76, 48, 51, 117, 53, 115, 119, 116, 121, 123, 124, 125, 126])   // ↩ ⌤ ⇥ ⌫ ⌦ ⎋ Home End PgUp PgDn ← → ↓ ↑
    static let digitKeyCodes: [UInt16: Int] = [18: 1, 19: 2, 20: 3, 21: 4, 23: 5, 22: 6, 26: 7, 28: 8, 25: 9]

    public private(set) var bindings: [PanelAction: KeyCombo]
    /// Held with a digit 1–9 to paste that row. The digits are fixed.
    public var quickPickModifiers: UInt { didSet { quickPickModifiers = Self.normalize(quickPickModifiers) } }

    public static let defaults = PanelShortcuts(bindings: [
        .openPanel: KeyCombo(keyCode: 9, modifiers: command | shift, display: "⌘⇧V"),
        .up: KeyCombo(keyCode: 126, modifiers: 0, display: "↑"),
        .down: KeyCombo(keyCode: 125, modifiers: 0, display: "↓"),
        .previousCategory: KeyCombo(keyCode: 123, modifiers: 0, display: "←"),
        .nextCategory: KeyCombo(keyCode: 124, modifiers: 0, display: "→"),
        .paste: KeyCombo(keyCode: 36, modifiers: 0, display: "↩"),
        .pin: KeyCombo(keyCode: 35, modifiers: command, display: "⌘P"),
        .delete: KeyCombo(keyCode: 51, modifiers: 0, display: "⌫"),
        .close: KeyCombo(keyCode: 53, modifiers: 0, display: "⎋"),
    ], quickPickModifiers: command)

    public init(bindings: [PanelAction: KeyCombo], quickPickModifiers: UInt) {
        self.bindings = bindings.mapValues(Self.normalized)
        self.quickPickModifiers = Self.normalize(quickPickModifiers)
    }

    public static func normalize(_ modifiers: UInt) -> UInt { modifiers & kept }
    private static func normalized(_ c: KeyCombo) -> KeyCombo {
        KeyCombo(keyCode: c.keyCode, modifiers: normalize(c.modifiers), display: c.display)
    }

    public func combo(for action: PanelAction) -> KeyCombo { bindings[action] ?? Self.defaults.bindings[action]! }

    /// Stores `combo` (modifiers normalised). Does not validate — callers
    /// run `problem(with:for:)` first and refuse to store on a problem.
    public mutating func set(_ combo: KeyCombo, for action: PanelAction) { bindings[action] = Self.normalized(combo) }

    /// The in-panel action bound to this key, if any. `.openPanel` is never
    /// returned: the hotkey is the Carbon layer's job.
    public func action(keyCode: UInt16, modifiers: UInt) -> PanelAction? {
        let m = Self.normalize(modifiers)
        return PanelAction.inPanel.first { let c = combo(for: $0); return c.keyCode == keyCode && c.modifiers == m }
    }

    public static func problem(with combo: KeyCombo, for action: PanelAction) -> ShortcutProblem? {
        let hasReal = normalize(combo.modifiers) & realModifiers != 0
        if action == .openPanel {
            return hasReal || functionKeyCodes.contains(combo.keyCode) ? nil : .hotkeyNeedsModifier
        }
        return hasReal || nonPrintingKeyCodes.contains(combo.keyCode) ? nil : .printableNeedsModifier
    }

    /// Titles of the other bindings sharing `action`'s combo, plus "Quick
    /// pick" when its key is a digit under `quickPickModifiers`. Empty = unique.
    public func conflicts(for action: PanelAction) -> [String] {
        let c = combo(for: action)
        var out = PanelAction.allCases
            .filter { $0 != action }
            .filter { let o = combo(for: $0); return o.keyCode == c.keyCode && o.modifiers == c.modifiers }
            .map(\.title)
        if Self.digitKeyCodes[c.keyCode] != nil, c.modifiers == quickPickModifiers { out.append("Quick pick") }
        return out
    }

    public var conflictingActions: Set<PanelAction> { Set(PanelAction.allCases.filter { !conflicts(for: $0).isEmpty }) }

    /// True when Delete is a bare ⌫/⌦ and the search field has text: the key
    /// must edit the query, not delete the selected clip.
    public func deleteYieldsToSearchField(queryEmpty: Bool) -> Bool {
        let c = combo(for: .delete)
        return !queryEmpty && c.modifiers == 0 && (c.keyCode == 51 || c.keyCode == 117)
    }

    public static func modifierGlyphs(_ modifiers: UInt) -> String {
        let m = normalize(modifiers)
        var s = ""
        if m & control != 0 { s += "⌃" }
        if m & option != 0 { s += "⌥" }
        if m & shift != 0 { s += "⇧" }
        if m & command != 0 { s += "⌘" }
        return s
    }

    public var quickPickDisplay: String { Self.modifierGlyphs(quickPickModifiers) + "1–9" }

    /// nil on success. -9878 is Carbon's `eventHotKeyExistsErr`.
    public static func hotkeyRegistrationMessage(status: Int32) -> String? {
        switch status {
        case 0: return nil
        case -9878: return "Already used by another app"
        default: return "Could not register (error \(status))"
        }
    }

    // MARK: Codable (lenient)

    private enum CodingKeys: String, CodingKey { case bindings, quickPickModifiers }

    /// A dictionary entry that decodes to nil instead of failing the whole
    /// map, so one junk binding costs only that binding.
    private struct LenientCombo: Decodable {
        let combo: KeyCombo?
        init(from decoder: Decoder) throws { combo = try? KeyCombo(from: decoder) }
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let raw = ((try? c.decodeIfPresent([String: LenientCombo].self, forKey: .bindings)) ?? nil) ?? [:]
        var b = Self.defaults.bindings
        for (key, entry) in raw {
            guard let a = PanelAction(rawValue: key), let combo = entry.combo,
                  Self.problem(with: combo, for: a) == nil else { continue }
            b[a] = combo
        }
        let q = ((try? c.decodeIfPresent(UInt.self, forKey: .quickPickModifiers)) ?? nil) ?? Self.command
        let qm = Self.normalize(q)
        self.init(bindings: b, quickPickModifiers: qm == 0 ? Self.command : qm)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        var raw: [String: KeyCombo] = [:]
        for (a, combo) in bindings { raw[a.rawValue] = combo }
        try c.encode(raw, forKey: .bindings)
        try c.encode(quickPickModifiers, forKey: .quickPickModifiers)
    }
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter PanelShortcutsTests 2>&1 | grep -E 'error:|failed|Executed' | head`
Expected: `Executed 9 tests, with 0 failures`.

- [ ] **Step 5: Commit**

```bash
git add Sources/ImperumCore/PanelShortcuts.swift Tests/ImperumCoreTests/PanelShortcutsTests.swift
git commit -m "feat(clipboard): PanelShortcuts key map with validation, conflicts and lenient decoding" -m "Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>" -m "Claude-Session: https://claude.ai/code/session_01ShdyPRmtWu8jp5YzevBUD4"
```

---

### Task 5: `ClipboardSettings.shortcuts`

**Files:**
- Modify: `Sources/ImperumCore/ClipboardSettings.swift`
- Test: `Tests/ImperumCoreTests/ClipboardSettingsTests.swift`

**Interfaces:**
- Consumes: `PanelShortcuts`, `.defaults`, `set(_:for:)`, `combo(for:)` (Task 4).
- Produces: `ClipboardSettings.shortcuts: PanelShortcuts` (default `.defaults`; absent or non-object JSON → `.defaults`).

- [ ] **Step 1: Write the failing tests**

Append inside `final class ClipboardSettingsTests`:

```swift
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
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter ClipboardSettingsTests 2>&1 | grep -E 'error:' | head -3`
Expected: `value of type 'ClipboardSettings' has no member 'shortcuts'`.

- [ ] **Step 3: Implement**

In `Sources/ImperumCore/ClipboardSettings.swift`, inside the struct after the `cmuxSocketPassword` property:

```swift
    /// Key map for the panel and its global hotkey (see `PanelShortcuts`).
    public var shortcuts: PanelShortcuts = .defaults
```

Add `shortcuts` to `CodingKeys` (last), and in `init(from:)` after the `cmuxSocketPassword` line:

```swift
        // PanelShortcuts decodes leniently on its own; this guards the case
        // where the value isn't even an object.
        let decodedShortcuts: PanelShortcuts? = (try? c.decodeIfPresent(PanelShortcuts.self, forKey: .shortcuts)) ?? nil
        s.shortcuts = decodedShortcuts ?? .defaults
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter ClipboardSettingsTests 2>&1 | grep -E 'error:|failed|Executed' | head`
Expected: all pass (11 tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/ImperumCore/ClipboardSettings.swift Tests/ImperumCoreTests/ClipboardSettingsTests.swift
git commit -m "feat(clipboard): persist PanelShortcuts in ClipboardSettings" -m "Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>" -m "Claude-Session: https://claude.ai/code/session_01ShdyPRmtWu8jp5YzevBUD4"
```

---

### Task 6: Recorded hotkey in `CmdVTap`, error surfaced by `ClipboardController`

**Files:**
- Modify: `Sources/ImperumTool/CmdVTap.swift:6-40` (doc, `start`, `stop`) and `:131-146` (`installHotKey`)
- Modify: `Sources/ImperumTool/ClipboardController.swift:17` (class decl), `:65` (`lastApplied`), `:133-155` (`apply`)

**Interfaces:**
- Consumes: `PanelShortcuts.normalize`, `.command/.shift/.option/.control`, `.hotkeyRegistrationMessage(status:)`, `ClipboardSettings.shortcuts.combo(for: .openPanel)`.
- Produces: `CmdVTap.start(doubleTap: Bool, hotkey: KeyCombo?) -> Bool`; `CmdVTap.hotkeyError: String?`; `ClipboardController: ObservableObject` with `@Published private(set) var hotkeyError: String?`.

- [ ] **Step 1: Change `CmdVTap`**

Replace the class doc comment's first line with:
```swift
/// Owns the double-tap ⌘V event tap and/or the user's global hotkey
/// (`PanelShortcuts`, default ⌘⇧V) registered through Carbon. Every key
```
(keep the rest of the comment as is).

After `var window: TimeInterval = 0.3 { ... }` add:

```swift
    /// Why the last hotkey registration failed, nil when it succeeded or
    /// no hotkey was requested. Read by the controller after `start`.
    private(set) var hotkeyError: String?
```

Replace `start`:

```swift
    /// Returns false when the event tap was requested but could not be created
    /// (no Accessibility trust). The hotkey never needs Accessibility; if it
    /// can't be registered, `hotkeyError` says why and the tap still runs.
    @discardableResult
    func start(doubleTap: Bool, hotkey: KeyCombo?) -> Bool {
        stop()
        var ok = true
        if doubleTap { ok = installTap() }
        if let hotkey { installHotKey(hotkey) }
        return ok
    }
```

In `stop()`, add `hotkeyError = nil` as the first line.

Replace the whole `// MARK: Carbon hotkey (⌘⇧V, matching CopyCat)` section:

```swift
    // MARK: Carbon hotkey

    private static func carbonModifiers(_ raw: UInt) -> UInt32 {
        let m = PanelShortcuts.normalize(raw)
        var out: UInt32 = 0
        if m & PanelShortcuts.command != 0 { out |= UInt32(cmdKey) }
        if m & PanelShortcuts.shift != 0 { out |= UInt32(shiftKey) }
        if m & PanelShortcuts.option != 0 { out |= UInt32(optionKey) }
        if m & PanelShortcuts.control != 0 { out |= UInt32(controlKey) }
        return out
    }

    private func installHotKey(_ combo: KeyCombo) {
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(GetApplicationEventTarget(), { _, _, refcon in
            guard let refcon else { return noErr }
            let me = Unmanaged<CmdVTap>.fromOpaque(refcon).takeUnretainedValue()
            DispatchQueue.main.async { me.onOpenPanel?() }
            return noErr
        }, 1, &spec, refcon, &hotKeyHandler)
        let id = EventHotKeyID(signature: OSType(0x494D5052) /* 'IMPR' */, id: 1)
        let status = RegisterEventHotKey(UInt32(combo.keyCode), Self.carbonModifiers(combo.modifiers), id,
                                         GetApplicationEventTarget(), 0, &hotKeyRef)
        hotkeyError = PanelShortcuts.hotkeyRegistrationMessage(status: status)
        if status != noErr { hotKeyRef = nil }
    }
```

- [ ] **Step 2: Change `ClipboardController`**

Line 17: `final class ClipboardController {` → `final class ClipboardController: ObservableObject {`.

Directly after that line add:

```swift
    /// Why the global hotkey could not be registered (e.g. another app owns
    /// it), for the settings tab. nil when registered or not in use.
    @Published private(set) var hotkeyError: String?
```

Replace the `lastApplied` declaration:

```swift
    private var lastApplied: (enabled: Bool, trigger: ClipboardTrigger, hotkey: KeyCombo, clearOnQuit: Bool)?
```

In `apply(_:)`, replace from `let triggerChanged = ...` through the closing brace of `if triggerChanged { ... }` with:

```swift
        let hotkey = s.shortcuts.combo(for: .openPanel)
        let triggerChanged = lastApplied.map { $0.enabled != s.enabled || $0.trigger != s.trigger || $0.hotkey != hotkey } ?? true
        if triggerChanged {
            if s.enabled {
                let ok = tap.start(doubleTap: s.trigger.usesDoubleTap, hotkey: s.trigger.usesHotkey ? hotkey : nil)
                tapNeedsAccessibility = !ok
                statusItem.needsAccessibility = !ok
            } else {
                tap.stop()
                tapNeedsAccessibility = false
                statusItem.needsAccessibility = false
            }
            hotkeyError = tap.hotkeyError
        }
```

and replace `lastApplied = (s.enabled, s.trigger, s.clearOnQuit)` with `lastApplied = (s.enabled, s.trigger, hotkey, s.clearOnQuit)`.

- [ ] **Step 3: Build and run the suite**

Run: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift build 2>&1 | grep -E 'error:|Build complete'`
Expected: `Build complete!` (the only `tap.start` caller is `apply`; `retryTapIfTrusted` goes through `apply` too).

Run: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test 2>&1 | grep -E "Test Suite '(ImperumCoreTests|CopyStackKitTests)\.xctest' (passed|failed)" -A1`
Expected: both pass.

- [ ] **Step 4: Manual check**

`DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift run ImperumTool`, Settings › Clipboard, trigger "Both". Press ⌘⇧V in another app: the panel opens (default binding still works). Quit.

- [ ] **Step 5: Commit**

```bash
git add Sources/ImperumTool/CmdVTap.swift Sources/ImperumTool/ClipboardController.swift
git commit -m "feat(clipboard): register the recorded open-panel hotkey and surface registration errors" -m "Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>" -m "Claude-Session: https://claude.ai/code/session_01ShdyPRmtWu8jp5YzevBUD4"
```

---

### Task 7: Panel routing, footer hints and row badges read the key map

**Files:**
- Modify: `Sources/ImperumTool/CopyStackModel.swift:41-48` (init) and add `shortcuts`
- Modify: `Sources/ImperumTool/CopyStackPanel.swift:108-150` (`route`)
- Modify: `Sources/ImperumTool/CopyStackView.swift:59-66` (row), `:80-104` (footer), `:107-113` (`ClipRow` fields), `:130`

**Interfaces:**
- Consumes: `PanelShortcuts.action(keyCode:modifiers:)`, `deleteYieldsToSearchField(queryEmpty:)`, `quickPickModifiers`, `combo(for:)`, `modifierGlyphs`, `normalize`; `ClipboardSettingsStore.$settings`.
- Produces: `CopyStackModel.shortcuts: PanelShortcuts` (live from the settings store; the model publishes a change when it changes).
- Note vs. spec: the spec says the controller sets a `shortcuts` property on the model on every apply. The model already holds `ClipboardSettingsStore`, so reading `settings.settings.shortcuts` directly gives the same live value with no extra plumbing; that is what this task does.

- [ ] **Step 1: `CopyStackModel`**

After `var totalCount: Int { flat.count }` add:

```swift
    /// The live key map. Read on every key event and by the footer.
    var shortcuts: PanelShortcuts { settings.settings.shortcuts }
```

In `init`, after the `store.$clips...` line add:

```swift
        settings.$settings.map(\.shortcuts).removeDuplicates().receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &bag)
```

- [ ] **Step 2: `CopyStackPanel.route`**

Replace `route(_:)` entirely (keep the doc comment):

```swift
    /// True when consumed. Anything else goes to the search field.
    private func route(_ e: NSEvent) -> Bool {
        let shortcuts = model.shortcuts
        let mods = PanelShortcuts.normalize(UInt(e.modifierFlags.rawValue))
        let cmd = e.modifierFlags.contains(.command)

        // 1. The user's bindings, first match wins. Keypad Enter doubles as Return.
        var action = shortcuts.action(keyCode: e.keyCode, modifiers: mods)
        if action == nil, e.keyCode == 76 { action = shortcuts.action(keyCode: 36, modifiers: mods) }
        if let action, let command = Self.command(for: action) {
            if action == .delete, shortcuts.deleteYieldsToSearchField(queryEmpty: model.query.isEmpty) { return false }
            return model.handle(key: command)
        }

        // 2. Quick pick: the configured modifiers plus a digit.
        if mods == shortcuts.quickPickModifiers, let ch = e.charactersIgnoringModifiers,
           let n = Int(ch), (1...9).contains(n) {
            return model.handle(key: .digit(n))
        }

        // 3. Standard editing shortcuts and the swallow list.
        if cmd, let ch = e.charactersIgnoringModifiers {
            // The panel has no Edit menu, so these standard shortcuts would
            // otherwise be swallowed by the local monitor and do nothing in
            // the search field. Route them to the field's editor directly.
            switch ch {
            case "v": return NSApp.sendAction(#selector(NSText.paste(_:)), to: nil, from: nil)
            case "c": return NSApp.sendAction(#selector(NSText.copy(_:)), to: nil, from: nil)
            case "x": return NSApp.sendAction(#selector(NSText.cut(_:)), to: nil, from: nil)
            case "a": return NSApp.sendAction(#selector(NSText.selectAll(_:)), to: nil, from: nil)
            // Swallow the shortcuts the app's main menu would otherwise act
            // on while this panel is key, so it can never quit, open
            // Settings, or minimize/close a window out from under the user.
            // Matched by character, not key code: on AZERTY and other
            // non-QWERTY layouts the physical key for ⌘Q (key code 12) types
            // a different character, so a key-code match let ⌘Q fall
            // through and quit the app. "0" is safe here — it never reaches
            // this switch for a digit paste, since that's handled by the
            // quick-pick check above.
            case "q", ",", "0", "w": return true // ⌘Q, ⌘, (comma), ⌘0, ⌘W
            default: break
            }
        }
        return false
    }

    private static func command(for action: PanelAction) -> CopyStackModel.KeyCommand? {
        switch action {
        case .up: return .up
        case .down: return .down
        case .previousCategory: return .left
        case .nextCategory: return .right
        case .paste: return .enter
        case .pin: return .pin
        case .delete: return .delete
        case .close: return .escape
        case .openPanel: return nil   // never returned by action(keyCode:modifiers:)
        }
    }
```

Behaviour notes (intentional, from the spec): bindings are matched on exact normalised modifiers, so ⇧↑ no longer moves the selection (it extends the text selection in search instead), and quick pick requires exactly the configured modifiers.

- [ ] **Step 3: `CopyStackView`**

Replace the footer and `hint`:

```swift
    // MARK: Footer

    private var footer: some View {
        let s = model.shortcuts
        return HStack(spacing: 14) {
            hint(s.combo(for: .up).display + s.combo(for: .down).display, "Navigate")
            hint(s.combo(for: .previousCategory).display + s.combo(for: .nextCategory).display, "Category")
            hint(s.combo(for: .paste).display, "Paste")
            hint(s.combo(for: .pin).display, "Pin")
            hint(s.combo(for: .delete).display, "Delete")
            Spacer()
            hint(s.combo(for: .close).display, "Close")
        }
        .font(.caption).foregroundStyle(.secondary)
        .padding(.horizontal, 16).padding(.vertical, 10)
    }

    private func hint(_ keys: String, _ label: String) -> some View {
        HStack(spacing: 5) {
            Text(keys).font(.caption2.monospaced())
                .padding(.horizontal, 6).padding(.vertical, 3)
                .background(RoundedRectangle(cornerRadius: 5).fill(Color.primary.opacity(0.1)))
            Text(label)
        }
    }
```

In the list, change the `ClipRow(...)` construction to pass the quick-pick prefix:

```swift
                            ClipRow(clip: clip, index: index, selected: model.selectedID == clip.id,
                                    quickPickPrefix: PanelShortcuts.modifierGlyphs(model.shortcuts.quickPickModifiers),
                                    thumbnail: model.thumbnail(for: clip), favicon: model.favicon(for: clip),
                                    richPreview: model.richPreview(for: clip))
```

In `private struct ClipRow`, add `let quickPickPrefix: String` after `let selected: Bool`, and replace the badge line with:

```swift
            if index < 9 { Text("\(quickPickPrefix)\(index + 1)").font(.caption.monospaced()).foregroundStyle(.secondary) }
```

- [ ] **Step 4: Build and run the suite**

Run: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift build 2>&1 | grep -E 'error:|Build complete'`
Expected: `Build complete!`

Run: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test 2>&1 | grep -E "Test Suite '(ImperumCoreTests|CopyStackKitTests)\.xctest' (passed|failed)" -A1`
Expected: both pass.

- [ ] **Step 5: Manual check**

`swift run ImperumTool` (with `DEVELOPER_DIR`), copy three text clips, open the panel with ⌘⇧V: ↑↓ move, ←→ change chip, ⌘P pins, type a letter then ⌫ edits the query (does not delete), clear the query then ⌫ deletes, ⌘2 pastes the second row, keypad Enter pastes, esc closes. Footer reads `↑↓ Navigate · ←→ Category · ↩ Paste · ⌘P Pin · ⌫ Delete · ⎋ Close`; rows show ⌘1…⌘9.

- [ ] **Step 6: Commit**

```bash
git add Sources/ImperumTool/CopyStackModel.swift Sources/ImperumTool/CopyStackPanel.swift Sources/ImperumTool/CopyStackView.swift
git commit -m "feat(clipboard): route panel keys and render hints from PanelShortcuts" -m "Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>" -m "Claude-Session: https://claude.ai/code/session_01ShdyPRmtWu8jp5YzevBUD4"
```

---

### Task 8: Shared `KeyComboRecorder` and the "Shortcuts" settings section

**Files:**
- Create: `Sources/ImperumTool/KeyComboRecorder.swift`
- Modify: `Sources/ImperumTool/TapGesturesSettingsTab.swift:390-438` (delete the private recorder)
- Modify: `Sources/ImperumTool/ClipboardSettingsTab.swift:8-9` (properties), `:23-27` (trigger picker), after the "Capture & trigger" section (new section)
- Modify: `Sources/ImperumTool/Settings.swift:106-108, 131-132`
- Modify: `Sources/ImperumTool/AppController.swift:108-111`

**Interfaces:**
- Consumes: `ClipboardController.hotkeyError` (Task 6), `PanelShortcuts` API (Task 4), `ClipboardSettings.shortcuts` (Task 5).
- Produces: `struct KeyComboRecorder: View` with `combo: KeyCombo?`, `stripFunctionModifier: Bool = false`, `validate: ((KeyCombo) -> ShortcutProblem?)? = nil`, `update: (KeyCombo?) -> Void`; `ClipboardSettingsTab(store:controller:onClearAll:)`; `SettingsTabs.makeController(config:blockStore:tapStore:tapController:clipboardStore:clipboardController:onClearClipboard:)`.

- [ ] **Step 1: Extract the recorder**

Create `Sources/ImperumTool/KeyComboRecorder.swift`:

```swift
import AppKit
import SwiftUI
import ImperumCore

/// Records one keyboard shortcut: click, press the keys, done; Esc cancels.
/// Shared by the Tap Gestures and Clipboard settings tabs.
struct KeyComboRecorder: View {
    let combo: KeyCombo?
    /// Drop the fn/🌐 bit so arrows and F-keys record cleanly. On for the
    /// Copy Stack (it compares ⌘⇧⌥⌃ only); off for Tap Gestures, which
    /// replays the recorded flags verbatim.
    var stripFunctionModifier = false
    /// Return a problem to reject the combo: it is then not stored and the
    /// message shows in orange until the next recording.
    var validate: ((KeyCombo) -> ShortcutProblem?)? = nil
    let update: (KeyCombo?) -> Void
    @State private var recording = false
    @State private var monitor: Any?
    @State private var problem: ShortcutProblem?

    var body: some View {
        VStack(alignment: .trailing, spacing: 2) {
            HStack(spacing: 8) {
                Text(recording ? "Press the shortcut now… (Esc cancels)" : (combo?.display ?? "No shortcut recorded"))
                    .font(.caption).foregroundStyle(recording ? .primary : .secondary)
                    .frame(minWidth: 90, alignment: .leading)
                Button(recording ? "Cancel" : (combo == nil ? "Record…" : "Change…")) {
                    recording ? stop() : start()
                }.controlSize(.small)
            }
            if let problem { Text(problem.message).font(.caption).foregroundStyle(.orange) }
        }
        .onDisappear(perform: stop)
    }

    private func start() {
        recording = true
        problem = nil
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { ev in
            if ev.keyCode == 53 { stop(); return nil }
            var mods = ev.modifierFlags.intersection(.deviceIndependentFlagsMask)
                .subtracting([.capsLock, .numericPad, .help])
            if stripFunctionModifier { mods.subtract(.function) }
            let recorded = KeyCombo(keyCode: ev.keyCode, modifiers: mods.rawValue, display: Self.describe(ev, mods))
            if let p = validate?(recorded) { problem = p } else { update(recorded) }
            stop()
            return nil
        }
    }

    private func stop() {
        recording = false
        if let m = monitor { NSEvent.removeMonitor(m); monitor = nil }
    }

    private static func describe(_ ev: NSEvent, _ mods: NSEvent.ModifierFlags) -> String {
        var s = ""
        if mods.contains(.function) { s += "🌐" }
        if mods.contains(.control) { s += "⌃" }
        if mods.contains(.option) { s += "⌥" }
        if mods.contains(.shift) { s += "⇧" }
        if mods.contains(.command) { s += "⌘" }
        let special: [UInt16: String] = [49: "Space", 36: "↩", 76: "⌤", 48: "⇥", 51: "⌫", 117: "⌦", 53: "⎋",
                                         115: "Home", 119: "End", 116: "PgUp", 121: "PgDn",
                                         123: "←", 124: "→", 125: "↓", 126: "↑",
                                         122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6", 98: "F7", 100: "F8",
                                         101: "F9", 109: "F10", 103: "F11", 111: "F12", 105: "F13", 107: "F14", 113: "F15",
                                         106: "F16", 64: "F17", 79: "F18", 80: "F19"]
        let key = special[ev.keyCode] ?? (ev.charactersIgnoringModifiers ?? "?").uppercased()
        return s + key
    }
}
```

In `Sources/ImperumTool/TapGesturesSettingsTab.swift` delete the whole `private struct KeyComboRecorder: View { ... }` (lines 390–438, from the `private struct KeyComboRecorder` line to its closing brace). The existing call site `KeyComboRecorder(combo: action.keyCombo) { ... }` keeps compiling: the trailing closure binds to `update` and the defaulted `var`s are skipped.

- [ ] **Step 2: Wire the controller into the tab**

`Sources/ImperumTool/Settings.swift`: change the `makeController` signature to

```swift
    static func makeController(config: AppConfig, blockStore: VolumeBlockStore,
                               tapStore: TapSettingsStore, tapController: TapGestureController,
                               clipboardStore: ClipboardSettingsStore, clipboardController: ClipboardController,
                               onClearClipboard: @escaping () -> Void) -> NSTabViewController {
```

and the clipboard tab line to

```swift
            ClipboardSettingsTab(store: clipboardStore, controller: clipboardController, onClearAll: onClearClipboard))
```

`Sources/ImperumTool/AppController.swift` `showSettings()`:

```swift
            let tabs = SettingsTabs.makeController(config: config, blockStore: volumeBlockStore,
                                                   tapStore: tapStore, tapController: tapGestures,
                                                   clipboardStore: clipboardSettings, clipboardController: clipboard,
                                                   onClearClipboard: { [weak self] in self?.clipboard.clearAll() })
```

`Sources/ImperumTool/ClipboardSettingsTab.swift`: after `@ObservedObject var store: ClipboardSettingsStore` add

```swift
    @ObservedObject var controller: ClipboardController
```

- [ ] **Step 3: The trigger label and the Shortcuts section**

In the trigger picker replace `Text("⌘⇧V").tag(ClipboardTrigger.hotkey)` with:

```swift
                    Text(store.settings.shortcuts.combo(for: .openPanel).display).tag(ClipboardTrigger.hotkey)
```

Directly after the closing brace of `Section("Capture & trigger") { ... }` (before `Section("Terminal")`) insert:

```swift
            Section("Shortcuts") {
                ForEach(PanelAction.allCases, id: \.self) { action in
                    LabeledContent(action.title) {
                        KeyComboRecorder(combo: store.settings.shortcuts.combo(for: action),
                                         stripFunctionModifier: true,
                                         validate: { PanelShortcuts.problem(with: $0, for: action) }) { combo in
                            if let combo { store.settings.shortcuts.set(combo, for: action) }
                        }
                    }
                    let others = store.settings.shortcuts.conflicts(for: action)
                    if !others.isEmpty {
                        Text("Also used by " + others.joined(separator: ", ")).font(.caption).foregroundStyle(.orange)
                    }
                    if action == .openPanel, let err = controller.hotkeyError {
                        Text(err).font(.caption).foregroundStyle(.orange)
                    }
                }
                LabeledContent("Quick pick") {
                    KeyComboRecorder(combo: KeyCombo(keyCode: 0, modifiers: store.settings.shortcuts.quickPickModifiers,
                                                     display: store.settings.shortcuts.quickPickDisplay),
                                     stripFunctionModifier: true,
                                     validate: { PanelShortcuts.normalize($0.modifiers) == 0 ? .printableNeedsModifier : nil }) { combo in
                        if let combo { store.settings.shortcuts.quickPickModifiers = combo.modifiers }
                    }
                }
                Text("Hold these modifiers with 1–9 to paste that row. Press the modifiers with any key to record them.")
                    .font(.caption).foregroundStyle(.secondary)
                Button("Reset to defaults") { store.settings.shortcuts = .defaults }
                Text("The terminal picker (copystack) keeps its own fixed keys.")
                    .font(.caption).foregroundStyle(.secondary)
            }
```

- [ ] **Step 4: Build, run the suite, render the tab**

Run: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift build 2>&1 | grep -E 'error:|Build complete'`
Expected: `Build complete!`

Run: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test 2>&1 | grep -E "Test Suite '(ImperumCoreTests|CopyStackKitTests)\.xctest' (passed|failed)" -A1`
Expected: both pass; ImperumCore = 158 + 9 (Part A) + 9 (Task 4) + 3 (Task 5) = 179.

Run the snapshot hook again:
```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift run ImperumTool --snapshot-settings /private/tmp/claude-501/-Users-deepdark-WSMonitor/8de8f080-57d2-4efc-ac87-c5863445ca12/scratchpad/clipboard-tab-2.png clipboard
```
Open the PNG with Read. Expected: a "Shortcuts" section with nine rows plus "Quick pick", each showing its default and a "Change…" button, then "Reset to defaults".

- [ ] **Step 5: Manual checklist (from the spec)**

Run `swift run ImperumTool` (with `DEVELOPER_DIR`), Settings › Clipboard:
1. Record ⌘⌥V for "Open the copy stack"; in another app ⌘⌥V opens the panel and ⌘⇧V no longer does. The trigger picker now reads "⌘⌥V".
2. Record plain V for "Open the copy stack": orange "Use ⌘, ⌃ or ⌥, or a function key", binding unchanged.
3. Record ⌘D for Delete; in the panel, ⌫ now edits the search query even when empty, ⌘D deletes the selection; footer shows "⌘D Delete".
4. Record ⌘W for Close; the panel closes on ⌘W (it was swallowed before).
5. Record ⌘D for Close as well: both rows show "Also used by …" in orange; ⌘D still deletes (Delete comes first).
6. Record ⌘⌥ + any key for Quick pick: rows show ⌥⌘1…; ⌥⌘2 pastes row two, ⌘2 no longer does.
7. Record a hotkey another running app owns (e.g. Spotlight's ⌘Space if enabled): the Open row shows "Already used by another app"; double-tap ⌘V and the menu-bar item still open the panel.
8. "Reset to defaults" restores every row and the footer.
9. Tap Gestures › a "Press keyboard shortcut" slot still records (recorder still works there, fn key still shown as 🌐).

- [ ] **Step 6: Commit**

```bash
git add Sources/ImperumTool/KeyComboRecorder.swift Sources/ImperumTool/TapGesturesSettingsTab.swift Sources/ImperumTool/ClipboardSettingsTab.swift Sources/ImperumTool/Settings.swift Sources/ImperumTool/AppController.swift
git commit -m "feat(clipboard): Shortcuts section in Settings with a shared KeyComboRecorder" -m "Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>" -m "Claude-Session: https://claude.ai/code/session_01ShdyPRmtWu8jp5YzevBUD4"
```

---

### Task 9: Documentation

**Files:**
- Modify: `README.md:44-51` (Copy Stack intro), `:85` area (terminal picker keys), `:142` (test count)
- Modify: `docs/superpowers/specs/2026-09-26-clipboard-history-design.md:280` (config keys)

- [ ] **Step 1: README**

Replace the first paragraph of "## Copy Stack (clipboard history)" (README lines 46–51) with:

```markdown
Copy several things, then choose what to paste. **Double-tap ⌘V** (or the
open-panel hotkey, ⌘⇧V by default, or a palm-rest tap bound to "Show Copy
Stack") opens a floating panel over the app you are in: search as you type,
←→ for category (Text · Links · Emails · Images · Videos · Files), ↑↓ to
move, ↩ or ⌘1–9 to paste, ⌘P to pin, ⌫ to delete, esc to close. Those are
the defaults: every one of them, and the hotkey, can be re-recorded in
Settings › Clipboard › Shortcuts (the terminal picker below keeps its own
fixed keys). Return pastes into the app you were in — files as files,
images as images.

Besides the global "Maximum stack size", each category can get its own cap
(Settings › Clipboard › Limit per category): once a category is over it,
its oldest unpinned clips are dropped automatically. Pinned clips never
count.
```

In the "### Terminal picker" section, after the sentence that starts "In the picker: type to search", append at the end of that paragraph: `These keys are fixed; the Shortcuts settings only apply to the floating panel.`

Update the test count line under "## Develop / test": `(382 tests)` → `(443 tests)` (179 ImperumCore + 264 CopyStackKit; re-check against the final run and use the real number).

- [ ] **Step 2: Old spec's config keys**

In `docs/superpowers/specs/2026-09-26-clipboard-history-design.md`, after the line ending `clipboardPaused` (false).` add:

```markdown
Added 2026-09-27 (see `2026-09-27-clipboard-limits-and-shortcuts-design.md`):
`clipboardCategoryLimits` ([String: Int], keyed by category, absent = off)
and `clipboardShortcuts` (the `PanelShortcuts` map, default = the keys above).
```

- [ ] **Step 3: Final full verification**

Run: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test 2>&1 | grep -E "Test Suite '(ImperumCoreTests|CopyStackKitTests)\.xctest' (passed|failed)" -A1`
Expected: both pass. Note the real totals and fix the README count if it differs.

Run: `./build.sh 2>&1 | tail -2` — this uses the default toolchain and will fail on the SwiftUI macro; if it does, run `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer ./build.sh 2>&1 | tail -2` instead.
Expected: `Built + signed: build/Imperum Tool.app`.

- [ ] **Step 4: Commit**

```bash
git add README.md docs/superpowers/specs/2026-09-26-clipboard-history-design.md
git commit -m "docs(clipboard): document per-category limits and configurable shortcuts" -m "Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>" -m "Claude-Session: https://claude.ai/code/session_01ShdyPRmtWu8jp5YzevBUD4"
```
