import Foundation

public enum ClipCategory: String, CaseIterable, Equatable {
    case all, text, links, emails, images, screenshots, videos, files

    public var kind: ClipKind? {
        switch self {
        case .all: return nil
        case .text: return .text
        case .links: return .link
        case .emails: return .email
        case .images: return .image
        case .screenshots: return .screenshot
        case .videos: return .video
        case .files: return .file
        }
    }

    public var title: String {
        switch self {
        case .all: return "All"
        case .text: return "Text"
        case .links: return "Links"
        case .emails: return "Emails"
        case .images: return "Images"
        case .screenshots: return "Screenshots"
        case .videos: return "Videos"
        case .files: return "Files"
        }
    }

    /// The category a clip of `kind` is counted under for per-category
    /// limits: the same rule the chips use, so a legacy `.color` clip is Text.
    public init(kind: ClipKind) {
        switch kind {
        case .text, .color: self = .text
        case .link: self = .links
        case .email: self = .emails
        case .image: self = .images
        case .screenshot: self = .screenshots
        case .video: self = .videos
        case .file: self = .files
        }
    }

    /// Whether a clip of kind `k` belongs in this category. `.text` also
    /// matches the legacy `.color` kind (round 10: Colors is no longer a
    /// distinct category, but old archives may still hold `.color` clips —
    /// they stay reachable under Text rather than disappearing).
    fileprivate func matches(_ k: ClipKind) -> Bool {
        guard let target = kind else { return true }   // .all
        if self == .text { return k == .text || k == .color }
        return k == target
    }
}

public enum ClipFilter {
    /// Category first, then a case- and diacritic-insensitive substring match
    /// on the title and, for text-family clips, the body. Whitespace-only
    /// queries match all.
    public static func apply(_ clips: [Clip], category: ClipCategory, query: String) -> [Clip] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        func matches(_ s: String) -> Bool {
            s.range(of: q, options: [.caseInsensitive, .diacriticInsensitive]) != nil
        }
        return clips.filter { c in
            if !category.matches(c.kind) { return false }
            if q.isEmpty { return true }
            if matches(c.title) { return true }
            if case .text(let body) = c.payload, matches(body) { return true }
            if case .fileURLs(let urls) = c.payload, urls.contains(where: { matches($0.lastPathComponent) }) { return true }
            return false
        }
    }
}

public struct ClipSection: Equatable {
    public let title: String
    public let clips: [Clip]
    public init(title: String, clips: [Clip]) { self.title = title; self.clips = clips }
}

public enum ClipGrouper {
    /// Pinned, Today, Yesterday, then one section per older calendar day
    /// (localised long date). Input order is preserved inside each section.
    public static func sections(_ clips: [Clip], now: Date, calendar: Calendar) -> [ClipSection] {
        var out: [ClipSection] = []
        let pinned = clips.filter(\.isPinned)
        if !pinned.isEmpty { out.append(ClipSection(title: "Pinned", clips: pinned)) }

        let today = calendar.startOfDay(for: now)
        let yesterday = calendar.date(byAdding: .day, value: -1, to: today)!
        var dayOrder: [Date] = []
        var byDay: [Date: [Clip]] = [:]
        for c in clips where !c.isPinned {
            // Any day at or after today (including "future" clips from a
            // clock set back) collapses into the single Today bucket so
            // Task 12's title-keyed ForEach never sees duplicate "Today"s.
            let rawDay = calendar.startOfDay(for: c.capturedAt)
            let day = rawDay >= today ? today : rawDay
            if byDay[day] == nil { dayOrder.append(day) }
            byDay[day, default: []].append(c)
        }
        let fmt = DateFormatter()
        fmt.calendar = calendar; fmt.timeZone = calendar.timeZone; fmt.locale = calendar.locale ?? .current
        fmt.dateStyle = .long; fmt.timeStyle = .none
        for day in dayOrder.sorted(by: >) {
            let title: String
            if day == today { title = "Today" }
            else if day == yesterday { title = "Yesterday" }
            else { title = fmt.string(from: day) }
            out.append(ClipSection(title: title, clips: byDay[day]!))
        }
        return out
    }
}
