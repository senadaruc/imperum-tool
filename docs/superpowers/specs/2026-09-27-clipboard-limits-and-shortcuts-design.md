# Clipboard Per-Category Limits and Configurable Shortcuts — Design

**Date:** 2026-09-27
**Status:** Approved in conversation (pending spec review)
**Extends:** `2026-09-26-clipboard-history-design.md` (Copy Stack)

## Problem

Two gaps in the Copy Stack settings:

1. The stack has one global cap ("Maximum stack size") and a retention
   age. A user who copies many images can have them crowd out the text
   clips they actually come back for. There is no way to say "keep at most
   50 images" without also capping everything else.
2. Every key is hard-coded. The global hotkey is ⌘⇧V in `CmdVTap`; the
   in-panel keys (↑↓ ←→ ↩ ⌘P ⌫ esc ⌘1–9) are literal key codes and
   characters in `CopyStackPanel.route`. A user whose other apps already
   own ⌘⇧V, or who wants ⌘D to delete, cannot change any of it.

## Goal

1. An optional cap per category (Text, Links, Emails, Images, Videos,
   Files). When a category is over its cap, its oldest unpinned clips are
   dropped automatically, exactly as the global cap does today. Off by
   default so nothing changes for existing users.
2. A recordable shortcut for every panel action and for the open-panel
   hotkey, edited in Settings › Clipboard with the same recorder the Tap
   Gestures tab already uses. Defaults equal today's keys.

## Non-goals

- Rebinding the terminal picker (`copystack`). It has its own key model in
  `CopyStackKit`, cannot see ⌘, and follows terminal conventions. Its keys
  stay fixed; the README says so.
- Changing the double-tap trigger key. Double-tap ⌘V is tied to paste
  semantics (hold, then replay a real ⌘V); it stays ⌘V.
- Per-category retention ages. Retention days stay global.
- Multiple bindings per action, or chords.

## Part A — per-category limits

### Data model (`ImperumCore`)

- `ClipLimits` gains `perCategory: [ClipCategory: Int]` (default empty).
  A category absent from the dictionary has no cap. `ClipCategory.all` is
  never a key.
- `ClipCategory` gains `init(kind: ClipKind)`: `text` and the legacy
  `color` → `.text`, `link` → `.links`, `email` → `.emails`,
  `image` → `.images`, `video` → `.videos`, `file` → `.files`. (The panel
  already shows colour clips under Text; limits follow the same rule.)
- `ClipboardSettings` gains `categoryLimits: [String: Int]`, keyed by
  `ClipCategory.rawValue` for stable JSON. Set-clamping keeps each value in
  10…2000 and drops keys that are `"all"` or not a category. Absent from
  older JSON → empty, meaning off. `ClipboardSettings.limits` builds
  `perCategory` from it.

### Enforcement (`ClipStore.enforce`)

The existing single pass over `clips` (newest first) gains one counter per
category alongside the global `unpinnedSeen`:

```
keep = !pinned
     ? unpinnedSeen <= maxStack
       && capturedAt >= cutoff
       && (cap(category) == nil || seen[category] <= cap(category))
     : true
```

Pinned clips remain exempt from every limit and are not counted. Dropped
blobs are reported through `onBlobsDropped` as today. Because
`ClipboardController.apply` already calls `store.enforce` on every settings
change, lowering a cap in Settings takes effect immediately, and
`insert` enforces on every capture.

### Settings UI (`ClipboardSettingsTab`)

Directly under "Maximum stack size", a `DisclosureGroup("Limit per
category")` with one row per category (Text, Links, Emails, Images, Videos,
Files): a `Toggle` and, when on, a `Stepper` in 10…2000 step 10. Turning a
toggle on writes 100; turning it off removes the key. A caption under the
group: "Pinned clips never count. The global maximum still applies."

## Part B — configurable shortcuts

### Model (`ImperumCore/PanelShortcuts.swift`)

