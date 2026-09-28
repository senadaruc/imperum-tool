# Caret-Anchored Copy Stack Bubble — Design

**Date:** 2026-09-28
**Status:** Implemented
**Extends:** `2026-09-26-clipboard-history-design.md` (Copy Stack panel)

## Problem

Double-tap ⌘V opens the Copy Stack as a 640 × 520 window centred on the
screen. When the trigger comes from inside a text field (a chat box, a
document, a form) that is far from where the user is looking and typing.
The requested feel is the macOS emoji picker or spelling suggestions: a
compact bubble right at the text cursor, with an arrow pointing at it.

## Goal

When the double-tap ⌘V trigger fires with a text field focused, the Copy
Stack opens as a compact bubble anchored to the insertion point, above or
below it depending on the room, with the same search / chips / list /
shortcuts as the full panel. Whenever no caret can be found, the existing
centred panel opens instead. Nothing about the trigger changes.

## Non-goals

- Changing how the panel is opened from the menu bar, a palm-rest tap, or
  the ⌘⇧V hotkey without Accessibility: those stay centred.
- Following the caret while the bubble is open (it stays where it opened).
- Any new permission: the double-tap already requires Accessibility, and
  the caret is read through the same permission.

## Caret lookup (`CaretLocator`, ImperumTool)

Synchronous, on the trigger's main-thread callback, before the panel is
shown (the panel is non-activating, so the user's field keeps focus either
way). Every AX round-trip is capped at 0.1 s (`AXUIElementSetMessagingTimeout`).

1. `AXIsProcessTrusted()` must be true; the front app must not be Imperum
   Tool itself.
2. Focused element: `kAXFocusedUIElementAttribute` on the system-wide
   element, then on the front app's element.
3. If that is not a text input, set `AXManualAccessibility` on the app
   element and look once more. Chromium, Electron and WebView2 apps (Teams,
   Slack, VS Code, browsers) only build their tree once asked.
4. A text input is a role in {AXTextField, AXTextArea, AXComboBox,
   AXSearchField}, or any element that answers
   `kAXSelectedTextRangeAttribute` and is not a container (AXWebArea,
   AXWindow, AXApplication, AXSheet, AXDrawer, AXScrollArea).
5. Caret bounds: `kAXBoundsForRangeParameterizedAttribute` for the first of
   `PanelPlacement.caretRangeCandidates` (the selection if any, the
   character at the caret, the one before, the empty range) that returns a
   rect with 0 < height < 500.
6. No bounds: the element's own frame (`AXWindow.frame(of:)`), so the
   bubble hangs off the field. Teams does this today.
7. Convert from AX (top-left origin, y down) to Cocoa with
   `AXCoordinates.cocoaRect`.

## Placement (`PanelPlacement`, ImperumCore, pure)

Input: caret rect and screen `visibleFrame` in Cocoa coordinates, the
content size 520 × 380, gap 6, arrow 10 tall × 20 wide, corner radius 12.

- Below the caret when the whole bubble fits; else above; if neither fits,
  the roomier side, clamped inside the screen.
- Horizontally centred on the caret, clamped to the screen.
- The arrow tip tracks `caret.midX`, clamped so it never enters the rounded
  corners (≥ radius + half the arrow width from either side).
- nil when the caret's centre is outside the screen → centred fallback.

## Panel (`CopyStackPanel`, `CopyStackView`)

- `Anchor.caret(CGRect)` joins `.mouseScreen` / `.mainScreen`. The screen is
  the one containing the caret's centre.
- Same `KeyablePanel` (borderless, non-activating, floating, key). Two
  looks on the same `NSVisualEffectView`:
  - full: `.hudWindow`, 14 pt corners, 640 × 520 (unchanged);
  - compact: `.popover` material, masked (`maskImage`) to a rounded rect
    with an isosceles arrow on the edge facing the caret. The window shadow
    follows the mask.
- `CopyStackModel.layout` (`.full` / `.compact(arrowEdge:arrowX:)`) drives
  `CopyStackView`: a 10 pt clear strip under the arrow, `.body` header
  instead of `.title3`, 12 pt paddings, 28 pt row glyphs, `.callout`
  titles, `.caption2` footer. Chips scroll horizontally without an
  indicator so they can never clip.
- Both looks fade in over 120 ms.
- Keys, dismissal, paste flow: unchanged.

## Settings

`ClipboardSettings.anchorToCaret` (default true, forward-compatible
decode). Settings › Clipboard › Capture & trigger: picker "Show the copy
stack as" with "Bubble at the text cursor" / "Popup centred on screen",
plus a caption explaining the fallback. Popup → the trigger opens the
centred panel as before.

`ClipboardSettings.showSearchField` (default true, forward-compatible
decode). Same section: toggle "Show the search field". Off removes the
"Type to search…" row from the header of both presentations; the clip
count moves to the trailing end of the chip row, unbound keys fall
through to nothing, and the chips, arrow keys and quick picks still work.

## Testing

- `PanelPlacementTests`: below / flipped above / clamped left and right /
  arrow kept out of the corners / neither side fits / off-screen → nil /
  zero-width caret / AX→Cocoa flip / range candidates at start, middle,
  end, unknown length, real selection.
- `ClipboardSettingsTests`: `anchorToCaret` and `showSearchField` default and round-trip.
- Manual, signed build: TextEdit caret mid-page → bubble below, arrow on
  the caret; Teams message box at the bottom → bubble above, arrow at the
  field; no text focus (Firefox page) → centred panel.
