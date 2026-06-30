# WSMonitor

A sudoless macOS menu-bar app that finds **which app drives WindowServer
CPU/RAM/GPU spikes**. Built for Apple Silicon (verified on M3 Max, macOS 26).

Design + research live in `docs/superpowers/specs/`; the build plan in
`docs/superpowers/plans/`.

## What it shows

Menu bar: `WS 42% · GPU 88% · Chrome` (green/yellow/red by severity).

Dropdown:
- WindowServer CPU / RAM / GPU memory
- **Top suspects** ranked by a HEAVY compositing score (CPU, pixel area,
  window count, RAM) — per display
- **Most correlated with spikes** — the app whose activity statistically
  tracks WindowServer's spikes (Pearson correlation over a rolling window)
- **Recent spikes** — auto-captured whenever WindowServer CPU > 60% or GPU
  > 80%, so intermittent spikes are recorded even when you're not looking
- Click any suspect to **pause it ~4s (SIGSTOP)** and watch whether
  WindowServer CPU drops — the one test that *proves* causation

## Why it works without sudo

`proc_pid_rusage` is permission-denied on WindowServer (it runs as
`_windowserver`). WSMonitor instead finds it via `sysctl(KERN_PROC_ALL)`
and computes instantaneous CPU from `ps` cumulative-CPU-time deltas. GPU
util + memory come from `IOAccelerator` performance statistics (IOKit).
No per-app GPU% is claimed — Apple exposes none publicly on Apple Silicon;
correlation + pause-and-watch substitute for it.

## Build

    ./build.sh

Produces `build/WSMonitor.app`, signed with
`Developer ID Application: Imperum B.V. (9TZGSR8224)`. Install:

    cp -R build/WSMonitor.app /Applications/
    open /Applications/WSMonitor.app

Add to Login Items: System Settings → General → Login Items → +.

## Develop / test

    swift test     # fast unit suite (WSCore logic + samplers)
    swift run WSMonitor   # run from source

## Optional: deep GPU capture (Phase B)

A privileged helper can capture authoritative per-process GPU/energy from
`powermetrics` at each spike. Not required — the app is fully useful
without it. See the plan, Phase B.