```swift
public enum PanelAction: String, Codable, CaseIterable {
    case openPanel                     // global hotkey
    case up, down, previousCategory, nextCategory
    case paste, pin, delete, close     // in-panel
}

public struct PanelShortcuts: Codable, Equatable {
    public var bindings: [PanelAction: KeyCombo]
    /// Modifier bits held with a digit 1–9 to paste that row. Digits are fixed.
    public var quickPickModifiers: UInt
    public static let defaults: PanelShortcuts
    public func combo(for: PanelAction) -> KeyCombo
    /// In-panel lookup; never returns `.openPanel`.
    public func action(keyCode: UInt16, modifiers: UInt) -> PanelAction?
    /// Actions that share a combo with another action (quick-pick modifiers
    /// clash with a binding whose key is a digit and whose modifiers match).
    public var conflictingActions: Set<PanelAction>
    public static func problem(with: KeyCombo, for: PanelAction) -> ShortcutProblem?
    public var quickPickDisplay: String   // e.g. "⌘1–9"
}

public enum ShortcutProblem: Equatable {
    case hotkeyNeedsModifier      // openPanel: needs ⌘, ⌃ or ⌥, or an F-key
    case printableNeedsModifier   // in-panel: a bare printable key would be untypeable in search
}
```

- `KeyCombo` (already in `TapAction.swift`) is reused unchanged: macOS
  virtual key code, raw `NSEvent.ModifierFlags`, display string.
- **Modifier normalisation.** Stored and compared modifiers are masked to
  ⌘ ⇧ ⌥ ⌃ only (`command | shift | option | control`). `.function`,
  `.numericPad`, `.capsLock` and `.help` are dropped, because arrow keys
  and F-keys carry `.function`/`.numericPad` on their own. The fn/🌐 key is
  therefore not a usable modifier for these bindings.
- **Defaults** (today's keys): openPanel ⌘⇧V (9), up ↑ (126), down ↓ (125),
  previousCategory ← (123), nextCategory → (124), paste ↩ (36), pin ⌘P (35),
  delete ⌫ (51), close ⎋ (53), quickPickModifiers ⌘.
- **Validation.** `problem(with:for:)` returns `.hotkeyNeedsModifier` for
  `openPanel` unless the combo has ⌘, ⌃ or ⌥, or its key code is F1–F19.
  For in-panel actions it returns `.printableNeedsModifier` when the combo
  has no ⌘/⌃/⌥ and the key is not one of the non-printing keys (arrows,
  ↩, keypad ↩, ⇥, ⌫, ⌦, ⎋, Home, End, Page Up/Down, F1–F19, Space is
  treated as printable). ⇧ alone does not count as a modifier. Quick-pick
  modifiers must be non-empty after normalisation.
- **Coding.** Encoded as `{"bindings": {"pin": {...}, ...},
  "quickPickModifiers": n}`. Decoding ignores unknown action keys, fills
  missing actions from `defaults`, and applies normalisation. Any combo
  that fails validation on decode is replaced by its default.
- `ClipboardSettings.shortcuts: PanelShortcuts` (default `.defaults`),
  decoded with `decodeIfPresent` like every other key.

### Global hotkey (`CmdVTap`)

- `start(doubleTap: Bool, hotkey: KeyCombo?)` replaces the `Bool` pair.
  `installHotKey(_:)` maps normalised modifiers to Carbon
  (`cmdKey`, `shiftKey`, `optionKey`, `controlKey`) and registers the key
  code. It returns the `OSStatus`; `CmdVTap` exposes `hotkeyError: String?`
  ("Already used by another app" for `eventHotKeyExistsErr`, otherwise the
  status number).
- `ClipboardController.apply` widens `lastApplied` to include the open-panel
  combo so a change restarts the tap. It publishes `hotkeyError` for the
  settings tab.

### Panel routing (`CopyStackPanel.route`)

Order of evaluation, first match wins:

1. Normalise the event's modifiers, look up
   `shortcuts.action(keyCode:modifiers:)`. Keypad Enter (76) is tried as
   Return (36) when its own code has no binding. A hit dispatches to
   `PanelModel.handle(key:)` with one rule kept from today: `.delete`
   whose binding is plain ⌫ or plain ⌦ fires only when the search query is
   empty; otherwise the key edits the query.
2. Quick pick: modifiers equal `quickPickModifiers` and
   `charactersIgnoringModifiers` is "1"…"9" → `.digit(n)`.
3. Existing fallbacks, unchanged: ⌘V/C/X/A routed to the search field's
   editor; ⌘Q, ⌘W, ⌘, and ⌘0 swallowed by character.
4. Everything else goes to the search field.

Because bindings are matched first, a user binding ⌘W to Close makes ⌘W
close the panel rather than being swallowed. `PanelModel` gets a
`shortcuts` property that `ClipboardController` sets on every apply.

### Footer hints and row badges (`CopyStackView`)

The footer renders each hint from `shortcuts.combo(for:).display`
(Navigate shows up/down, Category shows left/right, Paste, Pin, Delete,
Close) and the first nine rows show `quickPickDisplay`'s modifier glyphs
plus the digit. No literal key strings remain in the view.

### Settings UI

- `KeyComboRecorder` moves from `TapGesturesSettingsTab.swift` into its own
  `KeyComboRecorder.swift` (internal, not private) and gains an optional
  `validate: (KeyCombo) -> ShortcutProblem?` closure: a rejected combo is
  not stored and the recorder shows the problem's message in orange until
  the next recording. Its modifier normalisation adopts the rule above.
- New `Section("Shortcuts")` in `ClipboardSettingsTab`, after "Capture &
  trigger": one `LabeledContent` row per `PanelAction` (Open the copy
  stack, Move up, Move down, Previous category, Next category, Paste, Pin,
  Delete, Close) with a `KeyComboRecorder`, plus a "Quick pick" row whose
  recorder keeps only the modifiers and displays e.g. "⌘1–9". Rows in
  `conflictingActions` show "Also used by <action>" in orange. A "Reset to
  defaults" button restores `PanelShortcuts.defaults`. When `hotkeyError`
  is set, it appears under the Open row.
