# WSMonitor

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

## Why no per-app GPU %

Apple exposes **no per-app GPU% on Apple Silicon** — even `powermetrics`
reports per-process `GPU ms/s = 0`. So WSMonitor uses pixel-area + CPU +
correlation as proxies, `SIGSTOP` pause-and-watch for proof, and (optionally)
`powermetrics` **Energy Impact** — Apple's combined CPU+GPU+ANE power cost —
as the authoritative per-process signal. WindowServer's own CPU is read
sudolessly via `sysctl` + `ps` cputime deltas (`proc_pid_rusage` is
permission-denied on it); GPU util/mem via `IOAccelerator` (IOKit).

## Build

    ./build.sh                 # SwiftPM release → build/WSMonitor.app, Developer ID signed
    ./notarize.sh              # optional: notarize + staple (only to share the .app)
    cp -R build/WSMonitor.app /Applications/
    open /Applications/WSMonitor.app

It's a regular app: **Dock icon** (click → reopens window), **menu-bar gauge**,
and a window. Closing the window doesn't quit it (background monitor). Quit
with ⌘Q or the Dock menu. Add to Login Items to keep it always-on.

## Deep GPU capture (optional, privileged)

Click **Enable deep GPU capture** → one native admin-password prompt installs:
- a **root-owned** wrapper `/usr/local/libexec/wsmonitor-powermetrics` with a
  fixed argv (ignores all arguments), and
- a scoped sudoers rule allowing **only that wrapper with no args**
  (`/etc/sudoers.d/wsmonitor`).

The app then runs `powermetrics` each tick to show per-process Energy Impact.
Click **Disable** to remove both. No XPC, no daemon; the privileged command
can't take arguments or write files.

## Develop / test

    swift test                 # WSCore logic + samplers (30 tests)
    swift run WSMonitor        # run from source
