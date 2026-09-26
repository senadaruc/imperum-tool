import Foundation

/// Drives the wait between "picker exited" and "post ⌘V into the origin
/// terminal". Pure and side-effect free: `PickSession` (ImperumTool) samples
/// the real world (frontmost app, AX focus, the picker window) into an
/// `Observation` on a repeating timer and acts on the returned `Step`.
public struct FocusWait: Equatable {
    public struct Observation: Equatable {
        public let originIsFrontmost: Bool     // frontmost pid == origin pid
        public let originWindowFocused: Bool   // origin's AXFocusedWindow equals the recorded one
        public let pickerWindowGone: Bool      // no window with the picker title for the host pid
        public let elapsedMs: Int

        public init(originIsFrontmost: Bool, originWindowFocused: Bool, pickerWindowGone: Bool, elapsedMs: Int) {
            self.originIsFrontmost = originIsFrontmost
            self.originWindowFocused = originWindowFocused
            self.pickerWindowGone = pickerWindowGone
            self.elapsedMs = elapsedMs
        }
    }

    public enum Step: Equatable { case wait, nudge, post, timeout }

    private let nudgeAfterMs: Int
    private let timeoutMs: Int
    private let stableTicks: Int

    private var stableCount = 0
    private var didNudge = false
    private var finished = false   // set once .post or .timeout has been returned

    public init(nudgeAfterMs: Int = 150, timeoutMs: Int = 1500, stableTicks: Int = 2) {
        self.nudgeAfterMs = nudgeAfterMs
        self.timeoutMs = timeoutMs
        self.stableTicks = stableTicks
    }

    public mutating func step(_ o: Observation) -> Step {
        guard !finished else { return .wait }

        let ready = o.originIsFrontmost && o.originWindowFocused && o.pickerWindowGone
        if ready {
            stableCount += 1
            if stableCount >= stableTicks {
                finished = true
                return .post
            }
            return .wait
        }
        stableCount = 0

        if o.elapsedMs >= timeoutMs {
            finished = true
            return .timeout
        }
        if !didNudge, o.elapsedMs >= nudgeAfterMs {
            didNudge = true
            return .nudge
        }
        return .wait
    }
}
