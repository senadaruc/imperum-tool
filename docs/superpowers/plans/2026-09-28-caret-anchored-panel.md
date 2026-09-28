# Caret-Anchored Copy Stack Bubble — Implementation Plan

**Goal:** Open the Copy Stack as a compact bubble at the text cursor when the double-tap ⌘V trigger fires inside a text field; fall back to the centred panel otherwise.

**Spec:** `docs/superpowers/specs/2026-09-28-caret-anchored-panel-design.md`

**Build/test:** always `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test` (the CLT toolchain lacks XCTest).

- [x] 1. `PanelPlacementTests` then `Sources/ImperumCore/PanelPlacement.swift` (`place`, `caretRangeCandidates`, `AXCoordinates.cocoaRect`).
- [x] 2. `ClipboardSettings.anchorToCaret` + round-trip test.
- [x] 3. `Sources/ImperumTool/CaretLocator.swift` (focused element, Electron retry, role gate, bounds-for-range, frame fallback).
- [x] 4. `CopyStackPanel`: `Anchor.caret`, bubble mask on `.popover` material, fade-in. `CopyStackModel.layout`. `CopyStackView` compact metrics + arrow strip + scrolling chips.
- [x] 5. `ClipboardController`: read the caret in `tap.onOpenPanel` when `anchorToCaret`. Settings toggle "Open at the text cursor".
- [x] 6. Docs: this spec/plan, README Copy Stack section, pointer from the 2026-09-26 spec.
- [x] 7. Verify: full `swift test`; signed `./build.sh`; TextEdit (below), Teams (above), no text focus (centred).
