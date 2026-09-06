import AppKit
import Combine
import Foundation
import ImperumCore

/// Wires `MotionSensor` → `TapDetector` → `ActionRunner`, owns the guided
/// left/right calibration, and publishes state for the settings tab.
/// Started at app launch and lives for the whole run (like the volume blocker).
final class TapGestureController: ObservableObject {
    enum SensorStatus: Equatable { case unavailable(String), off, on }
    enum CalibrationState: Equatable {
        case idle, collectingLeft(Int), collectingRight(Int), done(SideCalibration), failed
    }
    static let calibrationTapsPerSide = 5

    @Published private(set) var status: SensorStatus = .off
    @Published private(set) var lastTap: String?
    @Published private(set) var calibration: CalibrationState = .idle

    let store: TapSettingsStore
    private let sensor = MotionSensor()
    private let detector: TapDetector
    private let runner = ActionRunner()
    private let queue = DispatchQueue(label: "io.imperum.tool.tap", qos: .userInteractive)
    private var cancellable: AnyCancellable?
    private var leftSamples: [TapImpulse] = [], rightSamples: [TapImpulse] = []
    private var lastTapClear: DispatchWorkItem?

    init(store: TapSettingsStore) {
        self.store = store
        detector = TapDetector(config: TapDetectorConfig(threshold: store.settings.threshold),
                               classifier: SideClassifier(calibration: store.settings.calibration))
        detector.suppressor = Self.recentKeyboardOrMouse
        sensor.handler = { [weak self] isGyro, sample in
            guard let self else { return }
            self.queue.async {
                if isGyro { self.detector.feed(gyro: sample) }
                else { self.detector.feed(accel: sample).forEach(self.handle) }
            }
        }
        cancellable = store.$settings
            .receive(on: DispatchQueue.main)
            .sink { [weak self] s in self?.apply(s) }
        apply(store.settings)
        NSLog("Imperum Tool tap gestures: enabled=\(store.settings.enabled) sensor=\(sensor.isAvailable ? "available" : sensor.unavailableReason)")
    }

    /// True when a key or mouse button went down in the last 250 ms — typing
    /// and clicking shake the chassis too. Public API, no permission needed.
    private static func recentKeyboardOrMouse() -> Bool {
        let types: [CGEventType] = [.keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown]
        return types.contains { CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: $0) < 0.25 }
    }

    private func apply(_ s: TapSettings) {
        queue.async {
            self.detector.config.threshold = s.threshold
            self.detector.classifier = SideClassifier(calibration: s.calibration)
        }
        let wantSensor = s.enabled || isCalibrating
        guard sensor.isAvailable else { status = .unavailable(sensor.unavailableReason); return }
        if wantSensor { sensor.start(); status = .on } else { sensor.stop(); status = .off }
    }

    private var isCalibrating: Bool {
        switch calibration { case .collectingLeft, .collectingRight: return true; default: return false }
    }

    // MARK: Detector output

    private func handle(_ out: TapDetectorOutput) {
        switch out {
        case .impulse(let imp):
            DispatchQueue.main.async { self.collectCalibration(imp) }
        case .tap(let ev):
            DispatchQueue.main.async { self.fire(ev) }
        }
    }

    private func fire(_ ev: TapEvent) {
        guard store.settings.enabled else { return }
        let action = store.settings.map.action(side: ev.side, count: ev.count)
        showLastTap("\(ev.side.rawValue.uppercased()) ×\(ev.count) → \(action.summary)")
        NSLog("Imperum Tool tap: \(ev.side) ×\(ev.count) → \(action.kind.rawValue)")
        runner.run(action)
    }

    private func showLastTap(_ text: String) {
        lastTap = text
        lastTapClear?.cancel()
        let w = DispatchWorkItem { [weak self] in self?.lastTap = nil }
        lastTapClear = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 6, execute: w)
    }

    // MARK: Calibration

    func startCalibration() {
        leftSamples = []; rightSamples = []
        calibration = .collectingLeft(0)
        queue.async { self.detector.calibrating = true; self.detector.reset() }
        apply(store.settings)   // makes sure the sensor is running even if the feature is off
    }

    func cancelCalibration() {
        calibration = .idle
        queue.async { self.detector.calibrating = false }
        apply(store.settings)
    }

    private func collectCalibration(_ imp: TapImpulse) {
        let n = Self.calibrationTapsPerSide
        switch calibration {
        case .collectingLeft(let k):
            leftSamples.append(imp)
            calibration = k + 1 >= n ? .collectingRight(0) : .collectingLeft(k + 1)
        case .collectingRight(let k):
            rightSamples.append(imp)
            if k + 1 >= n {
                if let cal = calibrateSides(left: leftSamples, right: rightSamples) {
                    store.settings.calibration = cal
                    calibration = .done(cal)
                } else {
                    calibration = .failed
                }
                queue.async { self.detector.calibrating = false }
                apply(store.settings)
            } else {
                calibration = .collectingRight(k + 1)
            }
        default:
            break
        }
    }
}
