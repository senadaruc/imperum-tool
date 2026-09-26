// Sources/ImperumCore/HostExclusion.swift
import Foundation

/// Pure hostname matching for the Copy Stack's per-website exclusions.
/// Entries are stored as bare lowercase hosts (e.g. `example.com`) and shown
/// to the user as `*.example.com` — each entry matches the site itself and
/// all its subdomains.
public enum HostExclusion {
    private static let allowedCharacters = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789.-")

    /// Turns user input into a stored entry, or nil when it can't be made
    /// into a valid host. Strips a scheme, userinfo, port, path/query/
    /// fragment, a leading `*.` or `www.`, and a trailing `.`. IDN input is
    /// only lowercased, never punycode-encoded.
    public static func normalize(_ input: String) -> String? {
        var s = input.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !s.isEmpty else { return nil }

        if let schemeRange = s.range(of: "://") {
            s = String(s[schemeRange.upperBound...])
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
            if h == e || h.hasSuffix("." + e) { return true }
        }
        return false
    }
}
