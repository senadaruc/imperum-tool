# Imperum Tool

A macOS menu-bar + window app that finds **which app drives WindowServer
CPU/RAM/GPU spikes**. Built for Apple Silicon (verified on M3 Max, macOS 26).

Design + research live in `docs/superpowers/specs/`; the build plan in
`docs/superpowers/plans/`.

## What it shows

Pinned header: WindowServer **CPU · RAM · GPU% · GPU mem**, plus a **Likely
culprit** card (the app most correlated with your spikes). Menu-bar gauge +
number, color-coded by severity. Below (scrollable):

- **Top suspects** ranked by a HEAVY compositing score
  (`N Open Windows · % CPU · M px`), per display
- **Most correlated with spikes** — Pearson correlation of each app's
  activity against WindowServer's, over a rolling window
- **Recent spikes** — auto-captured when WindowServer CPU > 60% or GPU > 80%
- **Pause** on any suspect → `SIGSTOP` it ~4s and watch if WindowServer
  drops (the one test that *proves* causation)
- **Power cost by process** (when deep capture is enabled) — per-process
  Energy Impact from `powermetrics`

## Tap gestures (Apple Silicon MacBooks)

Tap the palm rest to run an action — **Settings → Tap Gestures**. Six slots:
LEFT ×1/×2/×3 and RIGHT ×1/×2/×3, each mapped to one of 50+ built-in actions
(screenshots, clipboard, media keys, mic mute, brightness, window tiling,
Spaces, lock/sleep, Wi-Fi/Bluetooth, eject, Empty Trash, battery HUD,
flashlight…) or a custom keyboard shortcut, app, URL, or Apple Shortcut.

How it works: the Sensor Processing Unit's accelerometer + gyro stream at
~100 Hz through the private `IOHIDEventSystemClient` API (no entitlement
needed, but Developer ID only — never App Store). `TapDetector` high-passes
the signal, groups impulses into ×N events, and ignores anything within ¼ s
of a keypress or click. Left/right is learned by a 10-tap **calibration**
in Settings (the sensor sits in the lid, so the sign convention differs per
model). Keystroke, media-key and window actions need **Accessibility**
access; the tab shows the status and a button to grant it.

Design: `docs/superpowers/specs/2026-09-06-tap-gestures-design.md`.

## Copy Stack (clipboard history)

Copy several things, then choose what to paste. **Double-tap ⌘V** (or ⌘⇧V,
or a palm-rest tap bound to "Show Copy Stack") opens a floating panel over the
app you are in: search as you type, ←→ for category (Text · Links · Emails ·
Images · Videos · Files), ↑↓ to move, ↩ or ⌘1–9 to paste, ⌘P to pin,
⌫ to delete, esc to close. Return pastes into the app you were in — files as
files, images as images.

Privacy: nothing leaves this Mac. Anything a password manager marks concealed
or transient is never captured, apps on the exclusion list are ignored, and
the history lives in `~/Library/Application Support/Imperum Tool/Clipboard/`
encrypted with AES-GCM under a key in your login Keychain. Website icons for
links are opt-in (they contact the link's domain). "Clear stack when Imperum
Tool quits" gives session-only memory.

The double-tap needs Accessibility (to hold a ⌘V for ~300 ms and decide if a
second tap follows); the ⌘⇧V hotkey does not.

## Why no per-app GPU %

Apple exposes **no per-app GPU% on Apple Silicon** — even `powermetrics`
reports per-process `GPU ms/s = 0`. So Imperum Tool uses pixel-area + CPU +
correlation as proxies, `SIGSTOP` pause-and-watch for proof, and (optionally)
`powermetrics` **Energy Impact** — Apple's combined CPU+GPU+ANE power cost —
as the authoritative per-process signal. WindowServer's own CPU is read
sudolessly via `sysctl` + `ps` cputime deltas (`proc_pid_rusage` is
permission-denied on it); GPU util/mem via `IOAccelerator` (IOKit).

## Build

    ./build.sh                 # SwiftPM release → "build/Imperum Tool.app", Developer ID signed
    ./notarize.sh              # optional: notarize + staple (only to share the .app)
    cp -R "build/Imperum Tool.app" /Applications/
    open "/Applications/Imperum Tool.app"

It's a regular app: **Dock icon** (click → reopens window), **menu-bar gauge**,
and a window. Closing the window doesn't quit it (background monitor). Quit
with ⌘Q or the Dock menu. Add to Login Items to keep it always-on.

## Deep GPU capture (optional, privileged)

Click **Enable deep GPU capture** → one native admin-password prompt installs:
- a **root-owned** wrapper `/usr/local/libexec/imperum-tool-powermetrics` with a
  fixed argv (ignores all arguments), and
- a scoped sudoers rule allowing **only that wrapper with no args**
  (`/etc/sudoers.d/imperum-tool`).

The app then runs `powermetrics` each tick to show per-process Energy Impact.
Click **Disable** to remove both. No XPC, no daemon; the privileged command
can't take arguments or write files.

## Develop / test

    swift test                 # ImperumCore logic + samplers + tap detector (69 tests)
    swift run ImperumTool        # run from source
