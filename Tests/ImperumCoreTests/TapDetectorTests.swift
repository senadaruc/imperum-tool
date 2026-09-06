import XCTest
@testable import ImperumCore

/// Builds a synthetic 100 Hz accelerometer stream: gravity + optional
/// tap impulses (a 3-sample bump of `amp` g on x, followed by ringing).
private struct Stream {
    var samples: [MotionSample] = []
    var t: TimeInterval = 0
    mutating func rest(_ seconds: TimeInterval) {
        let n = Int(seconds * 100)
        for _ in 0..<n { samples.append(MotionSample(t: t, x: 0, y: 0.98, z: 0.23)); t += 0.01 }
    }
    mutating func tap(amp: Double, sign: Double = 1) {
        for k in [1.0, 0.6, 0.3, -0.2, 0.1] {
            samples.append(MotionSample(t: t, x: sign * amp * k, y: 0.98, z: 0.23)); t += 0.01
        }
    }
}

private func detect(_ s: Stream, detector: TapDetector = TapDetector(),
                 gyroY: Double = 0) -> [TapDetectorOutput] {
    var out: [TapDetectorOutput] = []
    detector.feed(gyro: MotionSample(t: 0, x: 0, y: gyroY, z: 0))
    for smp in s.samples { out += detector.feed(accel: smp) }
    return out
}

private func taps(_ out: [TapDetectorOutput]) -> [TapEvent] {
    out.compactMap { if case .tap(let e) = $0 { return e } else { return nil } }
}
private func impulses(_ out: [TapDetectorOutput]) -> [TapImpulse] {
    out.compactMap { if case .impulse(let i) = $0 { return i } else { return nil } }
}

final class TapDetectorTests: XCTestCase {
    func testRestProducesNothing() {
        var s = Stream(); s.rest(3)
        XCTAssertTrue(detect(s).isEmpty)
    }

    func testSingleTap() {
        var s = Stream(); s.rest(1); s.tap(amp: 0.3); s.rest(1)
        let out = detect(s)
        XCTAssertEqual(impulses(out).count, 1)
        let t = taps(out)
        XCTAssertEqual(t.count, 1)
        XCTAssertEqual(t.first?.count, 1)
    }

    func testImpulseCapturesSignedPeak() {
        var s = Stream(); s.rest(1); s.tap(amp: 0.3, sign: -1); s.rest(1)
        let imp = impulses(detect(s, gyroY: -0.4)).first
        XCTAssertNotNil(imp)
        XCTAssertLessThan(imp!.accelX, -0.2)      // sign preserved
        XCTAssertEqual(imp!.gyroY, -0.4)
        XCTAssertGreaterThan(imp!.magnitude, 0.25)
    }

    func testDoubleTap() {
        var s = Stream(); s.rest(1); s.tap(amp: 0.3); s.rest(0.2); s.tap(amp: 0.3); s.rest(1)
        let t = taps(detect(s))
        XCTAssertEqual(t.map(\.count), [2])
    }

    func testTripleTapEmitsImmediately() {
        var s = Stream(); s.rest(1)
        s.tap(amp: 0.3); s.rest(0.2); s.tap(amp: 0.3); s.rest(0.2); s.tap(amp: 0.3)
        let endOfThird = s.t
        s.rest(1)
        let t = taps(detect(s))
        XCTAssertEqual(t.map(\.count), [3])
        // Emitted right after the third capture window, not after the group timeout.
        XCTAssertLessThan(t[0].t, endOfThird)
    }

    func testFourthTapIgnoredRightAfterTriple() {
        var s = Stream(); s.rest(1)
        for _ in 0..<4 { s.tap(amp: 0.3); s.rest(0.2) }
        s.rest(1)
        XCTAssertEqual(taps(detect(s)).map(\.count), [3])
    }

    func testTwoSeparateSingles() {
        var s = Stream(); s.rest(1); s.tap(amp: 0.3); s.rest(1); s.tap(amp: 0.3); s.rest(1)
        XCTAssertEqual(taps(detect(s)).map(\.count), [1, 1])
    }