- The trigger picker's second choice reads the recorded open-panel combo
  (`shortcuts.combo(for: .openPanel).display`) instead of the literal
  "⌘⇧V"; the same for the double-tap caption, which stays "Double-tap ⌘V".

## Error handling

- Hotkey registration fails → the panel is still reachable by double-tap,
  the menu-bar item, the Tap Gesture action and `copystack`; Settings shows
  the reason. No alert.
- Corrupt or partial `shortcuts` JSON → per-action fallback to defaults,
  never a wholesale reset of other clipboard settings.
- Two actions bound to the same combo are allowed to persist (the user may
  be mid-edit) but are flagged; at runtime the first `PanelAction` in
  `CaseIterable` order wins, so behaviour is deterministic.
- A category cap larger than the global cap is legal and simply never
  binds.

## Testing

`ImperumCoreTests`:
- `ClipStoreTests`: per-category cap drops that category's oldest unpinned
  clip only; other categories untouched; pinned clip in a full category is
  kept and not counted; a `color` clip counts toward Text; global cap and
  category cap together; lowering a cap via `enforce` drops immediately;
  dropped image blobs reported.
- `ClipQueryTests`: `ClipCategory(kind:)` for every `ClipKind`.
- `ClipboardSettingsTests`: `categoryLimits` clamping and key filtering;
  older JSON without the key decodes to empty; round trip; `shortcuts`
  absent decodes to defaults; unknown action key ignored; invalid combo on
  decode replaced by default.
- `PanelShortcutsTests`: defaults equal today's keys; lookup with
  `.function`/`.numericPad` noise on arrows; keypad Enter handled by the
  caller not the model (documented); `conflictingActions` including a
  digit binding versus quick-pick modifiers; every `ShortcutProblem` case;
  Codable round trip; `quickPickDisplay`.

Manual checklist (goes into the plan): record ⌘⌥V as the hotkey and open
the panel with it; record a combo another app owns and see the caption;
rebind Delete to ⌘D and confirm ⌫ now edits the search query; bind Close
to ⌘W and confirm the panel closes instead of swallowing it; footer hints
change as bindings change; Reset to defaults; set Images to 10, copy 12
images, confirm the two oldest unpinned are gone and pinned ones remain;
`copystack` picker keys unchanged.

## Documentation

- README "Copy Stack" section: keys are described as defaults and point to
  Settings › Clipboard › Shortcuts; add the per-category limit; note the
  terminal picker's keys are fixed.
- The 2026-09-26 spec's "Config keys" list gains `clipboardCategoryLimits`
  and `clipboardShortcuts` by reference to this document.
