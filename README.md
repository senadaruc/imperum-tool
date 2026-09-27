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

Copy several things, then choose what to paste. **Double-tap ⌘V** (or the
open-panel hotkey, ⌘⇧V by default, or a palm-rest tap bound to "Show Copy
Stack") opens a floating panel over the app you are in: search as you type,
←→ for category (Text · Links · Emails · Images · Screenshots · Videos · Files), ↑↓ to
move, ↩ or ⌘1–9 to paste, ⌘P to pin, ⌫ to delete, esc to close. Those are
the defaults: every one of them, and the hotkey, can be re-recorded in
Settings › Clipboard › Shortcuts (the terminal picker below keeps its own
fixed keys). Return pastes into the app you were in — files as files,
images as images.

Besides the global "Maximum stack size", each category can get its own cap
(Settings › Clipboard › Limit per category): once a category is over it,
its oldest unpinned clips are dropped automatically. Pinned clips never
count.

Screenshots get their own category. Whether you copy one (⌃⇧⌘3/4, or
CleanShot X with copy-after-capture) or save it to a file (⇧⌘3/4, or any
CleanShot X capture), it lands in the stack automatically, attributed to
"Screenshot" or "CleanShot X" rather than the app that was in front, ready
to paste as an image. The tool watches the macOS screenshot location (the
Desktop unless you changed it) and CleanShot's media and export folders; it
never moves or deletes the files, and it never imports shots taken before
it was running. Settings › Clipboard › "Capture screenshots saved to disk"
turns the folder watching off; copied screenshots are captured regardless.

Upgrading: builds from before the Screenshots category treat a screenshot
clip in the saved history as corruption and start over with an empty
history. Once this version has run, don't launch an older build. From this
version on, a clip type the running build doesn't know is skipped instead.

Privacy: nothing leaves this Mac. Anything a password manager marks concealed
or transient is never captured, apps on the exclusion list are ignored, and
the history lives in `~/Library/Application Support/Imperum Tool/Clipboard/`
encrypted with AES-GCM under a key in your login Keychain. Website icons for
links are opt-in (they contact the link's domain). "Clear stack when Imperum
Tool quits" gives session-only memory.

Exclusions cover both applications and websites (Settings › Clipboard ›
Privacy). A website entry is a hostname shown as `*.example.com` and matches
that site plus all its subdomains; a copy made while a browser page on an
excluded site is frontmost is skipped the same way a copy in an excluded
application is. The page's URL is read through Accessibility, from the first
web area found in the front window — so this isn't limited to browsers as
such, it applies to whatever page is in front, in any app that hosts one
(Mail, an Electron app, etc). Double-tap ⌘V's Accessibility permission covers
this too; without it, website exclusions simply don't match anything.
Verified against Safari, Google Chrome, Firefox and Brave.

The double-tap needs Accessibility (to hold a ⌘V for ~300 ms and decide if a
second tap follows); the ⌘⇧V hotkey does not.

### Terminal picker (`copystack`)

Turn on "Use a terminal picker when a terminal app is in front" (Settings ›
Clipboard › Terminal) and the double-tap ⌘V / ⌘⇧V trigger opens a new window
of that terminal running the picker instead of the floating panel, whenever
the frontmost app is **Ghostty, cmux, iTerm2, kitty, or Terminal**. Warp has
no scriptable window picker, so it always gets the panel. macOS asks once per
terminal app to let Imperum Tool control it (System Settings › Privacy &
Security › Automation); denying it falls back to the panel, and Settings
shows that terminal's status.

In the picker: type to search (search covers up to the first 2 KiB of a
clip), ↑↓ / ^N ^K ^J to move, ←→ for category, PgUp/PgDn/Home/End, ⏎ to
paste (copies in `--copy` mode, prints to stdout otherwise), Alt+1–9 for a
quick pick, ^P to pin, ^D to delete, ^U to clear the query, Esc/^C to cancel.
These keys are fixed; the Shortcuts settings only apply to the floating panel.
`NO_COLOR` is honoured. The window needs at least 40 columns × 8 rows.

`copystack` is also a standalone CLI you can use outside the double-tap
trigger:

    copystack                    # interactive picker; prints the picked clip to stdout
    copystack --paste            # interactive picker; pastes into the frontmost app
    copystack --copy             # interactive picker; copies to the system clipboard
    copystack list [--json] [--limit N]
    copystack --version
    copystack --help

Exit codes: `0` success, `1` a usage error (or an image was picked in
stdout mode, or there's no controlling terminal, or input closed), `2`
Imperum Tool isn't running, command-line access is off, or the
connection was lost at any point, `130` cancelled with Esc/^C.

Install it once from Settings › Clipboard › Terminal ("Install command-line
tool…", which symlinks `/usr/local/bin/copystack`), or by hand:

    ln -s "/Applications/Imperum Tool.app/Contents/MacOS/copystack" /usr/local/bin/copystack

tmux panes can't be targeted directly by the double-tap trigger, so bind a
popup instead:

    bind-key V display-popup -E -w 100 -h 30 "copystack | tmux load-buffer - && tmux paste-buffer -p"

`copystack` talks to Imperum Tool over a private Unix socket at
`~/Library/Application Support/Imperum Tool/copystack.sock` (mode `0600`,
reachable only by your own user account; override with
`IMPERUM_COPYSTACK_SOCK`). It runs only while both "Enable clipboard
history" and "Allow command-line access" are on, and is removed when the
app quits.

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

    swift test                 # ImperumCore logic + samplers + tap detector + CopyStackKit (466 tests)
    swift run ImperumTool        # run from source