    func testBelowThresholdIgnored() {
        var s = Stream(); s.rest(1); s.tap(amp: 0.02); s.rest(1)
        XCTAssertTrue(detect(s).isEmpty)
    }

    func testSuppressorVetoes() {
        var s = Stream(); s.rest(1); s.tap(amp: 0.3); s.rest(1)
        let d = TapDetector(); d.suppressor = { true }
        XCTAssertTrue(detect(s, detector: d).isEmpty)
    }

    func testRingingDoesNotDoubleCount() {
        // A big tap with a long ringing tail inside the refractory period.
        var s = Stream(); s.rest(1)
        for k in [1.0, 0.7, -0.5, 0.4, -0.3, 0.3, -0.2, 0.2, -0.15, 0.1] {
            s.samples.append(MotionSample(t: s.t, x: 0.5 * k, y: 0.98, z: 0.23)); s.t += 0.01
        }
        s.rest(1)
        XCTAssertEqual(impulses(detect(s)).count, 1)
    }

    func testSideFromClassifier() {
        var s = Stream(); s.rest(1); s.tap(amp: 0.3); s.rest(1)
        let cal = SideCalibration(feature: .gyroY, leftIsPositive: true, boundary: 0, separation: 5)
        let d = TapDetector(classifier: SideClassifier(calibration: cal))
        XCTAssertEqual(taps(detect(s, detector: d, gyroY: 0.5)).first?.side, .left)
        let d2 = TapDetector(classifier: SideClassifier(calibration: cal))
        XCTAssertEqual(taps(detect(s, detector: d2, gyroY: -0.5)).first?.side, .right)
    }

    func testCalibratingReportsImpulsesButNoTaps() {
        var s = Stream(); s.rest(1); s.tap(amp: 0.3); s.rest(1)
        let d = TapDetector(); d.calibrating = true
        let out = detect(s, detector: d)
        XCTAssertEqual(impulses(out).count, 1)
        XCTAssertTrue(taps(out).isEmpty)
    }
}

final class SideCalibrationTests: XCTestCase {
    private func imp(ax: Double = 0, gy: Double = 0, gz: Double = 0) -> TapImpulse {
        TapImpulse(t: 0, magnitude: 0.3, accelX: ax, accelY: 0, accelZ: 0, gyroX: 0, gyroY: gy, gyroZ: gz)
    }

    func testPicksSeparatingFeatureAndSign() {
        // gyroZ separates cleanly (left negative), gyroY is noise.
        let left = [imp(gy: 0.1, gz: -0.5), imp(gy: -0.2, gz: -0.6), imp(gy: 0.05, gz: -0.4)]
        let right = [imp(gy: 0.12, gz: 0.5), imp(gy: -0.1, gz: 0.7), imp(gy: 0.0, gz: 0.45)]
        let cal = calibrateSides(left: left, right: right)
        XCTAssertEqual(cal?.feature, .gyroZ)
        XCTAssertEqual(cal?.leftIsPositive, false)
        let c = SideClassifier(calibration: cal)
        XCTAssertEqual(c.side(of: imp(gz: -0.3)), .left)
        XCTAssertEqual(c.side(of: imp(gz: 0.3)), .right)
    }

    func testNoSeparationReturnsNil() {
        let left = [imp(gy: 0.1), imp(gy: -0.1), imp(gy: 0.2)]
        let right = [imp(gy: 0.1), imp(gy: -0.1), imp(gy: 0.2)]
        XCTAssertNil(calibrateSides(left: left, right: right))
    }

    func testEmptyReturnsNil() {
        XCTAssertNil(calibrateSides(left: [], right: [imp()]))
    }

    func testFallbackUsesGyroY() {
        let c = SideClassifier()
        XCTAssertEqual(c.side(of: imp(gy: 0.3)), .left)
        XCTAssertEqual(c.side(of: imp(gy: -0.3)), .right)
    }
}
