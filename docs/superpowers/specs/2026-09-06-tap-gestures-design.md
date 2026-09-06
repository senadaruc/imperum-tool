# Tap Gestures — Design

**Date:** 2026-09-06
**Status:** Approved (user said "build with these features")

## Goal

Tap the MacBook chassis (left or right palm rest) 1, 2 or 3 times to run an
action. Six slots (LEFT ×1/×2/×3, RIGHT ×1/×2/×3), each mapped to one of
50+ built-in actions or a user-supplied keyboard shortcut / app / URL /
Apple Shortcut. Added to Imperum Tool so no separate always-on app is needed.

## Feasibility (verified 2026-09-06 on Mac17,7 / macOS 26.6.2)

The Sensor Processing Unit exposes an accelerometer (HID usage page 0xFF00,
usage 3) and a gyroscope (0xFF00 / 9). Both stream at ~100 Hz to an
unsandboxed user process via the private IOKit API
`IOHIDEventSystemClientCreateWithType(type = 1 monitor)` +
`IOHIDEventSystemClientSetMatchingMultiple` +
`IOHIDEventSystemClientRegisterEventCallback`. Event type 13 = accelerometer,
20 = gyro; fields `(type << 16) + {0,1,2}` are x/y/z. Noise floor at rest is
~0.001 g, so a fingertip tap (≥0.05 g impulse) is unambiguous.

Consequences: private API ⇒ Developer ID distribution only (already the
case). Apple Silicon MacBooks only; on any Mac without these sensors the
feature reports "not available" and stays inert.

## Non-goals

- No global "any side" mode — the product is the six-slot map.
- No gesture other than taps (no swipes, no knocks patterns beyond ×3).
- No App Store build.
- "Current weather" opens the Weather app rather than fetching a forecast
  (avoids a location prompt and a network dependency).

## Architecture

Follows the repo split: pure, testable logic in `ImperumCore`; system-framework
glue in the `ImperumTool` executable.

### ImperumCore (pure)

- `TapDetector.swift` — `MotionSample`, `TapImpulse`, `TapEvent`,
  `TapDetectorConfig`, `TapDetector`. Feed accelerometer and gyro samples;
  it high-passes the accelerometer (EMA gravity removal), detects impulses
  over a threshold with a refractory period, captures the peak feature
  vector within a 60 ms window, groups impulses into ×1/×2/×3 events
  (350 ms grouping window, emit at 3 immediately, ignore extras for 400 ms),
  and classifies side via `SideClassifier`. A `suppressor` closure lets the
  app veto impulses (typing / click suppression) without the detector
  knowing about CoreGraphics.
- `SideCalibration.swift` — `SideCalibration` (Codable: which feature,
  which sign means LEFT) and `calibrateSides(left:right:)` which picks,
  among accel-x / gyro-x / gyro-y / gyro-z peak values, the feature with
  the best left/right separation. `SideClassifier` uses it; uncalibrated
  default = sign of gyro-y.
- `TapAction.swift` — `TapAction { kind, text, keyCombo }`, `TapAction.Kind`
  (52 cases incl. `none` and `flashlight`), `ActionCategory`, display names,
  `needsParameter`. `KeyCombo { keyCode, modifiers, display }`.
- `TapMap.swift` — six slots keyed by `TapSide` + count; default map from
  the product page. `TapSettingsStore` (ObservableObject, UserDefaults JSON
  under `imperumTool_tapGestures_v1`): `enabled`, `threshold`, `map`,
  `calibration`.

### ImperumTool (glue)

- `MotionSensor.swift` — dlsym wrapper over the private IOHID event-system
  API; runs its own thread + run loop; delivers samples on a serial queue.
  `isAvailable` is false when no accelerometer service matches.
- `TapGestureController.swift` — owns `MotionSensor` + `TapDetector`;
  suppression via `CGEventSource.secondsSinceLastEventType` (public API, no
  permission) for keyDown / mouseDown within 250 ms; runs actions through
  `ActionRunner`; exposes `@Published lastTap` and a calibration state
  machine (collect 5 left impulses, then 5 right, then save) for the UI.
- `ActionRunner.swift` — one `run(_ action:)` switch. Building blocks:
  `pressKey(code, flags)` (CGEvent), `mediaKey(nx)` (NX system-defined
  event), AX window tiling (`AXUIElement` position/size), `shell(path,args)`,
  `openApp(path)`, `openURL`, `runShortcut(name)` (`/usr/bin/shortcuts run`),
  CoreWLAN Wi-Fi toggle, IOBluetooth private power toggle, CoreAudio mic
  mute, `NSWorkspace.unmountAndEjectDevice`, Finder empty-trash AppleScript,
  IOKit battery read, app-switcher stepping (⌘ held across taps, released
  after 1.5 s idle).
- `HUD.swift` — small non-activating panel for one-line feedback
  ("Battery 82% · charging", "Mic muted"); auto-hides.
- `Flashlight.swift` — toggles full-white borderless windows on every screen.
- `TapGesturesSettingsTab.swift` — enable toggle, sensitivity slider,
  sensor/Accessibility status, live "last tap" readout, guided calibration,
  and the six-slot map with per-slot parameter editors (key recorder,
  app chooser, URL / shortcut name fields).
- `Settings.swift` — `SettingsTabs.makeController` builds a native
  preferences-style `NSTabViewController` (`.toolbar`): General, Tap
  Gestures, External Volumes. The former `SettingsView` body moves
  unchanged into `GeneralSettingsTab`.
- `AppController` — constructs `TapSettingsStore` and `TapGestureController`
  at launch (like the volume blocker).

## Permissions

- **Accessibility** is required for simulated keystrokes, media keys and AX
  window tiling. Prompted on first such action via
  `AXIsProcessTrustedWithOptions`; the settings tab shows the status.
- **Automation (Finder)** is prompted by macOS on first Empty Trash.
- No permission is needed for the motion sensors, Wi-Fi, mic mute, eject,
  open app / URL, `shortcuts run`, `pmset displaysleepnow`.

## Error handling

- Sensor unavailable / private symbols missing → feature disabled with a
  visible reason in Settings; nothing crashes.
- Action failures (no front window, shortcut not found, Bluetooth symbols
  missing) → HUD message, logged via `NSLog`.
- Detection stops while calibration collects samples; calibration can be
  cancelled.

## Testing

- `TapDetectorTests`: synthetic 100 Hz streams — one tap → ×1; two taps
  200 ms apart → ×2; three → ×3 emitted immediately; noise under threshold →
  nothing; suppressor veto → nothing; refractory prevents double count from
  ringing.
- `SideCalibrationTests`: synthetic left/right impulse sets → picks the
  separating feature and the correct sign; classifier then labels new
  impulses; degenerate (no separation) → nil.
- `TapActionTests`: every `Kind` has a category and display name; Codable
  round-trip of a map with parameterised actions; default map matches the
  product page.
- `TapSettingsStoreTests`: isolated `UserDefaults` suite round-trip.
- Manual: run calibration, verify each of the six slots fires the mapped
  action; type quickly and confirm no false taps.
