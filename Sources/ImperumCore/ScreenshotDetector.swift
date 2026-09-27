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

/// Where a screenshot clip came from, for pairing a CleanShot save with its copy.
public enum CaptureChannel: Equatable { case file, pasteboard }

/// Decides which file events are new screenshots and collapses a screenshot
/// that arrives twice (CleanShot save + copy). Pure: the app feeds it facts.
public struct ScreenshotDetector {
    public static let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "heic"]
    public static let dedupeWindow: TimeInterval = 5
    public static let settleDelay: TimeInterval = 0.3
    /// Sightings of one file before it is given up on (an empty or endlessly
    /// rewritten file must not be re-checked for the rest of the session).
    public static let maxSettleAttempts = 20
    public static let cleanShotMediaPath = "Library/Application Support/CleanShot/media"

    public let startedAt: Date
    /// First sighting of the current byte size per URL, for the settle check.
    private var lastSighting: [URL: (size: Int, at: Date)] = [:]
    private var attempts: [URL: Int] = [:]
    /// URLs already turned into clips, or given up on; later events are ignored.
    private var accepted: Set<URL> = []
    private var givenUp: Set<URL> = []
    /// Recent screenshot clips per channel, for pairing a save with its copy.
    private var recent: [(width: Int, height: Int, channel: CaptureChannel, clipID: UUID, at: Date)] = []

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
        // The Desktop is shared (downloads, exports, AirDrops land there), so it
        // is never dedicated, even when it is CleanShot's export folder (its
        // default): there only tagged or screenshot-named files count.
        for i in collapsed.indices where same(collapsed[i].url, desktop) { collapsed[i].dedicated = false }
        return collapsed
    }

    /// The most specific root containing `path` (FSEvents reports real paths,
    /// so callers pass roots with symlinks resolved). Matches on a `/`
    /// boundary, so "~/Desktop" never claims "~/Desktop Old/x.png".
    public static func root(for path: String, in roots: [ScreenshotRoot]) -> ScreenshotRoot? {
        roots
            .filter { let r = $0.url.standardizedFileURL.path; return path == r || path.hasPrefix(r.hasSuffix("/") ? r : r + "/") }
            .max { $0.url.standardizedFileURL.path.count < $1.url.standardizedFileURL.path.count }
    }

    /// Paths to hand FSEvents: a root nested inside another is already covered
    /// by its ancestor's recursive stream.
    public static func streamPaths(_ roots: [ScreenshotRoot]) -> [String] {
        let paths = roots.map { $0.url.standardizedFileURL.path }
        return paths.enumerated().filter { i, p in
            !paths.enumerated().contains { j, q in j != i && p != q && p.hasPrefix(q.hasSuffix("/") ? q : q + "/") }
                && paths.firstIndex(of: p) == i
        }.map(\.element)
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

    /// A file settles when two sightings at least `settleDelay` apart agree on
    /// a non-zero size. Sightings closer together (one FSEvents batch, two
    /// overlapping re-checks) keep the first sighting's time, so a writer
    /// pausing between chunks is never mistaken for a finished file.
    public mutating func verdict(for e: FileEvent, at now: Date) -> FileVerdict {
        guard Self.imageExtensions.contains(e.url.pathExtension.lowercased()) else { return .ignore }
        guard e.createdAt >= startedAt else { return .ignore }
        guard !accepted.contains(e.url), !givenUp.contains(e.url) else { return .ignore }
        let n = (attempts[e.url] ?? 0) + 1
        attempts[e.url] = n
        let settled: Bool
        if let prev = lastSighting[e.url], prev.size == e.byteSize, e.byteSize > 0 {
            settled = now.timeIntervalSince(prev.at) >= Self.settleDelay - 0.001
        } else {
            lastSighting[e.url] = (e.byteSize, now)
            settled = false
        }
        guard settled else {
            guard n < Self.maxSettleAttempts else { forget(e.url); givenUp.insert(e.url); return .ignore }
            return .settle
        }
        forget(e.url)
        let name = e.url.lastPathComponent
        let qualifies = e.isTaggedScreenCapture || e.root.dedicated || Self.matchesNativeName(name)
        guard qualifies else { return .ignore }
        accepted.insert(e.url)
        return .accept(name.hasPrefix("CleanShot ") ? .cleanShot : e.root.source)
    }

    private mutating func forget(_ url: URL) {
        lastSighting.removeValue(forKey: url)
        attempts.removeValue(forKey: url)
    }

    // MARK: Dedupe

    /// The same shot arriving through the other channel (CleanShot writes the
    /// file and, with copy-after-capture, the pasteboard): returns the id of
    /// the oldest same-size clip from the *other* channel within
    /// `dedupeWindow` and consumes it. Otherwise records this clip and returns
    /// nil. Same-channel repeats never match: two real shots of the same
    /// size (full screen, the same window) both land.
    public mutating func counterpart(width: Int, height: Int, channel: CaptureChannel, clipID: UUID, at now: Date) -> UUID? {
        recent.removeAll { now.timeIntervalSince($0.at) > Self.dedupeWindow }
        if let i = recent.firstIndex(where: { $0.width == width && $0.height == height && $0.channel != channel }) {
            return recent.remove(at: i).clipID
        }
        recent.append((width, height, channel, clipID, now))
        return nil
    }
}
