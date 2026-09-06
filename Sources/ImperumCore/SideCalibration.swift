import Foundation

/// Which peak feature separates left taps from right taps on this machine.
/// Learned by calibration because the sensor sits in the lid and the sign
/// convention differs between models and lid angles.
public enum SideFeature: String, Codable, CaseIterable {
    case accelX, gyroX, gyroY, gyroZ

    public func value(of imp: TapImpulse) -> Double {
        switch self {
        case .accelX: return imp.accelX
        case .gyroX: return imp.gyroX
        case .gyroY: return imp.gyroY
        case .gyroZ: return imp.gyroZ
        }
    }
}

public struct SideCalibration: Codable, Equatable {
    public var feature: SideFeature
    public var leftIsPositive: Bool
    /// Decision boundary (usually ~0; midpoint of the two class means).
    public var boundary: Double
    /// Separation score at calibration time, for display.
    public var separation: Double
    public init(feature: SideFeature, leftIsPositive: Bool, boundary: Double, separation: Double) {
        self.feature = feature; self.leftIsPositive = leftIsPositive
        self.boundary = boundary; self.separation = separation
    }
}

/// Picks the feature whose left/right means are furthest apart relative to
/// their spread. Returns nil when nothing separates the classes at all.
public func calibrateSides(left: [TapImpulse], right: [TapImpulse]) -> SideCalibration? {
    guard !left.isEmpty, !right.isEmpty else { return nil }
    func stats(_ v: [Double]) -> (mean: Double, sd: Double) {
        let m = v.reduce(0, +) / Double(v.count)
        let varc = v.reduce(0) { $0 + ($1 - m) * ($1 - m) } / Double(v.count)
        return (m, varc.squareRoot())
    }
    var best: SideCalibration?
    for f in SideFeature.allCases {
        let l = stats(left.map(f.value(of:))), r = stats(right.map(f.value(of:)))
        let sep = abs(l.mean - r.mean) / (l.sd + r.sd + 1e-6)
        guard sep > 0, l.mean != r.mean else { continue }
        if best == nil || sep > best!.separation {
            best = SideCalibration(feature: f, leftIsPositive: l.mean > r.mean,
                                   boundary: (l.mean + r.mean) / 2, separation: sep)
        }
    }
    // Require the classes to be at least one combined standard deviation apart.
    guard let b = best, b.separation >= 1 else { return nil }
    return b
}

public struct SideClassifier: Equatable {
    public var calibration: SideCalibration?
    public init(calibration: SideCalibration? = nil) { self.calibration = calibration }

    /// Uncalibrated fallback: sign of gyro-y (the physics guess from the spike).
    public static let fallback = SideCalibration(feature: .gyroY, leftIsPositive: true, boundary: 0, separation: 0)

    public func side(of imp: TapImpulse) -> TapSide {
        let c = calibration ?? Self.fallback
        let positive = c.feature.value(of: imp) > c.boundary
        return positive == c.leftIsPositive ? .left : .right
    }
}
