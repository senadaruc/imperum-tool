# WindowServer Monitor — Design

**Date:** 2026-06-30
**Status:** Approved (pending spec review)
**Companion:** see `2026-06-30-attribution-research.md` for the verified
per-app GPU findings that drive this design.

## Problem

On macOS, `WindowServer` (the system compositor) periodically spikes in
CPU, RAM, and GPU. When it does, the user wants to know **which app is
responsible**. The spikes are intermittent, so a tool you have to be
actively watching at the exact moment is insufficient — the tool must
*catch* the spike and prove the cause.

Today this is done with a bash script (`~/ws-watch.sh`) that shells out
to `/usr/bin/swift`, `ps`, `pgrep`, and `osascript` on every cycle. It
re-compiles Swift every tick, mislabels `ps`'s lifetime-average CPU as
"CPU now", has no GPU signal, and has no history so it can't catch
intermittent spikes.

## Target machine (verified)

Apple M3 Max (Mac15,8), macOS 26.5.1, 40-core GPU, Metal 4. Displays:
**7680×3240** + **3840×2160** (~33M pixels). The huge panel is the
prime suspect for compositing-driven spikes — the design surfaces
per-display load explicitly.

## Goal

A native Swift menu-bar app that:
1. Lives in the menu bar (no Dock icon), always-on, low overhead.
2. Shows at a glance: WindowServer CPU%, global GPU%, top suspect —
   e.g. `WS 42% · GPU 88% · Chrome`.
3. Ranks on-screen apps by a "HEAVY" compositing-impact score, per display.
4. **Automatically captures** suspects when WindowServer CPU/GPU crosses
   a threshold, so intermittent spikes are recorded.
5. **Proves causation** via a correlation engine and a one-click
   SIGSTOP quit-and-watch, plus an authoritative powermetrics snapshot.

## GPU reality (why the architecture is shaped this way)

Verified on this machine: **no public per-app GPU% on Apple Silicon**
(`SurfaceList` absent on AGX; `powermetrics --show-process-gpu` needs
sudo and is flaky). So attribution = global spike signal + per-app
proxies + statistical correlation + a privileged ground-truth snapshot.
Full table in the research doc.

## Non-goals (YAGNI)

- No preferences window (interval/threshold live in the menu).
- No cross-launch persistence (in-memory rolling spike log only).
- No auto-update, no charts/history graphs.
- No per-app GPU **percentage** claim — proxies + correlation instead.

## Architecture

`LSUIElement` AppKit/SwiftUI app. An `NSStatusItem` owns the menu-bar
title; a `Timer` drives the sampling loop; a `SpikeLog` watches
thresholds; a `Correlator` scores causation; an optional privileged
helper provides powermetrics ground truth. Each unit is focused and
independently testable.

```
~/WSMonitor/
├── project.yml                 # xcodegen spec (Fleet/imperum-mobile-style workflow)
├── Sources/
│   ├── App/
│   │   ├── AppDelegate.swift       # LSUIElement, NSStatusItem, timer, wiring
│   │   ├── MenuView.swift          # SwiftUI dropdown: live table + spikes + controls
│   │   └── Info.plist              # LSUIElement=true, LSMinimumSystemVersion
│   ├── Samplers/
│   │   ├── WindowSampler.swift     # CGWindowList → per-PID {wins, area, display}
│   │   ├── CPUSampler.swift        # proc_pid_rusage delta → real CPU% + RSS
│   │   ├── GPUSampler.swift        # IOReport + IOAccelerator → global GPU% + GPU mem
│   │   ├── WindowServerStat.swift  # WindowServer PID + CPU/RAM
│   │   └── FrontApp.swift          # NSWorkspace.frontmostApplication
│   ├── Engine/
│   │   ├── HeavyScore.swift        # pure scoring function (weights in one place)
│   │   ├── Correlator.swift        # rolling time-series → per-app correlation
│   │   └── SpikeLog.swift          # threshold watch + rolling top-N capture
│   └── Control/
│       ├── QuitAndWatch.swift      # SIGSTOP/SIGCONT a suspect, observe WS delta
│       └── PowerMetricsClient.swift# talk to privileged helper (XPC)
├── Helper/
│   └── com.imperum.wsmonitor.helper/   # privileged helper (SMAppService)
│       ├── main.swift              # runs `powermetrics … -n1` on request, returns parsed JSON
│       └── Info/Launchd plists
├── Tests/                          # SwiftPM unit tests
├── build.sh                        # xcodebuild Release + codesign (app + helper)
└── README.md
```

### Data model

