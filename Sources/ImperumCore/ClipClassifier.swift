// Sources/ImperumCore/ClipClassifier.swift
import Foundation
import UniformTypeIdentifiers

/// Decides what a copied thing IS. Pure functions on strings and URLs so the
/// rules are unit-testable; the AppKit reader decides which representation to
/// hand in (files → text-vs-image → string). Round 10: colour is no longer a
/// distinct kind — a colour-shaped string classifies as plain `.text`.
public enum ClipClassifier {
    public static let maxTitleLength = 120

    /// Cap on how many leading whitespace/blank-line Characters `title(forText:)`
    /// will skip before giving up. A clip that is entirely (or almost entirely)
    /// leading whitespace/blank lines for megabytes must not be scanned
    /// character-by-character in full; past this cap we return "" rather than
    /// keep looking for real content.
    private static let maxLeadingWhitespaceScan = 4096

    private static let email = try! NSRegularExpression(pattern: #"^[^\s@]+@[^\s@]+\.[^\s@]{2,}$"#)

    /// A link/email string is never longer than this; above it we skip the
    /// trim + regex work entirely (`classifyText` runs on every clipboard
    /// change, so a multi-MB paste must not pay for a full-string regex scan).
    private static let maxClassifiableLength = 4096

    /// `nil` means "drop it" (empty / whitespace only).
    public static func classifyText(_ raw: String) -> ClipKind? {
        // Cheap check: returns at the first non-whitespace character instead
        // of trimming (which would allocate a full copy of a huge string).
        guard raw.contains(where: { !$0.isWhitespace }) else { return nil }
        if raw.utf8.count > maxClassifiableLength { return .text }
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if isLink(s) { return .link }
        if matches(email, s) { return .email }
        return .text
    }

    public static func kindForFile(_ url: URL) -> ClipKind {
        if let type = UTType(filenameExtension: url.pathExtension), type.conforms(to: .movie) { return .video }
        return .file
    }

    public static func title(forText raw: String) -> String {
        // Walk forward one Character at a time so cost is bounded by
        // maxTitleLength, never by the length of the input: a multi-MB clip
        // (one giant line, or many blank lines) must title instantly.
        // `Character.isNewline` (not literal "\n") so \r, \r\n and U+2028
        // are all recognised as line breaks.
        var idx = raw.startIndex
        let end = raw.endIndex
        // Skip leading blank lines and leading whitespace on the first
        // non-blank line, but never more than maxLeadingWhitespaceScan
        // Characters: a multi-MB run of whitespace must not be walked in
        // full just to discover there is no real content (or to find it
        // far past a reasonable title length).
        var skipped = 0
        while idx < end, skipped < maxLeadingWhitespaceScan, raw[idx].isWhitespace {
            idx = raw.index(after: idx)
            skipped += 1
        }
        guard idx < end, !raw[idx].isWhitespace else { return "" }
        var result = ""
        result.reserveCapacity(maxTitleLength)
        var count = 0
        while idx < end, count < maxTitleLength {
            let c = raw[idx]
            if c.isNewline { break }
            result.append(c)
            count += 1
            idx = raw.index(after: idx)
        }
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public static func title(forFiles urls: [URL]) -> String {
        guard let first = urls.first else { return "" }
        let rest = urls.count - 1
        return rest > 0 ? "\(first.lastPathComponent) +\(rest) more" : first.lastPathComponent
    }

    public static func title(imageWidth w: Int, height h: Int) -> String { "Image \(w)×\(h)" }
    public static func title(screenshotWidth w: Int, height h: Int) -> String { "Screenshot \(w)×\(h)" }

    // MARK: helpers

    private static func isLink(_ s: String) -> Bool {
        guard s.rangeOfCharacter(from: .whitespacesAndNewlines) == nil,
              let u = URL(string: s), let scheme = u.scheme?.lowercased(),
              scheme == "http" || scheme == "https", let host = u.host, !host.isEmpty else { return false }
        return true
    }

    private static func matches(_ re: NSRegularExpression, _ s: String) -> Bool {
        re.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) != nil
    }
}
