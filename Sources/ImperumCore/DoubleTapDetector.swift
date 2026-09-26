import Foundation

/// The double-tap rule as a pure state machine. The AppKit tap feeds key
/// events and its timer in; the decision says what to do with the event:
///  - `.hold`        swallow this ⌘V and arm a timer for `window`
///  - `.swallow`     drop the event (key repeat while holding)
///  - `.pasteNow`    post a real ⌘V now (then, for `.other`, pass that event on)
///  - `.openPanel`   cancel the timer, do not paste, open the copy stack
///  - `.passThrough` nothing to do with us
public struct DoubleTapDetector: Equatable {
    public enum Input: Equatable { case cmdV(at: TimeInterval, isRepeat: Bool), other, timerFired }
    public enum Decision: Equatable { case hold, swallow, pasteNow, openPanel, passThrough }

    public var window: TimeInterval
    private var holding = false

    public init(window: TimeInterval = 0.3) { self.window = window }

    public mutating func feed(_ input: Input) -> Decision {
        switch (holding, input) {
        case (false, .cmdV(_, let isRepeat)):
            if isRepeat { return .passThrough }
            holding = true
            return .hold
        case (false, _):
            return .passThrough
        case (true, .cmdV(_, let isRepeat)):
            if isRepeat { return .swallow }
            holding = false
            return .openPanel
        case (true, .other), (true, .timerFired):
            holding = false
            return .pasteNow
        }
    }
}