```
AppSample { pid, name, windows, area, perDisplayArea:[DisplayID:Int],
            cpu, rss, heavy }
SpikeEvent { timestamp, wsCPU, wsRSS, gpuUtil, gpuMem,
             top:[AppSample], correlated:[(name,score)],
             powerMetrics: PMSnapshot? }      // nil unless helper installed
PMSnapshot { perProcess:[(name, gpuMsPerSec, energyImpact)], wsCoalition }
```

## Sampling loop (every N seconds, default 5)

1. `WindowSampler` → per-PID window count + pixel area per display
   (on-screen, layer 0, area ≥ 5000 — script's filters).
2. `CPUSampler` → per-PID instantaneous CPU% (`proc_pid_rusage` CPU-time
   delta ÷ wall-clock) + RSS. **Fixes the script's lifetime-avg bug.**
3. `GPUSampler` → global GPU utilization% + GPU memory in-use.
4. `WindowServerStat` → WindowServer CPU/RAM.
5. `HeavyScore` per app, sort desc.
6. `Correlator.record(...)` appends to rolling series; updates per-app
   correlation scores.
7. Update status-item title (`WS x% · GPU y% · TopApp`, severity colour)
   and the dropdown.
8. `SpikeLog.observe(...)` — on threshold cross, capture a `SpikeEvent`
   (and, if the helper is installed, request a `PMSnapshot`).

## HEAVY score

Script's formula, centralized with named-constant weights:
`heavy = cpu*100 + area/100000 + windows*20 + rss/20`. Dropdown tooltip
shows the per-term breakdown. Correlation score shown alongside (it is
*not* folded into HEAVY — kept separate so users see proxy-rank vs
causation-rank distinctly).

## Causation layer

- **Correlator**: keeps ~last 60 samples of WS CPU/GPU and each app's
  CPU/window-activity. Computes Pearson correlation of each app's series
  against the WS series; the high-and-consistent app is flagged "likely
  cause". Honest stand-in for unavailable per-app GPU accounting.
- **QuitAndWatch**: `SIGSTOP` the suspect (reversible pause, not quit),
  watch WS CPU/GPU for ~3s, report the drop, then `SIGCONT`. The one
  method that proves causation. Confirmation dialog before acting.
- **PowerMetricsClient + helper**: on spike (or on demand), the helper
  runs `powermetrics --samplers tasks,gpu_power --show-process-gpu
  --show-process-energy -n1 -i200`, parses per-process GPU/energy +
  the WindowServer coalition, returns JSON over XPC. Stored in the
  SpikeEvent as ground truth.

## Privileged helper

- Installed via `SMAppService` (modern replacement for SMJobBless).
- Runs as root LaunchDaemon; only capability is "run powermetrics once
  and return parsed output" — no arbitrary command execution.
- App and helper both signed with **Developer ID Application: Imperum
  B.V. (9TZGSR8224)**; helper requires a matching code-signing
  requirement so only this app can talk to it.
- App is fully functional without the helper; the powermetrics layer is
  a toggle in the menu ("Enable deep GPU capture — installs helper").

## Signing & build

`build.sh`: `xcodegen` → `xcodebuild -configuration Release` (app +
helper) → `codesign --options runtime --timestamp --sign "Developer ID
Application: Imperum B.V. (9TZGSR8224)"` for both. Notarization optional
(the App Store Connect API key on hand). Output `WSMonitor.app` → `/Applications`,
add to Login Items.

## Testing

- SwiftPM unit tests: `HeavyScore` (exact scores for known inputs),
  `CPUSampler` delta math (synthetic CPU-time/wall pairs), `Correlator`
  (synthetic correlated vs uncorrelated series → expected ranking),
  `PowerMetricsClient` parser (fixture powermetrics output → struct).
- Manual acceptance: launch, confirm live readout; open a heavy WebGL
  page on the 7680×3240 panel; confirm GPU rises, a SpikeEvent is logged
  with the right top suspect + high correlation; SIGSTOP that app and
  confirm WS drops; (if enabled) confirm PMSnapshot attached.

## Risks

- `IOReport`/`IOAccelerator` are undocumented; key names vary by chip.
  `GPUSampler` enumerates accelerators, tolerates missing keys, falls
  back to "GPU —" rather than crashing.
- `powermetrics` per-process GPU is unreliable on Apple Silicon — the
  helper captures it as *supplementary* evidence, never the sole signal.
- Private symbol drift (if SkyLight is ever used) — v1 avoids SkyLight
  entirely, using only public CGWindowList.
- SMAppService helper approval requires a one-time user action in System
  Settings → Login Items; documented in README.
