// Sources/ImperumCore/HostExclusion.swift
import Foundation

/// Pure hostname matching for the Copy Stack's per-website exclusions.
/// Entries are stored as bare lowercase hosts (e.g. `example.com`) and shown
/// to the user as `*.example.com` — each entry matches the site itself and
/// all its subdomains.
public enum HostExclusion {
    private static let allowedCharacters = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789.-")

    /// Matches a scheme only at the very start of the input (`http://`,
    /// `https://`, ...), so a scheme embedded further in — e.g. inside a
    /// query string like `example.com/r?u=http://x.org` — is never mistaken
    /// for the start of the host.
    private static let leadingSchemeRegex = try! NSRegularExpression(pattern: "^[a-z][a-z0-9+.-]*://")

    /// Turns user input into a stored entry, or nil when it can't be made
    /// into a valid host. Strips a leading scheme, userinfo, port,
    /// path/query/fragment, a leading `*.` or `www.`, and a trailing `.`.
    /// Non-ASCII (IDN) input is rejected; a punycode (`xn--`) host is
    /// accepted as-is.
    public static func normalize(_ input: String) -> String? {
        var s = input.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !s.isEmpty else { return nil }

        let fullRange = NSRange(s.startIndex..., in: s)
        if let match = leadingSchemeRegex.firstMatch(in: s, range: fullRange), let range = Range(match.range, in: s) {
            s = String(s[range.upperBound...])
        }

        if let cut = s.firstIndex(where: { "/?#".contains($0) }) {
            s = String(s[s.startIndex..<cut])
        }

        if let at = s.lastIndex(of: "@") {
            s = String(s[s.index(after: at)...])
        }

        if let colon = s.firstIndex(of: ":") {
            s = String(s[s.startIndex..<colon])
        }

        if s.hasPrefix("*.") { s.removeFirst(2) }
        if s.hasPrefix("www.") { s.removeFirst(4) }
        while s.hasSuffix(".") { s.removeLast() }

        guard !s.isEmpty, s.contains("."), s.rangeOfCharacter(from: allowedCharacters.inverted) == nil else { return nil }
        let labels = s.split(separator: ".", omittingEmptySubsequences: false)
        guard labels.allSatisfy({ !$0.isEmpty }) else { return nil }
        return s
    }

    /// Display form shown in the settings UI: `"*." + entry`.
    public static func display(_ entry: String) -> String { "*." + entry }

    /// True when `host` equals one of `entries`, or is a subdomain of one
    /// (case-insensitive; a trailing dot on `host` is ignored).
    public static func matches(host: String, entries: [String]) -> Bool {
        var h = host.lowercased()
        if h.hasSuffix(".") { h.removeLast() }
        guard !h.isEmpty else { return false }
        for entry in entries {
            let e = entry.lowercased()
            guard !e.isEmpty else { continue }
            if h == e || h.hasSuffix("." + e) { return true }
        }
        return false
    }
}
