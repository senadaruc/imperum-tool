import Foundation

/// Which tool produced a screenshot. Used for the clip's source fields so a
/// shot taken while Safari was in front is not attributed to Safari.
public enum ScreenshotSource: String, Codable, Equatable {
    case native, cleanShot

    public var title: String {
        switch self {
        case .native: return "Screenshot"
        case .cleanShot: return "CleanShot X"
        }
    }

    public var bundleID: String {
        switch self {
        case .native: return "com.apple.screencapture"
        case .cleanShot: return "pl.maketheweb.cleanshotx"
        }
    }
}

/// A folder the app watches for new screenshot files.
public struct ScreenshotRoot: Equatable {
    public var url: URL
    public var source: ScreenshotSource
    /// True when every image written here is a screenshot (CleanShot's
    /// folders, a custom native location). False for the shared ~/Desktop,
    /// where only tagged files or native-named files count.
    public var dedicated: Bool
    public init(url: URL, source: ScreenshotSource, dedicated: Bool) {
        self.url = url; self.source = source; self.dedicated = dedicated
    }
}

/// One file-system sighting, already read by the caller (no I/O here).
public struct FileEvent: Equatable {
    public var url: URL
    public var root: ScreenshotRoot
    public var createdAt: Date
    public var byteSize: Int
    /// The `com.apple.metadata:kMDItemIsScreenCapture` xattr is present and true.
    public var isTaggedScreenCapture: Bool
    public init(url: URL, root: ScreenshotRoot, createdAt: Date, byteSize: Int, isTaggedScreenCapture: Bool) {
        self.url = url; self.root = root; self.createdAt = createdAt; self.byteSize = byteSize
        self.isTaggedScreenCapture = isTaggedScreenCapture
    }
}

/// `.settle` = ask again after `settleDelay` with a fresh byte size.
public enum FileVerdict: Equatable { case ignore, settle, accept(ScreenshotSource) }

/// Decides which file events are new screenshots and collapses a screenshot
/// that arrives twice (CleanShot save + copy). Pure: the app feeds it facts.
public struct ScreenshotDetector {
    public static let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "heic"]
    public static let dedupeWindow: TimeInterval = 5
    public static let settleDelay: TimeInterval = 0.3
    public static let cleanShotMediaPath = "Library/Application Support/CleanShot/media"

    public let startedAt: Date
    /// Last byte size seen per URL, for the settle check.
    private var lastSize: [URL: Int] = [:]
    /// URLs already turned into clips; later events for them are ignored.
    private var accepted: Set<URL> = []
    /// Recent screenshot pixel sizes, for dedupe.
    private var recent: [(width: Int, height: Int, at: Date)] = []

    public init(startedAt: Date) { self.startedAt = startedAt }

    // MARK: Roots

    /// The folders to watch, from raw defaults values. Trailing whitespace in
    /// `nativeLocation` is real (folder names may end in a space); `~` is
    /// expanded; empty/absent falls back to ~/Desktop. Duplicate folders
    /// collapse to one root, keeping `dedicated` if either side had it.
    public static func roots(nativeLocation: String?, cleanShotExportPath: String?, home: URL) -> [ScreenshotRoot] {
        let desktop = home.appendingPathComponent("Desktop", isDirectory: true)
        let nativeURL: URL = {
            guard let raw = nativeLocation, !raw.isEmpty else { return desktop }
            return expand(raw, home: home)
        }()
        var out: [ScreenshotRoot] = [
            ScreenshotRoot(url: nativeURL, source: .native, dedicated: !same(nativeURL, desktop)),
            ScreenshotRoot(url: home.appendingPathComponent(cleanShotMediaPath, isDirectory: true), source: .cleanShot, dedicated: true),
        ]
        if let raw = cleanShotExportPath, !raw.isEmpty {
            out.append(ScreenshotRoot(url: expand(raw, home: home), source: .cleanShot, dedicated: true))
        }
        var collapsed: [ScreenshotRoot] = []
        for r in out {
            if let i = collapsed.firstIndex(where: { same($0.url, r.url) }) {
                collapsed[i].dedicated = collapsed[i].dedicated || r.dedicated
            } else {
                collapsed.append(r)
            }
        }
        return collapsed
    }

    private static func expand(_ raw: String, home: URL) -> URL {
        if raw == "~" { return home }
        if raw.hasPrefix("~/") { return home.appendingPathComponent(String(raw.dropFirst(2)), isDirectory: true) }
        return URL(fileURLWithPath: raw, isDirectory: true)
    }

    private static func same(_ a: URL, _ b: URL) -> Bool {
        a.standardizedFileURL.path == b.standardizedFileURL.path
    }

    // MARK: Native file names

    private static let datePattern = try! NSRegularExpression(pattern: #"\d{4}-\d{2}-\d{2}"#)
    private static let timePattern = try! NSRegularExpression(pattern: #"\d{2}\.\d{2}\.\d{2}"#)

    /// "Screenshot 2026-09-27 at 11.06.37.png", "Bildschirmfoto 2026-09-27 um
    /// 11.06.37.png": every locale keeps the `YYYY-MM-DD` date and the
    /// `HH.MM.SS` time, only the words change.
    public static func matchesNativeName(_ fileName: String) -> Bool {
        let range = NSRange(fileName.startIndex..., in: fileName)
        return datePattern.firstMatch(in: fileName, range: range) != nil && timePattern.firstMatch(in: fileName, range: range) != nil
    }

    // MARK: Verdicts

    public mutating func verdict(for e: FileEvent) -> FileVerdict {
        guard Self.imageExtensions.contains(e.url.pathExtension.lowercased()) else { return .ignore }
        guard e.createdAt >= startedAt else { return .ignore }
        guard !accepted.contains(e.url) else { return .ignore }
        let previous = lastSize[e.url]
        lastSize[e.url] = e.byteSize
        guard let previous, previous == e.byteSize, e.byteSize > 0 else { return .settle }
        let qualifies = e.isTaggedScreenCapture || e.root.dedicated
            || (e.root.source == .native && Self.matchesNativeName(e.url.lastPathComponent))
        guard qualifies else { return .ignore }
        accepted.insert(e.url)
        lastSize.removeValue(forKey: e.url)
        return .accept(e.root.source)
    }

    // MARK: Dedupe

    /// True when a screenshot of this pixel size was seen within
    /// `dedupeWindow`. Otherwise records this one and returns false.
    public mutating func isDuplicate(width: Int, height: Int, at now: Date) -> Bool {
        recent.removeAll { now.timeIntervalSince($0.at) > Self.dedupeWindow }
        if recent.contains(where: { $0.width == width && $0.height == height }) { return true }
        recent.append((width, height, now))
        return false
    }
}
