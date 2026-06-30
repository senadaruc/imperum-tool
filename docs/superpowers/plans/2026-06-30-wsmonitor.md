# WindowServer Monitor Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A sudoless macOS menu-bar app that detects WindowServer CPU/RAM/GPU spikes and identifies which app is responsible, with an optional privileged helper for authoritative powermetrics ground truth.

**Architecture:** Swift Package Manager workspace. `WSCore` library holds all pure logic + system samplers (CoreGraphics/IOKit/libproc) and is unit-tested via `swift test`. `WSMonitor` executable links `WSCore` + AppKit, runs as a menu-bar accessory (`NSApplication.setActivationPolicy(.accessory)`), drives a timer sampling loop, and renders an `NSStatusItem` + dropdown. A second executable `WSHelper` (privileged, installed via `SMAppService`) runs `powermetrics` once per request over XPC. `build.sh` assembles and Developer-ID-signs `WSMonitor.app`.

**Tech Stack:** Swift 5.9+/Swift 6, SwiftPM, AppKit, SwiftUI (dropdown), CoreGraphics (`CGWindowListCopyWindowInfo`), IOKit (`IOServiceMatching("IOAccelerator")`, IOReport), `libproc`/`proc_pid_rusage`, `ServiceManagement` (`SMAppService`), XPC, XCTest.

## Global Constraints

- Target: Apple Silicon (M3 Max verified), macOS 26.5.1. `Package.swift` `platforms: [.macOS(.v14)]` (min deploy macOS 14 for `SMAppService`).
- 100% sudoless for the core app; privilege only inside the optional `WSHelper`.
- No public per-app GPU% is claimed — proxies + correlation only.
- HEAVY formula, verbatim: `heavy = cpu*100 + area/100000 + windows*20 + rss/20`.
- Window filters, verbatim from `ws-watch.sh`: on-screen only, exclude desktop elements, `layer == 0`, per-window `area >= 5000`.
- Spike thresholds (defaults): WindowServer CPU > 60% OR global GPU util > 80%. Spike de-dupe cooldown 30s unless top suspect changed.
- Code-sign identity (app + helper): `Developer ID Application: Imperum B.V. (9TZGSR8224)`.
- Bundle id app: `io.imperum.wsmonitor`; helper: `io.imperum.wsmonitor.helper`.
- Menu-bar title format: `WS {wsCPU}% · GPU {gpuUtil}% · {topApp}`.
- All commits unsigned-friendly: `git -c commit.gpgsign=false commit`.

---

## Phase A — Sudoless MVP (working app, no helper)

### Task 1: SwiftPM scaffold + empty accessory app

**Files:**
- Create: `Package.swift`
- Create: `Sources/WSCore/WSCore.swift` (placeholder)
- Create: `Sources/WSMonitor/main.swift`
- Create: `Tests/WSCoreTests/SmokeTests.swift`

**Interfaces:**
- Produces: SwiftPM package with library `WSCore` + executable `WSMonitor`.

- [ ] **Step 1: Write `Package.swift`**

```swift
// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "WSMonitor",
    platforms: [.macOS(.v14)],
    targets: [
        .target(name: "WSCore"),
        .executableTarget(
            name: "WSMonitor",
            dependencies: ["WSCore"]
        ),
        .testTarget(name: "WSCoreTests", dependencies: ["WSCore"]),
    ]
)
```

- [ ] **Step 2: Placeholder library + smoke test**

`Sources/WSCore/WSCore.swift`:
```swift
public enum WSCore {
    public static let version = "0.1.0"
}
```

`Tests/WSCoreTests/SmokeTests.swift`:
```swift
import XCTest
@testable import WSCore

final class SmokeTests: XCTestCase {
    func testVersion() {
        XCTAssertEqual(WSCore.version, "0.1.0")
    }
}
```

- [ ] **Step 3: Minimal accessory app entry**

`Sources/WSMonitor/main.swift`:
```swift
import AppKit

let app = NSApplication.shared
app.setActivationPolicy(.accessory) // LSUIElement equivalent: no Dock icon
let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
statusItem.button?.title = "WS …"
let menu = NSMenu()
menu.addItem(NSMenuItem(title: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
statusItem.menu = menu
app.run()
```

- [ ] **Step 4: Run tests**

Run: `cd ~/WSMonitor && swift test`
Expected: PASS (`testVersion`).

- [ ] **Step 5: Verify it builds + launches**

Run: `swift build && .build/debug/WSMonitor &` then check the menu bar shows `WS …`; `kill %1` after.
Expected: a menu-bar item appears, no Dock icon.

- [ ] **Step 6: Commit**

```bash
git add Package.swift Sources Tests
git -c commit.gpgsign=false commit -m "feat: SwiftPM scaffold + empty accessory menu-bar app"
```

---

### Task 2: HeavyScore (pure scoring)

**Files:**
- Create: `Sources/WSCore/HeavyScore.swift`
- Test: `Tests/WSCoreTests/HeavyScoreTests.swift`

**Interfaces:**
- Produces: `struct AppSample` and `func heavyScore(_:) -> Double`.

```swift
public struct AppSample: Equatable {
    public var pid: Int32
    public var name: String
    public var windows: Int
    public var area: Int                 // total pixel area across displays
    public var perDisplayArea: [UInt32: Int]
    public var cpu: Double               // instantaneous %, 0..(100*cores)
    public var rss: Double               // MB
    public var heavy: Double
    public init(pid: Int32, name: String, windows: Int, area: Int,
                perDisplayArea: [UInt32: Int] = [:], cpu: Double = 0,
                rss: Double = 0, heavy: Double = 0) {
        self.pid = pid; self.name = name; self.windows = windows; self.area = area
        self.perDisplayArea = perDisplayArea; self.cpu = cpu; self.rss = rss; self.heavy = heavy
    }
}
```

- [ ] **Step 1: Write the failing test**

```swift
import XCTest
@testable import WSCore

final class HeavyScoreTests: XCTestCase {
    func testFormulaMatchesScript() {
        // cpu*100 + area/100000 + windows*20 + rss/20
        let s = heavyScore(cpu: 12.5, area: 8_300_000, windows: 6, rss: 1024)
        // 1250 + 83 + 120 + 51.2 = 1504.2
        XCTAssertEqual(s, 1504.2, accuracy: 0.001)
    }
    func testZero() {
        XCTAssertEqual(heavyScore(cpu: 0, area: 0, windows: 0, rss: 0), 0, accuracy: 0.0001)
    }
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `swift test --filter HeavyScoreTests`
Expected: FAIL ("cannot find 'heavyScore'").

- [ ] **Step 3: Implement**

`Sources/WSCore/HeavyScore.swift`:
```swift
public enum HeavyWeights {
    public static let cpu = 100.0
    public static let areaDivisor = 100_000.0
    public static let window = 20.0
    public static let rssDivisor = 20.0
}

public func heavyScore(cpu: Double, area: Int, windows: Int, rss: Double) -> Double {
    cpu * HeavyWeights.cpu
        + Double(area) / HeavyWeights.areaDivisor
        + Double(windows) * HeavyWeights.window
        + rss / HeavyWeights.rssDivisor
}
```

- [ ] **Step 4: Run to verify pass**

Run: `swift test --filter HeavyScoreTests`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/WSCore/HeavyScore.swift Tests/WSCoreTests/HeavyScoreTests.swift
git -c commit.gpgsign=false commit -m "feat: HeavyScore pure scoring + AppSample model"
```

---

### Task 3: CPUSampler (real instantaneous CPU + RSS via libproc)

**Files:**
- Create: `Sources/WSCore/CPUSampler.swift`
- Test: `Tests/WSCoreTests/CPUSamplerTests.swift`

