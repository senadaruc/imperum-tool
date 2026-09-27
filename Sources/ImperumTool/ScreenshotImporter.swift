// Sources/ImperumTool/ScreenshotImporter.swift
import AppKit
import ImperumCore

/// Owns the folder watcher and the pure detector. Turns new screenshot files
/// into `CapturedClip`s for the controller, and answers the pasteboard path's
/// "is this a duplicate of a screenshot we just imported?" question so a
/// CleanShot save+copy yields one clip.
final class ScreenshotImporter {
    var onCaptured: ((CapturedClip) -> Void)?
    var onStatusChanged: (() -> Void)?
    /// Human-readable state for the settings caption.
    private(set) var status = "" { didSet { if status != oldValue { onStatusChanged?() } } }

    private var detector = ScreenshotDetector(startedAt: Date())
    private lazy var watcher = ScreenshotWatcher { [weak self] path, removed in self?.handle(path: path, removed: removed) }
    private var roots: [ScreenshotRoot] = []
    private var enabled = false
    private var streamFailed = false

    // MARK: Lifecycle

    func update(enabled: Bool) {
        self.enabled = enabled
        if enabled { refreshRoots() } else { watcher.stop(); roots = []; status = "" }
    }

    /// Re-reads both apps' defaults, drops roots that don't exist, and
    /// restarts the stream if the set changed. Called on every settings
    /// apply and on volume mount/unmount.
    func refreshRoots() {
        guard enabled else { return }
        let native = UserDefaults(suiteName: "com.apple.screencapture")?.string(forKey: "location")
        let export = UserDefaults(suiteName: "pl.maketheweb.cleanshotx")?.string(forKey: "exportPath")
        let home = FileManager.default.homeDirectoryForCurrentUser
        let all = ScreenshotDetector.roots(nativeLocation: native, cleanShotExportPath: export, home: home)
        var isDir: ObjCBool = false
        let present = all.filter { FileManager.default.fileExists(atPath: $0.url.path, isDirectory: &isDir) && isDir.boolValue }
        let nativeMissing = all.contains { $0.source == .native } && !present.contains { $0.source == .native }
        if present != roots || !watcher.isRunning {
            roots = present
            detector = ScreenshotDetector(startedAt: Date())
            streamFailed = !present.isEmpty && !watcher.start(paths: present.map(\.url.path))
        }
        status = Self.statusText(watched: present, nativeMissing: nativeMissing, streamFailed: streamFailed)
    }

    static func statusText(watched: [ScreenshotRoot], nativeMissing: Bool, streamFailed: Bool) -> String {
        if streamFailed { return "Screenshot watching is unavailable this session" }
        var parts: [String] = []
        if !watched.isEmpty {
            parts.append("Watching: " + watched.map { ($0.url.path as NSString).abbreviatingWithTildeInPath }.joined(separator: ", "))
        }
        if nativeMissing { parts.append("Screenshot folder not available (volume not mounted)") }
        return parts.joined(separator: ". ")
    }

    // MARK: Pasteboard-side dedupe

    func isDuplicate(width: Int, height: Int) -> Bool {
        detector.isDuplicate(width: width, height: height, at: Date())
    }

    // MARK: File events

    private func handle(path: String, removed: Bool) {
        guard enabled, !removed else { return }
        let url = URL(fileURLWithPath: path)
        guard let root = roots.first(where: { url.path.hasPrefix($0.url.path) }) else { return }
        guard let event = Self.fileEvent(url: url, root: root) else { return }
        switch detector.verdict(for: event) {
        case .ignore: return
        case .settle:
            DispatchQueue.main.asyncAfter(deadline: .now() + ScreenshotDetector.settleDelay) { [weak self] in
                self?.handle(path: path, removed: false)
            }
        case .accept(let source):
            importFile(url, source: source)
        }
    }

    private static func fileEvent(url: URL, root: ScreenshotRoot) -> FileEvent? {
        guard let values = try? url.resourceValues(forKeys: [.creationDateKey, .fileSizeKey, .isRegularFileKey]),
              values.isRegularFile == true else { return nil }
        return FileEvent(url: url, root: root, createdAt: values.creationDate ?? .distantPast,
                         byteSize: values.fileSize ?? 0, isTaggedScreenCapture: isTaggedScreenCapture(url))
    }

    /// `com.apple.metadata:kMDItemIsScreenCapture`, a bplist boolean written by
    /// CleanShot (and by some macOS versions). Present-but-undecodable counts
    /// as tagged: only screenshot tools write this attribute at all.
    private static func isTaggedScreenCapture(_ url: URL) -> Bool {
        let name = "com.apple.metadata:kMDItemIsScreenCapture"
        return url.withUnsafeFileSystemRepresentation { fsPath -> Bool in
            guard let fsPath else { return false }
            let size = getxattr(fsPath, name, nil, 0, 0, 0)
            guard size > 0 else { return false }
            var buf = [UInt8](repeating: 0, count: size)
            guard getxattr(fsPath, name, &buf, size, 0, 0) == size else { return false }
            let value = try? PropertyListSerialization.propertyList(from: Data(buf), options: [], format: nil)
            return (value as? Bool) ?? true
        }
    }

    private func importFile(_ url: URL, source: ScreenshotSource) {
        guard let img = ImageFile.pngImage(at: url) else {
            NSLog("Imperum Tool screenshots: could not decode \(url.lastPathComponent)")
            return
        }
        guard !detector.isDuplicate(width: img.width, height: img.height, at: Date()) else { return }
        let id = ClipCapture.contentID(img.data)
        let clip = Clip(id: id, kind: .screenshot, capturedAt: Date(), sourceAppName: source.title, sourceBundleID: source.bundleID,
                        title: ClipClassifier.title(screenshotWidth: img.width, height: img.height),
                        payload: .blob(id: id, utType: "public.png", width: img.width, height: img.height))
        onCaptured?(CapturedClip(clip: clip, blobData: img.data))
    }
}
