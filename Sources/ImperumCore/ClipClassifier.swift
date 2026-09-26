// Sources/ImperumCore/ClipClassifier.swift
import Foundation
import UniformTypeIdentifiers

/// Decides what a copied thing IS. Pure functions on strings and URLs so the
/// rules are unit-testable; the AppKit reader decides which representation to
/// hand in (files → image → colour → string).
public enum ClipClassifier {
    public static let maxTitleLength = 120

    private static let hexColor = try! NSRegularExpression(pattern: #"^#(?:[0-9a-fA-F]{3,4}|[0-9a-fA-F]{6}|[0-9a-fA-F]{8})$"#)
    private static let funcColor = try! NSRegularExpression(pattern: #"^(?:rgb|rgba|hsl|hsla)\(\s*[^()]+\)$"#, options: [.caseInsensitive])
    private static let email = try! NSRegularExpression(pattern: #"^[^\s@]+@[^\s@]+\.[^\s@]{2,}$"#)

    /// A link/email/colour string is never longer than this; above it we skip
    /// the trim + regex work entirely (`classifyText` runs on every clipboard
    /// change, so a multi-MB paste must not pay for a full-string regex scan).
    private static let maxClassifiableLength = 4096

    /// `nil` means "drop it" (empty / whitespace only).
    public static func classifyText(_ raw: String) -> ClipKind? {
        // Cheap check: returns at the first non-whitespace character instead
        // of trimming (which would allocate a full copy of a huge string).
        guard raw.contains(where: { !$0.isWhitespace }) else { return nil }
        if raw.utf8.count > maxClassifiableLength { return .text }
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if isColor(s) { return .color }
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
        // non-blank line.
        while idx < end, raw[idx].isWhitespace {
            idx = raw.index(after: idx)
        }
        guard idx < end else { return "" }
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

    /// "#RRGGBB" (alpha dropped) for any recognised colour string, else nil.
    public static func normalizedColorHex(_ raw: String) -> String? {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if matches(hexColor, s) {
            var hex = String(s.dropFirst()).uppercased()
            if hex.count == 3 || hex.count == 4 { hex = hex.map { "\($0)\($0)" }.joined() }
            return "#" + String(hex.prefix(6))
        }
        if matches(funcColor, s), s.lowercased().hasPrefix("rgb") {
            let inner = s.drop(while: { $0 != "(" }).dropFirst().dropLast()
            let parts = inner.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            guard parts.count >= 3 else { return nil }
            let comps = parts.prefix(3).compactMap { p -> Int? in
                if p.hasSuffix("%"), let v = Double(p.dropLast()) { return Int((v / 100 * 255).rounded()) }
                return Int(p)
            }
            guard comps.count == 3 else { return nil }
            return String(format: "#%02X%02X%02X", min(255, max(0, comps[0])), min(255, max(0, comps[1])), min(255, max(0, comps[2])))
        }
        return nil
    }

    // MARK: helpers

    private static func isColor(_ s: String) -> Bool { matches(hexColor, s) || matches(funcColor, s) }

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