**Interfaces:**
- Consumes: nothing.
- Produces:
  - `func cpuPercent(prevNs: UInt64, curNs: UInt64, elapsed: TimeInterval) -> Double` (pure, testable)
  - `final class CPUSampler` with `func sample(pids: [Int32]) -> [Int32: (cpu: Double, rss: Double)]` (live; keeps previous CPU-time per pid).

The pure delta function is the tested unit; the live wrapper is validated manually.

- [ ] **Step 1: Failing test for the delta math**

```swift
import XCTest
@testable import WSCore

final class CPUSamplerTests: XCTestCase {
    func testHalfCoreBusy() {
        // 0.5s of CPU time over 1.0s wall = 50%
        let pct = cpuPercent(prevNs: 0, curNs: 500_000_000, elapsed: 1.0)
        XCTAssertEqual(pct, 50.0, accuracy: 0.001)
    }
    func testTwoCoresFull() {
        // 2.0s CPU over 1.0s wall = 200%
        let pct = cpuPercent(prevNs: 1_000_000_000, curNs: 3_000_000_000, elapsed: 1.0)
        XCTAssertEqual(pct, 200.0, accuracy: 0.001)
    }
    func testZeroElapsedIsZero() {
        XCTAssertEqual(cpuPercent(prevNs: 0, curNs: 1, elapsed: 0), 0)
    }
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `swift test --filter CPUSamplerTests`
Expected: FAIL ("cannot find 'cpuPercent'").

- [ ] **Step 3: Implement pure math + live sampler**

`Sources/WSCore/CPUSampler.swift`:
```swift
import Foundation
import Darwin

/// CPU% = (cpu-time delta in ns) / (wall elapsed in ns) * 100.
public func cpuPercent(prevNs: UInt64, curNs: UInt64, elapsed: TimeInterval) -> Double {
    guard elapsed > 0, curNs >= prevNs else { return 0 }
    let deltaNs = Double(curNs - prevNs)
    return deltaNs / (elapsed * 1_000_000_000.0) * 100.0
}

public final class CPUSampler {
    private var prevCPU: [Int32: UInt64] = [:]
    private var prevTime = Date()

    public init() {}

    /// Returns instantaneous CPU% and RSS(MB) per pid, using proc_pid_rusage deltas.
    public func sample(pids: [Int32]) -> [Int32: (cpu: Double, rss: Double)] {
        let now = Date()
        let elapsed = now.timeIntervalSince(prevTime)
        var out: [Int32: (Double, Double)] = [:]
        var nextPrev: [Int32: UInt64] = [:]
        for pid in pids {
            var info = rusage_info_current()
            let rc = withUnsafeMutablePointer(to: &info) {
                $0.withMemoryRebound(to: (rusage_info_t?).self, capacity: 1) {
                    proc_pid_rusage(pid, RUSAGE_INFO_CURRENT, $0)
                }
            }
            guard rc == 0 else { continue }
            let cpuNs = info.ri_user_time + info.ri_system_time   // nanoseconds
            let rssMB = Double(info.ri_resident_size) / 1_048_576.0
            nextPrev[pid] = cpuNs
            if let p = prevCPU[pid] {
                out[pid] = (cpuPercent(prevNs: p, curNs: cpuNs, elapsed: elapsed), rssMB)
            } else {
                out[pid] = (0, rssMB)   // first observation: no delta yet
            }
        }
        prevCPU = nextPrev
        prevTime = now
        return out
    }
}
```

- [ ] **Step 4: Run to verify pass**

Run: `swift test --filter CPUSamplerTests`
Expected: PASS.

- [ ] **Step 5: Manual live check**

Run: add a temporary `print(CPUSampler().sample(pids: [Int32(ProcessInfo.processInfo.processIdentifier)]))` in a scratch; confirm it returns an RSS > 0. (Remove after.)

- [ ] **Step 6: Commit**

```bash
git add Sources/WSCore/CPUSampler.swift Tests/WSCoreTests/CPUSamplerTests.swift
git -c commit.gpgsign=false commit -m "feat: CPUSampler with real sampled CPU% (fixes ps lifetime-avg)"
```

---

### Task 4: WindowSampler (per-app windows, pixel area, per display)

**Files:**
- Create: `Sources/WSCore/WindowSampler.swift`
- Test: `Tests/WSCoreTests/WindowSamplerTests.swift`

**Interfaces:**
- Produces:
  - `struct RawWindow { pid; owner; layer; width; height; displayID }` (pure input)
  - `func aggregate(windows: [RawWindow]) -> [Int32: (name: String, windows: Int, area: Int, perDisplay: [UInt32:Int])]` (pure, tested)
  - `func sampleWindows() -> [Int32: (name, windows, area, perDisplay)]` (live CGWindowList wrapper).

- [ ] **Step 1: Failing test for aggregation + filters**

```swift
import XCTest
@testable import WSCore

