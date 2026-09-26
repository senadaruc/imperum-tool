import Foundation

public enum ClipCategory: String, CaseIterable, Equatable {
    case all, text, links, emails, colors, images, videos, files

    public var kind: ClipKind? {
        switch self {
        case .all: return nil
        case .text: return .text
        case .links: return .link
        case .emails: return .email
        case .colors: return .color
        case .images: return .image
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
        case .colors: return "Colors"
        case .images: return "Images"
        case .videos: return "Videos"
        case .files: return "Files"
        }
    }
}

public enum ClipFilter {
    /// Category first, then a case-insensitive substring match on the title
    /// and, for text-family clips, the body. Whitespace-only queries match all.
    public static func apply(_ clips: [Clip], category: ClipCategory, query: String) -> [Clip] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return clips.filter { c in
            if let k = category.kind, c.kind != k { return false }
            if q.isEmpty { return true }
            if c.title.lowercased().contains(q) { return true }
            if case .text(let body) = c.payload, body.lowercased().contains(q) { return true }
            if case .fileURLs(let urls) = c.payload, urls.contains(where: { $0.lastPathComponent.lowercased().contains(q) }) { return true }
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
            let day = calendar.startOfDay(for: c.capturedAt)
            if byDay[day] == nil { dayOrder.append(day) }
            byDay[day, default: []].append(c)
        }
        let fmt = DateFormatter()
        fmt.calendar = calendar; fmt.timeZone = calendar.timeZone; fmt.locale = Locale(identifier: "en_US_POSIX")
        fmt.dateStyle = .long; fmt.timeStyle = .none
        for day in dayOrder.sorted(by: >) {
            let title: String
            if day >= today { title = "Today" }              // includes "future" clips
            else if day == yesterday { title = "Yesterday" }
            else { title = fmt.string(from: day) }
            out.append(ClipSection(title: title, clips: byDay[day]!))
        }
        return out
    }
}
