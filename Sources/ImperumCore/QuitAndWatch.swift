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