final class WindowSamplerTests: XCTestCase {
    func testFiltersAndAggregates() {
        let ws = [
            RawWindow(pid: 10, owner: "Chrome", layer: 0, width: 1000, height: 1000, displayID: 1), // 1,000,000
            RawWindow(pid: 10, owner: "Chrome", layer: 0, width: 50, height: 50, displayID: 1),       // 2500 < 5000 → dropped
            RawWindow(pid: 10, owner: "Chrome", layer: 0, width: 2000, height: 1000, displayID: 2),  // 2,000,000 other display
            RawWindow(pid: 20, owner: "Dock", layer: 25, width: 4000, height: 100, displayID: 1),    // layer != 0 → dropped
        ]
        let agg = aggregate(windows: ws)
        XCTAssertNil(agg[20])                       // dock filtered by layer
        XCTAssertEqual(agg[10]?.windows, 2)         // two surviving windows
        XCTAssertEqual(agg[10]?.area, 3_000_000)
        XCTAssertEqual(agg[10]?.perDisplay[1], 1_000_000)
        XCTAssertEqual(agg[10]?.perDisplay[2], 2_000_000)
        XCTAssertEqual(agg[10]?.name, "Chrome")
    }
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `swift test --filter WindowSamplerTests`
Expected: FAIL ("cannot find 'RawWindow'").

- [ ] **Step 3: Implement aggregation + live sampler**

`Sources/WSCore/WindowSampler.swift`:
```swift
import Foundation
import CoreGraphics

public struct RawWindow {
    public var pid: Int32
    public var owner: String
    public var layer: Int
    public var width: Double
    public var height: Double
    public var displayID: UInt32
    public init(pid: Int32, owner: String, layer: Int, width: Double, height: Double, displayID: UInt32) {
        self.pid = pid; self.owner = owner; self.layer = layer
        self.width = width; self.height = height; self.displayID = displayID
    }
}

public struct WinAgg { public var name: String; public var windows: Int; public var area: Int; public var perDisplay: [UInt32: Int] }

public let kMinWindowArea = 5000

public func aggregate(windows: [RawWindow]) -> [Int32: WinAgg] {
    var out: [Int32: WinAgg] = [:]
    for w in windows {
        guard w.layer == 0 else { continue }
        let a = Int(w.width * w.height)
        guard a >= kMinWindowArea else { continue }
        var e = out[w.pid] ?? WinAgg(name: w.owner, windows: 0, area: 0, perDisplay: [:])
        e.windows += 1
        e.area += a
        e.perDisplay[w.displayID, default: 0] += a
        out[w.pid] = e
    }
    return out
}

public func sampleWindows() -> [Int32: WinAgg] {
    let opts: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
    guard let infos = CGWindowListCopyWindowInfo(opts, kCGNullWindowID) as? [[String: Any]] else { return [:] }
    var raws: [RawWindow] = []
    for info in infos {
        guard let pid = info[kCGWindowOwnerPID as String] as? Int32,
              let owner = info[kCGWindowOwnerName as String] as? String else { continue }
        let layer = info[kCGWindowLayer as String] as? Int ?? 0
        var width = 0.0, height = 0.0
        if let b = info[kCGWindowBounds as String] as? [String: Any] {
            width = b["Width"] as? Double ?? 0
            height = b["Height"] as? Double ?? 0
        }
        // Map window bounds to a display id (best-effort: main display fallback).
        let display = displayID(forBounds: info[kCGWindowBounds as String] as? [String: Any])
        raws.append(RawWindow(pid: pid, owner: owner, layer: layer, width: width, height: height, displayID: display))
    }
    return aggregate(windows: raws)
}

private func displayID(forBounds bounds: [String: Any]?) -> UInt32 {
    guard let b = bounds,
          let x = b["X"] as? Double, let y = b["Y"] as? Double else {
        return CGMainDisplayID()
    }
    let pt = CGPoint(x: x + 1, y: y + 1)
    var ids = [CGDirectDisplayID](repeating: 0, count: 8)
    var count: UInt32 = 0
    if CGGetDisplaysWithPoint(pt, 8, &ids, &count) == .success, count > 0 { return ids[0] }
    return CGMainDisplayID()
}
```

- [ ] **Step 4: Run to verify pass**

Run: `swift test --filter WindowSamplerTests`
Expected: PASS.

- [ ] **Step 5: Manual live check**

Scratch: `print(sampleWindows().values.map { "\($0.name) \($0.windows) \($0.area)" })` — expect your real apps listed.

- [ ] **Step 6: Commit**

```bash
git add Sources/WSCore/WindowSampler.swift Tests/WSCoreTests/WindowSamplerTests.swift
git -c commit.gpgsign=false commit -m "feat: WindowSampler — per-app windows/area, per-display, script filters"
```

---

### Task 5: GPUSampler (global GPU util + GPU memory, sudoless)

**Files:**
- Create: `Sources/WSCore/GPUSampler.swift`
- Test: `Tests/WSCoreTests/GPUSamplerTests.swift`

**Interfaces:**
- Produces:
  - `struct GPUStats { utilization: Double?; rendererUtil: Double?; tilerUtil: Double?; memInUseMB: Double? }`
  - `func parseAcceleratorStats(_ perf: [String: Any]) -> GPUStats` (pure, tested)
  - `func sampleGPU() -> GPUStats` (live IOKit `IOAccelerator` `PerformanceStatistics`).

Uses IOAccelerator (verified present, sudoless). IOReport is a future enhancement; not needed for v1 since IOAccelerator gives util + memory.

- [ ] **Step 1: Failing test for the parser**

```swift
import XCTest
@testable import WSCore

final class GPUSamplerTests: XCTestCase {
    func testParseKnownKeys() {
        let perf: [String: Any] = [
            "Device Utilization %": 30,
            "Renderer Utilization %": 28,
            "Tiler Utilization %": 12,
            "In use system memory": 3_083_403_264, // bytes
        ]
        let s = parseAcceleratorStats(perf)
        XCTAssertEqual(s.utilization, 30)
        XCTAssertEqual(s.rendererUtil, 28)
        XCTAssertEqual(s.tilerUtil, 12)
        XCTAssertEqual(s.memInUseMB!, 2940.5, accuracy: 1.0)
    }
    func testMissingKeysAreNil() {
        let s = parseAcceleratorStats([:])
        XCTAssertNil(s.utilization)
        XCTAssertNil(s.memInUseMB)
    }
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `swift test --filter GPUSamplerTests`
Expected: FAIL ("cannot find 'parseAcceleratorStats'").

- [ ] **Step 3: Implement parser + IOKit live sampler**

`Sources/WSCore/GPUSampler.swift`:
```swift
import Foundation
import IOKit

public struct GPUStats: Equatable {
    public var utilization: Double?
    public var rendererUtil: Double?
    public var tilerUtil: Double?
    public var memInUseMB: Double?
    public init(utilization: Double? = nil, rendererUtil: Double? = nil,
                tilerUtil: Double? = nil, memInUseMB: Double? = nil) {
        self.utilization = utilization; self.rendererUtil = rendererUtil
        self.tilerUtil = tilerUtil; self.memInUseMB = memInUseMB
    }
}

public func parseAcceleratorStats(_ perf: [String: Any]) -> GPUStats {
    func num(_ k: String) -> Double? { (perf[k] as? NSNumber)?.doubleValue }
    var s = GPUStats()
    s.utilization = num("Device Utilization %")
    s.rendererUtil = num("Renderer Utilization %")
    s.tilerUtil = num("Tiler Utilization %")
    if let bytes = num("In use system memory") { s.memInUseMB = bytes / 1_048_576.0 }
    return s
}

/// Reads the busiest IOAccelerator's PerformanceStatistics. Sudoless.
public func sampleGPU() -> GPUStats {
    var iterator: io_iterator_t = 0
    guard IOServiceGetMatchingServices(kIOMainPortDefault,
            IOServiceMatching("IOAccelerator"), &iterator) == KERN_SUCCESS else { return GPUStats() }
    defer { IOObjectRelease(iterator) }
    var best = GPUStats()
    var service = IOIteratorNext(iterator)
    while service != 0 {
        defer { IOObjectRelease(service); service = IOIteratorNext(iterator) }
        var props: Unmanaged<CFMutableDictionary>?
        guard IORegistryEntryCreateCFProperties(service, &props, kCFAllocatorDefault, 0) == KERN_SUCCESS,
              let dict = props?.takeRetainedValue() as? [String: Any],
              let perf = dict["PerformanceStatistics"] as? [String: Any] else { continue }
        let s = parseAcceleratorStats(perf)
        if (s.utilization ?? -1) >= (best.utilization ?? -1) { best = s }
    }
    return best
}
```

- [ ] **Step 4: Run to verify pass**

Run: `swift test --filter GPUSamplerTests`
Expected: PASS.

- [ ] **Step 5: Manual live check**

Scratch: `print(sampleGPU())` — expect a non-nil `utilization` and `memInUseMB` matching `ioreg`'s `Device Utilization %`.

- [ ] **Step 6: Commit**

```bash
git add Sources/WSCore/GPUSampler.swift Tests/WSCoreTests/GPUSamplerTests.swift
git -c commit.gpgsign=false commit -m "feat: GPUSampler — sudoless global GPU util + memory via IOAccelerator"
```

---

### Task 6: WindowServerStat + FrontApp

**Files:**
- Create: `Sources/WSCore/WindowServerStat.swift`
- Create: `Sources/WSCore/FrontApp.swift`
- Test: `Tests/WSCoreTests/WindowServerStatTests.swift`

**Interfaces:**
- Produces:
  - `func windowServerPID() -> Int32?` (live; finds the `WindowServer` process)
  - `func processName(pid: Int32) -> String?` (pure-ish helper via libproc)
  - `func frontAppName() -> String` (AppKit `NSWorkspace`).

- [ ] **Step 1: Failing test (name lookup of self)**

```swift
import XCTest
@testable import WSCore

final class WindowServerStatTests: XCTestCase {
    func testProcessNameOfSelf() {
        let me = Int32(ProcessInfo.processInfo.processIdentifier)
        XCTAssertNotNil(processName(pid: me))
    }
    func testWindowServerFound() {
        // WindowServer always runs in a logged-in GUI session.
        XCTAssertNotNil(windowServerPID())
    }
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `swift test --filter WindowServerStatTests`
Expected: FAIL ("cannot find 'processName'").

- [ ] **Step 3: Implement**

`Sources/WSCore/WindowServerStat.swift`:
```swift
import Foundation
import Darwin

public func processName(pid: Int32) -> String? {
    var buf = [CChar](repeating: 0, count: 4096)
    let n = proc_name(pid, &buf, UInt32(buf.count))
    return n > 0 ? String(cString: buf) : nil
}

/// Finds the WindowServer pid by scanning all pids for the process named "WindowServer".
public func windowServerPID() -> Int32? {
    var count = proc_listallpids(nil, 0)
    guard count > 0 else { return nil }
    var pids = [Int32](repeating: 0, count: Int(count) * 2)
    count = proc_listallpids(&pids, Int32(pids.count) * Int32(MemoryLayout<Int32>.size))
    for i in 0..<Int(count) where pids[i] > 0 {
        if processName(pid: pids[i]) == "WindowServer" { return pids[i] }
    }
    return nil
}
```

`Sources/WSCore/FrontApp.swift`:
```swift
import AppKit

public func frontAppName() -> String {
    NSWorkspace.shared.frontmostApplication?.localizedName ?? "Unknown"
}
```

- [ ] **Step 4: Run to verify pass**

Run: `swift test --filter WindowServerStatTests`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/WSCore/WindowServerStat.swift Sources/WSCore/FrontApp.swift Tests/WSCoreTests/WindowServerStatTests.swift
git -c commit.gpgsign=false commit -m "feat: WindowServer pid lookup, process name, front app"
```

---

### Task 7: Monitor engine (assemble a ranked snapshot)

**Files:**
- Create: `Sources/WSCore/Monitor.swift`
- Test: `Tests/WSCoreTests/MonitorTests.swift`

**Interfaces:**
- Consumes: `CPUSampler`, `sampleWindows`, `sampleGPU`, `windowServerPID`.
- Produces:
  - `struct Snapshot { ts: Date; wsCPU: Double; wsRSS: Double; gpu: GPUStats; apps: [AppSample] }`
  - `func buildSnapshot(winAgg:cpu:wsPID:gpu:now:) -> Snapshot` (pure assembler, tested)
  - `final class Monitor { func tick() -> Snapshot }` (live).

- [ ] **Step 1: Failing test for the pure assembler**

```swift
import XCTest
@testable import WSCore

final class MonitorTests: XCTestCase {
    func testRanksByHeavyDescAndExtractsWS() {
        let win: [Int32: WinAgg] = [
            10: WinAgg(name: "Chrome", windows: 6, area: 8_300_000, perDisplay: [1: 8_300_000]),
            99: WinAgg(name: "WindowServer", windows: 0, area: 0, perDisplay: [:]),
            20: WinAgg(name: "Notes", windows: 1, area: 200_000, perDisplay: [1: 200_000]),
        ]
        let cpu: [Int32: (cpu: Double, rss: Double)] = [
            10: (40, 1500), 99: (75, 900), 20: (2, 120),
        ]
        let snap = buildSnapshot(winAgg: win, cpu: cpu, wsPID: 99,
                                 gpu: GPUStats(utilization: 88), now: Date(timeIntervalSince1970: 0))
        XCTAssertEqual(snap.wsCPU, 75)
        XCTAssertEqual(snap.wsRSS, 900)
        XCTAssertEqual(snap.apps.first?.name, "Chrome")   // highest HEAVY
        XCTAssertFalse(snap.apps.contains { $0.name == "WindowServer" }) // WS excluded from suspects
    }
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `swift test --filter MonitorTests`
Expected: FAIL ("cannot find 'buildSnapshot'").

- [ ] **Step 3: Implement assembler + live Monitor**

`Sources/WSCore/Monitor.swift`:
```swift
import Foundation

public struct Snapshot {
    public var ts: Date
    public var wsCPU: Double
    public var wsRSS: Double
    public var gpu: GPUStats
    public var apps: [AppSample]   // sorted by heavy desc, WindowServer excluded
}

public func buildSnapshot(winAgg: [Int32: WinAgg],
                          cpu: [Int32: (cpu: Double, rss: Double)],
                          wsPID: Int32?,
                          gpu: GPUStats,
                          now: Date) -> Snapshot {
    var wsCPU = 0.0, wsRSS = 0.0
    if let ws = wsPID, let c = cpu[ws] { wsCPU = c.cpu; wsRSS = c.rss }
    var apps: [AppSample] = []
    let pids = Set(winAgg.keys).union(cpu.keys)
    for pid in pids {
        if pid == wsPID { continue }
        guard let w = winAgg[pid] else { continue }   // suspects must own visible windows
        let c = cpu[pid] ?? (0, 0)
        let h = heavyScore(cpu: c.cpu, area: w.area, windows: w.windows, rss: c.rss)
        apps.append(AppSample(pid: pid, name: w.name, windows: w.windows, area: w.area,
                              perDisplayArea: w.perDisplay, cpu: c.cpu, rss: c.rss, heavy: h))
    }
    apps.sort { $0.heavy > $1.heavy }
    return Snapshot(ts: now, wsCPU: wsCPU, wsRSS: wsRSS, gpu: gpu, apps: apps)
}

public final class Monitor {
    private let cpuSampler = CPUSampler()
    private var wsPIDCache: Int32?
    public init() {}

    public func tick() -> Snapshot {
        let win = sampleWindows()
        if wsPIDCache == nil { wsPIDCache = windowServerPID() }
        var pids = Array(win.keys)
        if let ws = wsPIDCache { pids.append(ws) }
        let cpu = cpuSampler.sample(pids: pids)
        let gpu = sampleGPU()
        return buildSnapshot(winAgg: win, cpu: cpu, wsPID: wsPIDCache, gpu: gpu, now: Date())
    }
}
```

- [ ] **Step 4: Run to verify pass**

Run: `swift test --filter MonitorTests`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/WSCore/Monitor.swift Tests/WSCoreTests/MonitorTests.swift
git -c commit.gpgsign=false commit -m "feat: Monitor — ranked snapshot assembler + live tick"
```

---

### Task 8: SpikeLog (threshold capture with cooldown)

**Files:**
- Create: `Sources/WSCore/SpikeLog.swift`
- Test: `Tests/WSCoreTests/SpikeLogTests.swift`

**Interfaces:**
- Produces:
  - `struct SpikeEvent { ts; wsCPU; gpuUtil; top: [AppSample] }`
  - `struct SpikeConfig { cpuThreshold=60; gpuThreshold=80; cooldown=30; topN=5 }`
  - `final class SpikeLog { func observe(_ snap: Snapshot) -> SpikeEvent?; var events: [SpikeEvent] }`

- [ ] **Step 1: Failing test for threshold + cooldown + suspect-change**

```swift
import XCTest
@testable import WSCore

final class SpikeLogTests: XCTestCase {
    private func snap(_ t: TimeInterval, wsCPU: Double, gpu: Double, top: String) -> Snapshot {
        Snapshot(ts: Date(timeIntervalSince1970: t), wsCPU: wsCPU, wsRSS: 0,
                 gpu: GPUStats(utilization: gpu),
                 apps: [AppSample(pid: 1, name: top, windows: 1, area: 1, heavy: 1)])
    }
    func testCapturesAboveThresholdThenCooldown() {
        let log = SpikeLog(config: SpikeConfig(cpuThreshold: 60, gpuThreshold: 80, cooldown: 30, topN: 5))
        XCTAssertNil(log.observe(snap(0, wsCPU: 10, gpu: 10)))     // calm
        XCTAssertNotNil(log.observe(snap(1, wsCPU: 70, gpu: 10)))  // CPU spike
        XCTAssertNil(log.observe(snap(5, wsCPU: 72, gpu: 10)))     // within cooldown, same suspect
        XCTAssertNotNil(log.observe(snap(40, wsCPU: 72, gpu: 10))) // cooldown elapsed
        XCTAssertNotNil(log.observe(snap(41, wsCPU: 72, gpu: 10, top: "Other"))) // suspect changed → capture
        XCTAssertEqual(log.events.count, 3)
    }
    func testGpuThreshold() {
        let log = SpikeLog(config: SpikeConfig())
        XCTAssertNotNil(log.observe(snap(0, wsCPU: 5, gpu: 90)))
    }
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `swift test --filter SpikeLogTests`
Expected: FAIL ("cannot find 'SpikeLog'").

- [ ] **Step 3: Implement**

`Sources/WSCore/SpikeLog.swift`:
```swift
import Foundation

public struct SpikeConfig {
    public var cpuThreshold: Double
    public var gpuThreshold: Double
    public var cooldown: TimeInterval
    public var topN: Int
    public init(cpuThreshold: Double = 60, gpuThreshold: Double = 80,
                cooldown: TimeInterval = 30, topN: Int = 5) {
        self.cpuThreshold = cpuThreshold; self.gpuThreshold = gpuThreshold
        self.cooldown = cooldown; self.topN = topN
    }
}

public struct SpikeEvent {
    public var ts: Date
    public var wsCPU: Double
    public var gpuUtil: Double?
    public var top: [AppSample]
}

public final class SpikeLog {
    public private(set) var events: [SpikeEvent] = []
    private let config: SpikeConfig
    private let maxEvents = 50
    private var lastTopName: String?

    public init(config: SpikeConfig = SpikeConfig()) { self.config = config }

    public func observe(_ snap: Snapshot) -> SpikeEvent? {
        let gpu = snap.gpu.utilization ?? 0
        let isSpike = snap.wsCPU > config.cpuThreshold || gpu > config.gpuThreshold
        guard isSpike else { return nil }
        let topName = snap.apps.first?.name
        if let last = events.last {
            let withinCooldown = snap.ts.timeIntervalSince(last.ts) < config.cooldown
            if withinCooldown && topName == lastTopName { return nil }
        }
        let ev = SpikeEvent(ts: snap.ts, wsCPU: snap.wsCPU, gpuUtil: snap.gpu.utilization,
                            top: Array(snap.apps.prefix(config.topN)))
        events.append(ev)
        if events.count > maxEvents { events.removeFirst(events.count - maxEvents) }
        lastTopName = topName
        return ev
    }
}
```

- [ ] **Step 4: Run to verify pass**

Run: `swift test --filter SpikeLogTests`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/WSCore/SpikeLog.swift Tests/WSCoreTests/SpikeLogTests.swift
git -c commit.gpgsign=false commit -m "feat: SpikeLog — threshold capture with cooldown + suspect-change"
```

---

### Task 9: Correlator (causation by Pearson correlation)

**Files:**
- Create: `Sources/WSCore/Correlator.swift`
- Test: `Tests/WSCoreTests/CorrelatorTests.swift`

**Interfaces:**
- Produces:
  - `func pearson(_ a: [Double], _ b: [Double]) -> Double` (pure, tested)
  - `final class Correlator { func record(_ snap: Snapshot); func ranking() -> [(name: String, score: Double)] }`

- [ ] **Step 1: Failing test for Pearson + ranking**

```swift
import XCTest
@testable import WSCore

final class CorrelatorTests: XCTestCase {
    func testPerfectPositive() {
        XCTAssertEqual(pearson([1,2,3,4], [2,4,6,8]), 1.0, accuracy: 1e-9)
    }
    func testPerfectNegative() {
        XCTAssertEqual(pearson([1,2,3,4], [4,3,2,1]), -1.0, accuracy: 1e-9)
    }
    func testRankingFlagsCorrelatedApp() {
        let c = Correlator(window: 10)
        // WS rises with "Bad"; "Good" is flat.
        for i in 0..<6 {
            let ws = Double(i * 10)
            let snap = Snapshot(ts: Date(timeIntervalSince1970: Double(i)), wsCPU: ws, wsRSS: 0,
                gpu: GPUStats(utilization: ws),
                apps: [AppSample(pid: 1, name: "Bad", windows: 1, area: 1, cpu: ws, rss: 0, heavy: 1),
                       AppSample(pid: 2, name: "Good", windows: 1, area: 1, cpu: 5, rss: 0, heavy: 1)])
            c.record(snap)
        }
        let r = c.ranking()
        XCTAssertEqual(r.first?.name, "Bad")
        XCTAssertGreaterThan(r.first!.score, 0.9)
    }
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `swift test --filter CorrelatorTests`
Expected: FAIL ("cannot find 'pearson'").

- [ ] **Step 3: Implement**

`Sources/WSCore/Correlator.swift`:
```swift
import Foundation

public func pearson(_ a: [Double], _ b: [Double]) -> Double {
    let n = min(a.count, b.count)
    guard n >= 2 else { return 0 }
    let ax = Array(a.suffix(n)), bx = Array(b.suffix(n))
    let ma = ax.reduce(0,+) / Double(n), mb = bx.reduce(0,+) / Double(n)
    var num = 0.0, da = 0.0, db = 0.0
    for i in 0..<n {
        let xa = ax[i] - ma, xb = bx[i] - mb
        num += xa * xb; da += xa * xa; db += xb * xb
    }
    let den = (da * db).squareRoot()
    return den == 0 ? 0 : num / den
}

public final class Correlator {
    private let window: Int
    private var wsSeries: [Double] = []
    private var appSeries: [String: [Double]] = [:]
    public init(window: Int = 60) { self.window = window }

    public func record(_ snap: Snapshot) {
        // WS signal = max(wsCPU, gpuUtil) so either kind of spike drives correlation.
        let wsSignal = max(snap.wsCPU, snap.gpu.utilization ?? 0)
        append(&wsSeries, wsSignal)
        let names = Set(snap.apps.map { $0.name })
        for app in snap.apps { append(&appSeries[app.name, default: []], app.cpu) }
        // keep absent apps aligned by padding with 0
        for (name, _) in appSeries where !names.contains(name) {
            append(&appSeries[name, default: []], 0)
        }
    }

    private func append(_ arr: inout [Double], _ v: Double) {
        arr.append(v)
        if arr.count > window { arr.removeFirst(arr.count - window) }
    }

    public func ranking() -> [(name: String, score: Double)] {
        appSeries.map { ($0.key, pearson(wsSeries, $0.value)) }
                 .sorted { $0.1 > $1.1 }
                 .map { (name: $0.0, score: $0.1) }
    }
}
```

- [ ] **Step 4: Run to verify pass**

Run: `swift test --filter CorrelatorTests`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/WSCore/Correlator.swift Tests/WSCoreTests/CorrelatorTests.swift
git -c commit.gpgsign=false commit -m "feat: Correlator — Pearson causation ranking over rolling series"
```

---

### Task 10: QuitAndWatch (SIGSTOP/SIGCONT proof)

**Files:**
- Create: `Sources/WSCore/QuitAndWatch.swift`
- Test: `Tests/WSCoreTests/QuitAndWatchTests.swift`

**Interfaces:**
- Produces:
  - `func pause(pid: Int32) -> Bool` / `func resume(pid: Int32) -> Bool` (kill(2) SIGSTOP/SIGCONT)
  - `struct WatchResult { before: Double; after: Double; drop: Double }`
  - `func watchDrop(before: Double, after: Double) -> WatchResult` (pure, tested).

- [ ] **Step 1: Failing test**

```swift
import XCTest
@testable import WSCore

final class QuitAndWatchTests: XCTestCase {
    func testDropMath() {
        let r = watchDrop(before: 180, after: 40)
        XCTAssertEqual(r.drop, 140, accuracy: 0.001)
    }
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `swift test --filter QuitAndWatchTests`
Expected: FAIL ("cannot find 'watchDrop'").

- [ ] **Step 3: Implement**

`Sources/WSCore/QuitAndWatch.swift`:
```swift
import Foundation
import Darwin

public struct WatchResult: Equatable {
    public var before: Double
    public var after: Double
    public var drop: Double
}

public func watchDrop(before: Double, after: Double) -> WatchResult {
    WatchResult(before: before, after: after, drop: before - after)
}

@discardableResult public func pause(pid: Int32) -> Bool { kill(pid, SIGSTOP) == 0 }
@discardableResult public func resume(pid: Int32) -> Bool { kill(pid, SIGCONT) == 0 }
```

- [ ] **Step 4: Run to verify pass**

Run: `swift test --filter QuitAndWatchTests`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/WSCore/QuitAndWatch.swift Tests/WSCoreTests/QuitAndWatchTests.swift
git -c commit.gpgsign=false commit -m "feat: QuitAndWatch — SIGSTOP/SIGCONT + drop math"
```

---

### Task 11: Menu-bar UI wiring (live app)

**Files:**
- Modify: `Sources/WSMonitor/main.swift`
- Create: `Sources/WSMonitor/AppController.swift`
- Create: `Sources/WSMonitor/Formatters.swift`
- Test: `Tests/WSCoreTests/FormattersTests.swift` (move `formatTitle` into WSCore so it is testable)
- Create: `Sources/WSCore/TitleFormatter.swift`

**Interfaces:**
- Consumes: `Monitor`, `SpikeLog`, `Correlator`, `pause/resume`.
- Produces: `func formatTitle(wsCPU:gpu:top:) -> String` (in WSCore, tested), and a live `AppController` driving an `NSStatusItem` on a 5s timer.

- [ ] **Step 1: Failing test for the title formatter**

`Tests/WSCoreTests/FormattersTests.swift`:
```swift
import XCTest
@testable import WSCore

final class FormattersTests: XCTestCase {
    func testTitle() {
        XCTAssertEqual(formatTitle(wsCPU: 42.4, gpu: 88.0, top: "Chrome"),
                       "WS 42% · GPU 88% · Chrome")
    }
    func testTitleNoTop() {
        XCTAssertEqual(formatTitle(wsCPU: 5, gpu: nil, top: nil),
                       "WS 5% · GPU —% · …")
    }
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `swift test --filter FormattersTests`
Expected: FAIL ("cannot find 'formatTitle'").

- [ ] **Step 3: Implement formatter in WSCore**

`Sources/WSCore/TitleFormatter.swift`:
```swift
import Foundation

public func formatTitle(wsCPU: Double, gpu: Double?, top: String?) -> String {
    let g = gpu.map { String(Int($0.rounded())) } ?? "—"
    return "WS \(Int(wsCPU.rounded()))% · GPU \(g)% · \(top ?? "…")"
}
```

- [ ] **Step 4: Run to verify pass**

Run: `swift test --filter FormattersTests`
Expected: PASS.

- [ ] **Step 5: Implement AppController + rewire main**

`Sources/WSMonitor/AppController.swift`:
```swift
import AppKit
import WSCore

final class AppController: NSObject {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let monitor = Monitor()
    private let spikes = SpikeLog()
    private let correlator = Correlator()
    private var timer: Timer?
    private var latest: Snapshot?

    func start() {
        rebuildMenu(snapshot: nil)
        tick()
        timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in self?.tick() }
    }

    private func tick() {
        let snap = monitor.tick()
        latest = snap
        correlator.record(snap)
        _ = spikes.observe(snap)
        statusItem.button?.title = formatTitle(wsCPU: snap.wsCPU, gpu: snap.gpu.utilization, top: snap.apps.first?.name)
        statusItem.button?.contentTintColor = severityColor(snap)
        rebuildMenu(snapshot: snap)
    }

    private func severityColor(_ s: Snapshot) -> NSColor {
        let g = s.gpu.utilization ?? 0
        if s.wsCPU > 60 || g > 80 { return .systemRed }
        if s.wsCPU > 30 || g > 50 { return .systemYellow }
        return .systemGreen
    }

    private func rebuildMenu(snapshot: Snapshot?) {
        let menu = NSMenu()
        if let s = snapshot {
            menu.addItem(header("WindowServer  CPU \(Int(s.wsCPU))%  RAM \(Int(s.wsRSS)) MB  GPU mem \(Int(s.gpu.memInUseMB ?? 0)) MB"))
            menu.addItem(.separator())
            menu.addItem(header("Top suspects (HEAVY)"))
            for a in s.apps.prefix(8) {
                let item = NSMenuItem(title: "\(a.name)  ·  HEAVY \(Int(a.heavy))  ·  \(a.windows)w \(a.cpu, fmt: 0)% \(a.area/1000)k px",
                                      action: #selector(pauseSuspect(_:)), keyEquivalent: "")
                item.target = self; item.representedObject = a.pid
                menu.addItem(item)
            }
            menu.addItem(.separator())
            let corr = correlator.ranking().prefix(3).filter { $0.score > 0.3 }
            if !corr.isEmpty {
                menu.addItem(header("Most correlated with spikes"))
                for c in corr { menu.addItem(disabled("\(c.name)  ·  r=\(String(format: "%.2f", c.score))")) }
                menu.addItem(.separator())
            }
            if !spikes.events.isEmpty {
                menu.addItem(header("Recent spikes"))
                for e in spikes.events.suffix(5).reversed() {
                    let when = DateFormatter.localizedString(from: e.ts, dateStyle: .none, timeStyle: .medium)
                    menu.addItem(disabled("\(when)  WS \(Int(e.wsCPU))% · GPU \(Int(e.gpuUtil ?? 0))% — \(e.top.first?.name ?? "?")"))
                }
                menu.addItem(.separator())
            }
            menu.addItem(disabled("Click a suspect to PAUSE it (proves cause); it resumes after 4s"))
        } else {
            menu.addItem(disabled("Sampling…"))
        }
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        statusItem.menu = menu
    }

    private func header(_ s: String) -> NSMenuItem { disabled(s) }
    private func disabled(_ s: String) -> NSMenuItem {
        let i = NSMenuItem(title: s, action: nil, keyEquivalent: ""); i.isEnabled = false; return i
    }

    @objc private func pauseSuspect(_ sender: NSMenuItem) {
        guard let pid = sender.representedObject as? Int32, let before = latest?.wsCPU else { return }
        pause(pid: pid)
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [weak self] in
            resume(pid: pid)
            let after = self?.monitor.tick().wsCPU ?? before
            let r = watchDrop(before: before, after: after)
            let a = NSAlert()
            a.messageText = "Quit-and-watch result"
            a.informativeText = "WindowServer CPU \(Int(r.before))% → \(Int(r.after))% (drop \(Int(r.drop))%).\nIf the drop is large, this app is your culprit."
            a.runModal()
        }
    }
}

// Tiny interpolation helper for fixed-decimal in menu strings.
private extension String.StringInterpolation {
    mutating func appendInterpolation(_ value: Double, fmt: Int) {
        appendLiteral(String(format: "%.\(fmt)f", value))
    }
}
```

`Sources/WSMonitor/main.swift` (replace body):
```swift
import AppKit

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let controller = AppController()
controller.start()
app.run()
```

- [ ] **Step 6: Build + manual acceptance**

Run: `swift build && .build/debug/WSMonitor &`
Expected: menu bar shows `WS x% · GPU y% · <app>`, updates every 5s; dropdown lists suspects, correlated apps (after ~10 ticks), recent spikes; clicking a suspect pauses it 4s and shows a drop alert. `kill %1` when done.

- [ ] **Step 7: Commit**

```bash
git add Sources/WSMonitor Sources/WSCore/TitleFormatter.swift Tests/WSCoreTests/FormattersTests.swift
git -c commit.gpgsign=false commit -m "feat: live menu-bar UI — title, suspects, correlation, spikes, quit-and-watch"
```

---

### Task 12: build.sh — assemble + Developer-ID-sign WSMonitor.app

**Files:**
- Create: `build.sh`
- Create: `Resources/Info.plist`
- Create: `README.md`

**Interfaces:** none (packaging).

- [ ] **Step 1: Info.plist**

`Resources/Info.plist`:
```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>WSMonitor</string>
  <key>CFBundleIdentifier</key><string>io.imperum.wsmonitor</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>CFBundleShortVersionString</key><string>0.1.0</string>
  <key>CFBundleExecutable</key><string>WSMonitor</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>LSUIElement</key><true/>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>ITSAppUsesNonExemptEncryption</key><false/>
</dict></plist>
```

- [ ] **Step 2: build.sh**

`build.sh`:
```bash
#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
ID="Developer ID Application: Imperum B.V. (9TZGSR8224)"
APP="build/WSMonitor.app"

swift build -c release
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp .build/release/WSMonitor "$APP/Contents/MacOS/WSMonitor"
codesign --force --options runtime --timestamp \
  --sign "$ID" "$APP/Contents/MacOS/WSMonitor"
codesign --force --options runtime --timestamp \
  --sign "$ID" "$APP"
codesign --verify --deep --strict --verbose=2 "$APP"
echo "Built + signed: $APP"
```

- [ ] **Step 3: README**

`README.md`:
```markdown
# WSMonitor
Sudoless macOS menu-bar app that finds which app drives WindowServer
CPU/RAM/GPU spikes. See docs/superpowers/specs for design + research.

## Build
    ./build.sh
Produces build/WSMonitor.app (Developer ID signed). Copy to /Applications:
    cp -R build/WSMonitor.app /Applications/
Add to Login Items: System Settings → General → Login Items → +.

## Use
Menu bar shows `WS x% · GPU y% · TopApp` (red when spiking). Open the
dropdown for ranked suspects, the spike-correlated app, recent spikes,
and one-click pause-and-watch to prove the culprit.
```

- [ ] **Step 4: Build the signed app**

Run: `chmod +x build.sh && ./build.sh`
Expected: `Built + signed: build/WSMonitor.app`, `codesign --verify` prints `valid on disk`.

- [ ] **Step 5: Launch the bundle**

Run: `open build/WSMonitor.app`
Expected: menu-bar item appears, no Dock icon, no Gatekeeper warning.

- [ ] **Step 6: Commit**

```bash
git add build.sh Resources/Info.plist README.md
git -c commit.gpgsign=false commit -m "build: assemble + Developer-ID-sign WSMonitor.app"
```

---

## Phase B — Privileged powermetrics helper (opt-in ground truth)

> Build Phase A first and confirm it identifies a real spike. Phase B adds authoritative per-process GPU/energy at spike time.

### Task 13: PowerMetrics output parser (pure)

**Files:**
- Create: `Sources/WSCore/PowerMetricsParser.swift`
- Create: `Tests/WSCoreTests/Fixtures/powermetrics-tasks.txt` (captured sample)
- Test: `Tests/WSCoreTests/PowerMetricsParserTests.swift`

**Interfaces:**
- Produces:
  - `struct PMProcess { name; pid; gpuMsPerS: Double?; energyImpact: Double? }`
  - `func parsePowerMetrics(_ text: String) -> [PMProcess]` (pure, tested).

- [ ] **Step 1: Capture a real fixture (one-time, needs sudo — user runs)**

Run: `sudo powermetrics --samplers tasks --show-process-gpu --show-process-energy -n1 -i200 > Tests/WSCoreTests/Fixtures/powermetrics-tasks.txt`
Expected: a text table with `Name`, `ID`, `GPU ms/s`, and energy columns.

- [ ] **Step 2: Failing test against the fixture**

```swift
import XCTest
@testable import WSCore

final class PowerMetricsParserTests: XCTestCase {
    func testParsesProcessRows() throws {
        let url = Bundle.module.url(forResource: "powermetrics-tasks", withExtension: "txt")!
        let text = try String(contentsOf: url, encoding: .utf8)
        let procs = parsePowerMetrics(text)
        XCTAssertFalse(procs.isEmpty)
        XCTAssertTrue(procs.contains { $0.name.contains("WindowServer") })
        XCTAssertTrue(procs.allSatisfy { $0.pid >= 0 })
    }
}
```
(Note: add `resources: [.process("Fixtures")]` to the `WSCoreTests` target in `Package.swift`.)

- [ ] **Step 3: Run to verify it fails**

Run: `swift test --filter PowerMetricsParserTests`
Expected: FAIL ("cannot find 'parsePowerMetrics'").

- [ ] **Step 4: Implement the parser**

`Sources/WSCore/PowerMetricsParser.swift`:
```swift
import Foundation

public struct PMProcess: Equatable {
    public var name: String
    public var pid: Int32
    public var gpuMsPerS: Double?
    public var energyImpact: Double?
}

/// Parses the `--samplers tasks` table. Columns are whitespace-separated;
/// the header row defines column order (Name, ID, ... GPU ms/s, ... Energy Impact).
public func parsePowerMetrics(_ text: String) -> [PMProcess] {
    let lines = text.split(separator: "\n").map(String.init)
    guard let headerIdx = lines.firstIndex(where: { $0.contains("Name") && $0.contains("ID") }) else { return [] }
    let header = lines[headerIdx]
    func col(_ key: String) -> Int? {
        // index of the column whose header contains `key`
        let cols = header.split(whereSeparator: { $0 == " " }).map(String.init)
        return cols.firstIndex(where: { $0.contains(key) })
    }
    let gpuCol = header.range(of: "GPU ms/s")
    let energyCol = header.range(of: "Energy Impact")
    var out: [PMProcess] = []
    for line in lines[(headerIdx+1)...] {
        let t = line.trimmingCharacters(in: .whitespaces)
        if t.isEmpty || t.hasPrefix("*") || t.hasPrefix("-") { continue }
        // Fields: Name may contain spaces, but ID is the first all-digit token after it.
        let parts = line.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        guard let idIdx = parts.firstIndex(where: { Int32($0) != nil }) else { continue }
        let name = parts[0..<idIdx].joined(separator: " ")
        let pid = Int32(parts[idIdx]) ?? -1
        let nums = parts[(idIdx+1)...].compactMap { Double($0) }
        // Best-effort: GPU ms/s and Energy are among the trailing numeric columns.
        let gpu = gpuCol != nil ? nums.first : nil
        let energy = energyCol != nil ? nums.last : nil
        out.append(PMProcess(name: name, pid: pid, gpuMsPerS: gpu, energyImpact: energy))
        _ = col // keep helper referenced
    }
    return out
}
```

- [ ] **Step 5: Run to verify pass**

Run: `swift test --filter PowerMetricsParserTests`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add Sources/WSCore/PowerMetricsParser.swift Tests/WSCoreTests Package.swift
git -c commit.gpgsign=false commit -m "feat: powermetrics tasks parser + fixture test"
```

---

### Task 14: Privileged helper executable + SMAppService install + XPC

**Files:**
- Modify: `Package.swift` (add `WSHelper` executable target)
- Create: `Sources/WSHelper/main.swift`
- Create: `Sources/WSMonitor/PowerMetricsClient.swift`
- Modify: `Sources/WSMonitor/AppController.swift` (menu toggle + spike hook)
- Modify: `build.sh` (bundle + sign helper into the app, add launchd plist)
- Create: `Resources/io.imperum.wsmonitor.helper.plist`

**Interfaces:**
- Consumes: `parsePowerMetrics`.
- Produces: an XPC mach service `io.imperum.wsmonitor.helper` exposing `runPowerMetrics(reply: (String) -> Void)`; `PowerMetricsClient.capture(completion:)` in the app; a menu toggle "Enable deep GPU capture".

> This task wires SMAppService + XPC. It has no pure-logic unit test (it's IPC/privilege); it is validated by the manual acceptance steps. The parser it depends on is already tested in Task 13.

- [ ] **Step 1: Add helper target to Package.swift**

```swift
.executableTarget(name: "WSHelper", dependencies: ["WSCore"]),
```

- [ ] **Step 2: Helper main — XPC listener that runs powermetrics once**

`Sources/WSHelper/main.swift`:
```swift
import Foundation

@objc protocol HelperProtocol { func runPowerMetrics(withReply reply: @escaping (String) -> Void) }

final class Helper: NSObject, HelperProtocol, NSXPCListenerDelegate {
    func runPowerMetrics(withReply reply: @escaping (String) -> Void) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/powermetrics")
        p.arguments = ["--samplers", "tasks,gpu_power", "--show-process-gpu",
                       "--show-process-energy", "-n1", "-i200"]
        let pipe = Pipe(); p.standardOutput = pipe
        do { try p.run(); p.waitUntilExit() } catch { reply("ERROR: \(error)"); return }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        reply(String(data: data, encoding: .utf8) ?? "")
    }
    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection conn: NSXPCConnection) -> Bool {
        conn.exportedInterface = NSXPCInterface(with: HelperProtocol.self)
        conn.exportedObject = self
        conn.resume()
        return true
    }
}

let delegate = Helper()
let listener = NSXPCListener(machServiceName: "io.imperum.wsmonitor.helper")
listener.delegate = delegate
listener.resume()
RunLoop.main.run()
```

- [ ] **Step 3: launchd plist for the daemon**

`Resources/io.imperum.wsmonitor.helper.plist`:
```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>io.imperum.wsmonitor.helper</string>
  <key>BundleProgram</key><string>Contents/MacOS/WSHelper</string>
  <key>MachServices</key><dict><key>io.imperum.wsmonitor.helper</key><true/></dict>
  <key>AssociatedBundleIdentifiers</key><array><string>io.imperum.wsmonitor</string></array>
</dict></plist>
```

- [ ] **Step 4: App-side client + SMAppService registration**

`Sources/WSMonitor/PowerMetricsClient.swift`:
```swift
import Foundation
import ServiceManagement
import WSCore

@objc protocol HelperProtocol { func runPowerMetrics(withReply reply: @escaping (String) -> Void) }

final class PowerMetricsClient {
    static let shared = PowerMetricsClient()
    private let service = SMAppService.daemon(plistName: "io.imperum.wsmonitor.helper.plist")

