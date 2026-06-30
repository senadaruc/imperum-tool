# WindowServer Monitor — Design

**Date:** 2026-06-30
**Status:** Approved (pending spec review)

## Problem

On macOS, `WindowServer` (the system compositor) periodically spikes in
CPU, RAM, and GPU. When it does, the user wants to know **which app is
responsible**. The spikes are intermittent, so a tool you have to be
actively watching at the exact moment is insufficient — the tool must
*catch* the spike and record the suspects.

Today this is done with a bash script (`~/ws-watch.sh`) that shells out
to `/usr/bin/swift`, `ps`, `pgrep`, and `osascript` on every cycle. It
works for live triage but: re-compiles Swift every tick, mislabels
`ps`'s lifetime-average CPU as "CPU now", has no GPU signal, and has no
history so it can't catch intermittent spikes.

## Goal

A native Swift menu-bar app that:
1. Lives in the menu bar (no Dock icon), always-on, low overhead.
2. Shows at a glance: WindowServer CPU%, global GPU%, and the current
   top suspect app — e.g. `WS 42% · GPU 88% · Chrome`.
3. Ranks all on-screen apps by a "HEAVY" compositing-impact score.
4. **Automatically captures** the top suspects whenever WindowServer
   CPU or GPU crosses a threshold, so intermittent spikes are recorded.

## Non-goals (YAGNI)

- No preferences window (interval/threshold live in the menu).
- No persistence across launches (in-memory rolling spike log only).
- No auto-update, no charts/graphs, no notarization by default.
- No per-app GPU **percentage** — see "GPU reality" below.

## GPU reality on macOS

- **WindowServer CPU + RAM**: exact (single process, via `libproc`).
- **Global GPU utilization**: readable from `IOAccelerator`
  `PerformanceStatistics` (`Device Utilization %`) via IOKit — the same
  number Activity Monitor's GPU history shows.
- **Per-app GPU %**: NO public API exists. Activity Monitor uses private
  `IOReport`/GPUStats. We deliberately do not use private APIs. Instead,
  per-app compositing load is approximated by the reliable public
  proxies — **live CPU, total pixel area, window count** — which is what
  actually drives WindowServer's GPU compositing work.

## Architecture

`LSUIElement` SwiftUI/AppKit app. An `NSStatusItem` owns the menu-bar
title; a `Timer` drives a sampling loop; a background watcher captures
spikes. Each source is a focused, independently-testable unit.

```
~/WSMonitor/
├── project.yml                 # xcodegen spec (mirrors Fleet/imperum-mobile workflow)
├── Sources/
│   ├── AppDelegate.swift       # LSUIElement, NSStatusItem, timer loop, wiring
│   ├── WindowSampler.swift     # CGWindowListCopyWindowInfo → per-PID {wins, area}
│   ├── CPUSampler.swift        # libproc CPU-time delta → real instantaneous % + RSS
│   ├── GPUSampler.swift        # IOAccelerator PerformanceStatistics → global GPU%
│   ├── WindowServerStat.swift  # WindowServer PID + CPU/MEM/RSS
│   ├── HeavyScore.swift        # pure scoring function (one place for weights)
│   ├── SpikeLog.swift          # threshold watch + rolling top-N capture
│   ├── FrontApp.swift          # NSWorkspace.frontmostApplication
│   └── MenuView.swift          # SwiftUI dropdown: live table + Recent spikes + controls
├── Resources/Info.plist        # LSUIElement=true, LSMinimumSystemVersion
├── Tests/                      # SwiftPM unit tests (HeavyScore, CPU-delta math)
└── build.sh                    # xcodebuild Release + codesign Developer ID
```

### Data model

```
AppSample {
  pid: Int, name: String, windows: Int, area: Int,   // from WindowSampler
  cpu: Double, rss: Double,                           // from CPUSampler (delta)
  heavy: Double                                       // from HeavyScore
}
SpikeEvent { timestamp: Date, wsCPU: Double, gpu: Double, top: [AppSample] }
```

## Sampling loop

Every N seconds (default 5, configurable in-menu):
1. `WindowSampler` → per-PID window count + summed pixel area
   (on-screen, layer 0, area ≥ 5000 — same filters as the script).
2. `CPUSampler` → per-PID instantaneous CPU% (CPU-time delta between
   two reads ÷ wall-clock elapsed) + RSS. **The key fix over the
   script's lifetime-average `ps %cpu`.** First tick shows "—" until a
   delta exists.
3. `GPUSampler` → global GPU utilization %.
4. `WindowServerStat` → WindowServer CPU/RAM.
5. `HeavyScore` over each app, sort descending.
6. Update status-item title (`WS x% · GPU y% · TopApp`) with severity
   colour (green/yellow/red) and the dropdown table.
7. `SpikeLog.observe(wsCPU, gpu, ranked)` — if a threshold is crossed,
   append a `SpikeEvent`.

## HEAVY score

Preserve the script's formula (so behaviour is familiar), centralized
in `HeavyScore.swift` with the weights as named constants:

```
heavy = cpu*100 + area/100000 + windows*20 + rss/20
```

A tooltip in the dropdown shows the per-term breakdown for transparency.

## Spike capture

`SpikeLog` holds a rolling buffer (last 50 events). On each loop it
checks `wsCPU > cpuThreshold (default 60)` OR `gpu > gpuThreshold
(default 80)`. To avoid spamming during a sustained spike, it
de-dupes: a new event is only recorded if ≥ `coolDown` (default 30s)
since the last, or the top suspect changed. The dropdown's "Recent
spikes" section renders them newest-first:
`14:32 — WS 71% · GPU 91% — Chrome (12 wins · 8.3M px)`.

## Signing & build

`build.sh`:
1. `xcodegen` (regenerate project from `project.yml`).
2. `xcodebuild -configuration Release` → `WSMonitor.app`.
3. `codesign --options runtime --timestamp \
     --sign "Developer ID Application: Imperum B.V. (9TZGSR8224)" WSMonitor.app`
   — same identity that signed the custom Fleet Desktop agent.
4. Notarization is **optional** and not run by default (personal use,
   un-quarantined local launch). Notary key is available at
   `~/.appstoreconnect/private_keys/AuthKey_UB3PR8KXU8.p8` if the app is
   ever shared.

Output `WSMonitor.app` is dropped into `/Applications` and added to
Login Items manually (or via a one-liner the README provides).

## Testing

- SwiftPM unit tests for `HeavyScore` (pure function — exact expected
  scores for known inputs) and the CPU-delta arithmetic in `CPUSampler`
  (feed two synthetic CPU-time/wall-time pairs, assert the %).
- `GPUSampler`/`WindowSampler` are validated by manual run (they read
  live system state; assert non-crash + plausible ranges).
- Manual acceptance: launch, confirm menu-bar readout updates, force a
  GPU spike (e.g. a heavy WebGL page), confirm a spike event is logged
  with the right top suspect.

## Risks

- `IOAccelerator` stat keys vary by GPU vendor (Apple Silicon vs Intel
  vs eGPU). `GPUSampler` must enumerate accelerators and tolerate
  missing keys, falling back to "GPU —" rather than crashing.
- Multi-GPU machines: report the busiest accelerator (or sum) — decided
  at implementation; default to max utilization across accelerators.
