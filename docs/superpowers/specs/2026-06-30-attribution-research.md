# Research: Attributing WindowServer CPU/RAM/GPU to an app

**Date:** 2026-06-30
**Target machine (verified):** Apple M3 Max (Mac15,8), macOS 26.5.1,
40-core GPU, Metal 4. Displays: **7680×3240** + **3840×2160**
(~33 million pixels of compositing surface).

## The core difficulty

WindowServer is the system compositor. It does rendering/compositing
work *on behalf of every client app*, but macOS exposes **no public
per-client CPU/GPU accounting** for that work. So "WindowServer is at
180% CPU" can't be split into "Chrome caused 120% of it" through any
documented API. Apple's own Activity Monitor does not link a window to
its owning process either, and its per-process %GPU column is unreliable
on Apple Silicon.

## What was tested on this exact machine

| Technique | sudo? | Result on M3 Max / macOS 26 | Verdict |
|---|---|---|---|
| `IOAccelerator` `PerformanceStatistics` (IOKit) | no | `Device/Renderer/Tiler Utilization %`, GPU mem in-use (3.08 GB) | ✅ **Global** GPU util + GPU RAM, live |
| `IOReport` API (the macmon/mactop path) | no | GPU utilization, frequency, power | ✅ **Global** GPU, no sudo |
| `IOAccelerator` `SurfaceList` per-PID surfaces | no | **0 entries** — not present on AGX | ❌ dead on Apple Silicon |
| `powermetrics --show-process-gpu` | **yes** | "GPU ms/s" per process; unreliable/often 0 on Apple Silicon | ⚠️ privileged + flaky |
| `powermetrics --show-process-energy` / `tasks` | **yes** | per-process energy + coalition incl. WindowServer | ⚠️ best ground-truth snapshot |
| `CGWindowListCopyWindowInfo` | no | per-app window count + pixel area (public) | ✅ proxy signal |
| `proc_pid_rusage` (libproc) CPU-time delta | no | true instantaneous per-PID CPU% + RSS | ✅ fixes script's lifetime-avg bug |
| SkyLight/CGS connection → PID → window list | no | accurate WS-side per-app window/surface counts | ⚠️ private API, fragile, SIP |

## Conclusion

True per-app GPU% does not exist publicly on Apple Silicon. Attribution
must be done by **combining a global spike signal with per-app proxy
signals, plus statistical correlation over time, plus an optional
privileged ground-truth snapshot.**

## Proposed strategy (3 layers)

### Layer 1 — Detect the spike (exact, no sudo, always on)
- WindowServer **CPU%** via `proc_pid_rusage` delta; **RAM** = its RSS.
- **Global GPU** via `IOReport` (utilization/power) + `IOAccelerator`
  `PerformanceStatistics` (GPU memory in-use). No sudo.

### Layer 2 — Rank suspects (proxy, no sudo, always on)
Per app, every cycle:
- live CPU% (libproc delta) — an app forcing redraws usually burns its
  own CPU submitting frames,
- window count + summed pixel area (`CGWindowListCopyWindowInfo`),
- combined into the HEAVY score (script's formula, centralized).
Plus **per-display** breakdown — on this machine the 7680×3240 panel is
the dominant compositing cost; apps with large windows on it rank higher.

### Layer 3 — Confirm causation (the actual diagnosis)
Two mechanisms, because proxies alone only *suggest*:

1. **Correlation engine (no sudo, automatic).** Keep short rolling time
   series of WindowServer CPU/GPU and of each app's CPU/window-activity.
   When WS spikes, compute which app's activity series best correlates
   with the WS series. The consistently-correlated app across many
   spikes is the culprit. This is the statistically honest substitute
   for direct per-app GPU accounting.

2. **Quit-and-watch helper (no sudo, manual, definitive).** A button to
   quit (or `SIGSTOP`) the top suspect and watch whether WindowServer
   CPU/GPU drops within a few seconds — automating the one method that
   actually proves causation. SIGSTOP (pause) is reversible and safer
   than quitting.

3. **(Optional) powermetrics snapshot on spike (privileged).** If the
   user installs a small privileged helper once, a spike triggers a
   one-shot `powermetrics --samplers tasks,gpu_power --show-process-gpu
   --show-process-energy -n1` captured into the spike log as ground
   truth. Off by default; the app is fully useful without it.

## Why this is better than the bash script
- Real instantaneous CPU (not lifetime average).
- Adds GPU utilization **and** GPU memory (script had neither).
- Catches intermittent spikes automatically (spike log).
- Moves from "here's a suspect" to "here's the app that *correlates* with
  your spikes, and a one-click way to prove it."

## Sources
- Apple — View GPU activity in Activity Monitor
- Eclectic Light Co. — WindowServer: display compositor; Activity Monitor CPU view
- vladkens/macmon (IOReport, sudoless Apple Silicon metrics)
- tlkh/asitop; metaspartan/mactop (powermetrics / IOReport monitors)
- NUIKit/CGSInternal (CGSConnection private headers)
- chockenberry GPU statistics gist (IOAccelerator PerformanceStatistics)
- andreafortuna.org — macOS WindowServer & Electron overload