    var isInstalled: Bool { service.status == .enabled }

    func install() throws { try service.register() }   // prompts user approval in Login Items
    func uninstall() throws { try service.unregister() }

    func capture(completion: @escaping ([PMProcess]) -> Void) {
        let conn = NSXPCConnection(machServiceName: "io.imperum.wsmonitor.helper", options: .privileged)
        conn.remoteObjectInterface = NSXPCInterface(with: HelperProtocol.self)
        conn.resume()
        let proxy = conn.remoteObjectProxyWithErrorHandler { _ in completion([]) } as? HelperProtocol
        proxy?.runPowerMetrics { text in
            completion(parsePowerMetrics(text))
            conn.invalidate()
        }
    }
}
```

- [ ] **Step 5: Wire toggle + spike hook into AppController**

In `rebuildMenu`, add before Quit:
```swift
let installed = PowerMetricsClient.shared.isInstalled
let toggle = NSMenuItem(title: installed ? "Disable deep GPU capture" : "Enable deep GPU capture (installs helper)",
                        action: #selector(toggleHelper), keyEquivalent: "")
toggle.target = self
menu.addItem(toggle)
```
Add methods:
```swift
@objc private func toggleHelper() {
    let c = PowerMetricsClient.shared
    do { if c.isInstalled { try c.uninstall() } else { try c.install() } }
    catch { NSAlert(error: error).runModal() }
}
```
In `tick()`, after `spikes.observe`, when a spike is returned and the helper is installed, capture ground truth and append to the spike’s display (store the latest PMProcess list in a property and render its top GPU consumer under "Recent spikes").
```swift
if let _ = spikes.observe(snap), PowerMetricsClient.shared.isInstalled {
    PowerMetricsClient.shared.capture { procs in
        let topGPU = procs.compactMap { p in p.gpuMsPerS.map { (p.name, $0) } }
                          .sorted { $0.1 > $1.1 }.first
        if let t = topGPU { print("powermetrics ground truth on spike: \(t.0) \(t.1) GPU ms/s") }
    }
}
```
(Replace the earlier bare `_ = spikes.observe(snap)` call.)

- [ ] **Step 6: build.sh — bundle + sign the helper**

Append to `build.sh` before the final app `codesign`:
```bash
mkdir -p "$APP/Contents/Library/LaunchDaemons" "$APP/Contents/MacOS"
cp .build/release/WSHelper "$APP/Contents/MacOS/WSHelper"
cp Resources/io.imperum.wsmonitor.helper.plist "$APP/Contents/Library/LaunchDaemons/"
codesign --force --options runtime --timestamp --sign "$ID" "$APP/Contents/MacOS/WSHelper"
```

- [ ] **Step 7: Build, install helper, force a spike, verify ground truth**

Run: `./build.sh && open build/WSMonitor.app`
Then: menu → "Enable deep GPU capture" → approve in System Settings → Login Items.
Force a GPU spike (heavy WebGL on the 7680×3240 panel). Watch the app's stderr/log:
Expected: a `powermetrics ground truth on spike: <App> <n> GPU ms/s` line appears when a spike is captured.

- [ ] **Step 8: Commit**

```bash
git add Package.swift Sources/WSHelper Sources/WSMonitor/PowerMetricsClient.swift Sources/WSMonitor/AppController.swift build.sh Resources/io.imperum.wsmonitor.helper.plist
git -c commit.gpgsign=false commit -m "feat: privileged SMAppService helper — powermetrics ground truth on spike"
```

---

## Self-Review notes

- **Spec coverage:** spike detection (Tasks 5–8), per-display ranking (Task 4 perDisplay + Task 7), real CPU (Task 3), GPU util+mem sudoless (Task 5), correlation (Task 9), SIGSTOP quit-and-watch (Tasks 10–11), spike log (Task 8), Developer-ID signing (Task 12), privileged powermetrics helper (Tasks 13–14), menu-bar title format (Task 11). All design sections mapped.
- **Type consistency:** `WinAgg`, `AppSample`, `Snapshot`, `SpikeEvent`, `GPUStats`, `PMProcess` used identically across tasks; `formatTitle`, `buildSnapshot`, `heavyScore`, `parsePowerMetrics` signatures stable.
- **Known soft spots flagged for execution:** (a) `displayID(forBounds:)` is best-effort; if per-display attribution looks wrong on the 7680×3240 panel, refine using `CGDisplayBounds` containment. (b) `parsePowerMetrics` column mapping is heuristic — the fixture test locks the real format; adjust indices to the captured fixture. (c) `HelperProtocol` is declared in both helper and app intentionally (no shared XPC module); keep the two in sync.
```
