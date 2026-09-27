// Sources/ImperumTool/ScreenshotWatcher.swift
import CoreServices
import Foundation

/// Thin FSEvents adapter: reports file-level events under the given roots on
/// the main queue. Knows nothing about screenshots; `ScreenshotImporter`
/// decides what to do with each path.
final class ScreenshotWatcher {
    private let onEvent: (String, Bool) -> Void
    private var stream: FSEventStreamRef?

    /// `onEvent(path, isRemoval)` — `isRemoval` is true for a delete/rename-away.
    init(onEvent: @escaping (String, Bool) -> Void) { self.onEvent = onEvent }

    var isRunning: Bool { stream != nil }

    /// Returns false when the stream could not be created or started.
    @discardableResult
    func start(paths: [String]) -> Bool {
        stop()
        guard !paths.isEmpty else { return false }
        var ctx = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(),
                                       retain: nil, release: nil, copyDescription: nil)
        let flags = UInt32(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagNoDefer)
        guard let s = FSEventStreamCreate(nil, ScreenshotWatcher.callback, &ctx, paths as CFArray,
                                          FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.2, flags) else { return false }
        FSEventStreamSetDispatchQueue(s, .main)
        guard FSEventStreamStart(s) else {
            FSEventStreamInvalidate(s); FSEventStreamRelease(s)
            return false
        }
        stream = s
        return true
    }

    func stop() {
        guard let s = stream else { return }
        FSEventStreamStop(s); FSEventStreamInvalidate(s); FSEventStreamRelease(s)
        stream = nil
    }

    deinit { stop() }

    private static let callback: FSEventStreamCallback = { _, info, count, eventPaths, eventFlags, _ in
        guard let info else { return }
        let me = Unmanaged<ScreenshotWatcher>.fromOpaque(info).takeUnretainedValue()
        guard let paths = unsafeBitCast(eventPaths, to: NSArray.self) as? [String] else { return }
        let flags = UnsafeBufferPointer(start: eventFlags, count: count)
        for (i, path) in paths.enumerated() {
            let f = Int(flags[i])
            guard f & kFSEventStreamEventFlagItemIsFile != 0 else { continue }
            let removed = f & kFSEventStreamEventFlagItemRemoved != 0
            me.onEvent(path, removed)
        }
    }
}
