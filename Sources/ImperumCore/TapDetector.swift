import Foundation

public enum TapSide: String, Codable, CaseIterable, Hashable {
    case left, right
}

/// One accelerometer (g) or gyroscope (rad/s) reading. `t` is a monotonic
/// timestamp in seconds — the detector only ever uses differences.
public struct MotionSample: Equatable {
    public var t: TimeInterval
    public var x: Double, y: Double, z: Double
    public init(t: TimeInterval, x: Double, y: Double, z: Double) {
        self.t = t; self.x = x; self.y = y; self.z = z
    }
}

/// Peak features captured for a single physical tap. Values are signed peaks
/// (largest-magnitude sample inside the capture window), which is what side
/// classification keys on.
public struct TapImpulse: Equatable {
    public var t: TimeInterval
    public var magnitude: Double          // |high-passed accel| at the peak, g
    public var accelX: Double, accelY: Double, accelZ: Double
    public var gyroX: Double, gyroY: Double, gyroZ: Double
    public init(t: TimeInterval, magnitude: Double,
                accelX: Double, accelY: Double, accelZ: Double,
                gyroX: Double, gyroY: Double, gyroZ: Double) {
        self.t = t; self.magnitude = magnitude
        self.accelX = accelX; self.accelY = accelY; self.accelZ = accelZ
        self.gyroX = gyroX; self.gyroY = gyroY; self.gyroZ = gyroZ
    }
}

public struct TapEvent: Equatable {
    public var side: TapSide
    public var count: Int
    public var t: TimeInterval
    public init(side: TapSide, count: Int, t: TimeInterval) {
        self.side = side; self.count = count; self.t = t
    }
}

public struct TapDetectorConfig: Equatable {
    /// High-passed acceleration (g) that counts as a tap. ~0.001 g is the
    /// resting noise floor; a fingertip tap is 0.05–1 g.
    public var threshold: Double
    /// Ignore further crossings for this long after one (tap ringing).
    public var refractory: TimeInterval
    /// Keep sampling the peak for this long after the crossing.
    public var captureWindow: TimeInterval
    /// Taps closer together than this belong to the same ×N group.
    public var groupWindow: TimeInterval
    /// Groups cap here and emit immediately.
    public var maxCount: Int
    /// After a group emits, ignore impulses for this long.
    public var postEmitIgnore: TimeInterval
    /// EMA coefficient for gravity removal (per sample at ~100 Hz).
    public var emaAlpha: Double

    public static let defaultThreshold = 0.06

    public init(threshold: Double = TapDetectorConfig.defaultThreshold,
                refractory: TimeInterval = 0.12, captureWindow: TimeInterval = 0.06,
                groupWindow: TimeInterval = 0.35, maxCount: Int = 3,
                postEmitIgnore: TimeInterval = 0.4, emaAlpha: Double = 0.05) {
        self.threshold = threshold; self.refractory = refractory
        self.captureWindow = captureWindow; self.groupWindow = groupWindow
        self.maxCount = maxCount; self.postEmitIgnore = postEmitIgnore
        self.emaAlpha = emaAlpha
    }
}

public enum TapDetectorOutput: Equatable {
    /// A single physical tap was captured (fed to calibration and to grouping).
    case impulse(TapImpulse)
    /// A completed ×N group on one side.
    case tap(TapEvent)
}

/// Pure tap detector: feed 100 Hz accelerometer + gyro samples, get impulses
/// and grouped tap events back. No timers — grouping timeouts are evaluated
/// on the sample stream, which is continuous while the sensor is active.
public final class TapDetector {
    public var config: TapDetectorConfig
    public var classifier: SideClassifier
    /// Return true to veto an impulse (e.g. a key was pressed just now).
    public var suppressor: (() -> Bool)?
    /// When true, impulses are reported but never grouped into tap events.
    public var calibrating = false

    private var ema: (Double, Double, Double)?
    private var lastGyro = (0.0, 0.0, 0.0)
    private var lastCrossing: TimeInterval = -.infinity
    private var ignoreUntil: TimeInterval = -.infinity

    // Peak capture in progress.
    private var capture: TapImpulse?
    private var captureDeadline: TimeInterval = 0

    // Current ×N group.
    private var groupSide: TapSide?
    private var groupCount = 0
    private var groupLast: TimeInterval = 0

    public init(config: TapDetectorConfig = TapDetectorConfig(),
                classifier: SideClassifier = SideClassifier()) {
        self.config = config; self.classifier = classifier
    }

    public func reset() {
        ema = nil; capture = nil; groupSide = nil; groupCount = 0
        lastCrossing = -.infinity; ignoreUntil = -.infinity
    }

    public func feed(gyro s: MotionSample) {
        lastGyro = (s.x, s.y, s.z)
    }

    public func feed(accel s: MotionSample) -> [TapDetectorOutput] {
        guard let e = ema else { ema = (s.x, s.y, s.z); return [] }
        let a = config.emaAlpha
        let next = (e.0 + a * (s.x - e.0), e.1 + a * (s.y - e.1), e.2 + a * (s.z - e.2))
        ema = next
        let hp = (s.x - next.0, s.y - next.1, s.z - next.2)
        let mag = (hp.0 * hp.0 + hp.1 * hp.1 + hp.2 * hp.2).squareRoot()

        var out: [TapDetectorOutput] = []

        // 1. Continue an open peak capture.
        if var c = capture {
            if mag > c.magnitude {
                c = TapImpulse(t: c.t, magnitude: mag, accelX: hp.0, accelY: hp.1, accelZ: hp.2,
                               gyroX: lastGyro.0, gyroY: lastGyro.1, gyroZ: lastGyro.2)
            }
            if s.t >= captureDeadline {
                capture = nil
                out.append(.impulse(c))
                out += group(c)
            } else {
                capture = c
            }
        }
        // 2. New crossing?
        else if mag >= config.threshold,
                s.t - lastCrossing >= config.refractory,
                s.t >= ignoreUntil,
                !(suppressor?() ?? false) {
            lastCrossing = s.t
            capture = TapImpulse(t: s.t, magnitude: mag, accelX: hp.0, accelY: hp.1, accelZ: hp.2,
                                 gyroX: lastGyro.0, gyroY: lastGyro.1, gyroZ: lastGyro.2)
            captureDeadline = s.t + config.captureWindow
        }

        // 3. Close a group that has gone quiet.
        if let side = groupSide, capture == nil, s.t - groupLast > config.groupWindow {
            out.append(.tap(TapEvent(side: side, count: groupCount, t: groupLast)))
            clearGroup(now: s.t)
        }
        return out
    }

    private func group(_ imp: TapImpulse) -> [TapDetectorOutput] {
        guard !calibrating else { return [] }
        let side = classifier.side(of: imp)
        if groupSide == nil { groupSide = side; groupCount = 0 }
        groupCount += 1
        groupLast = imp.t
        if groupCount >= config.maxCount, let s = groupSide {
            let ev = TapEvent(side: s, count: groupCount, t: imp.t)
            clearGroup(now: imp.t)
            return [.tap(ev)]
        }
        return []
    }

    private func clearGroup(now: TimeInterval) {
        groupSide = nil; groupCount = 0
        ignoreUntil = now + config.postEmitIgnore
    }
}
