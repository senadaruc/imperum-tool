import Foundation

/// Measures the number of terminal display columns a string or scalar
/// occupies. Foundation-only: does not rely on `Darwin.wcwidth`, whose
/// behaviour depends on the process locale and can vary across terminals.
///
/// ## Zero-width joiner (ZWJ) sequences
/// A ZWJ sequence (e.g. the "family" emoji built from several emoji joined
/// by U+200D) renders as a single glyph in modern terminals, but terminal
/// emulators vary in how many columns they actually allocate to it. This
/// implementation adopts the simplest consistent rule: only the first
/// scalar of a ZWJ-joined run contributes its width; the ZWJ itself and
/// every scalar that follows a ZWJ contribute zero. This makes a ZWJ family
/// emoji width 2 (matching its first emoji component) rather than the sum
/// of all its parts, which keeps column accounting predictable even though
/// some terminals render the glyph wider.
public enum DisplayWidth {
    /// Combining marks (general categories Mn, Me, Mc).
    private static func isCombiningMark(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.properties.generalCategory {
        case .nonspacingMark, .enclosingMark, .spacingMark:
            return true
        default:
            return false
        }
    }

    private static let zeroWidthRanges: [ClosedRange<UInt32>] = [
        0x200B...0x200F, // zero-width space/joiners/marks, direction marks
        0xFE00...0xFE0F, // variation selectors
        0xFEFF...0xFEFF, // zero-width no-break space / BOM
    ]

    private static let wideRanges: [ClosedRange<UInt32>] = [
        0x1100...0x115F,
        0x2E80...0x303E, // split around 0x303F exclusion below
        0x3041...0xA4CF, // continues the "2E80-A4CF except 303F" range
        0xAC00...0xD7A3,
        0xF900...0xFAFF,
        0xFE30...0xFE4F,
        0xFF00...0xFF60,
        0xFFE0...0xFFE6,
        0x1F300...0x1F64F,
        0x1F900...0x1F9FF,
        0x20000...0x3FFFD,
        0x1F000...0x1FAFF,
    ]

    /// Width of a single Unicode scalar, ignoring ZWJ-sequence context.
    public static func of(_ scalar: Unicode.Scalar) -> Int {
        let v = scalar.value
        if v < 0x20 || v == 0x7F {
            return 0
        }
        if v == 0x200D { // ZWJ itself
            return 0
        }
        if isCombiningMark(scalar) {
            return 0
        }
        for range in zeroWidthRanges where range.contains(v) {
            return 0
        }
        for range in wideRanges where range.contains(v) {
            return 2
        }
        return 1
    }

    /// Total display width of a string, honoring the ZWJ-sequence rule
    /// documented on this type: only the first scalar of a run joined by
    /// U+200D contributes width.
    public static func of(_ s: String) -> Int {
        var total = 0
        var suppressNext = false
        for scalar in s.unicodeScalars {
            if scalar.value == 0x200D {
                suppressNext = true
                continue
            }
            if suppressNext {
                suppressNext = false
                continue
            }
            total += of(scalar)
        }
        return total
    }

    /// Truncates `s` so its display width never exceeds `columns`, appending
    /// `ellipsis` when a cut was made. Never splits a grapheme cluster.
    /// Returns "" when `columns <= 0`.
    public static func truncate(_ s: String, to columns: Int, ellipsis: String = "…") -> String {
        guard columns > 0 else { return "" }
        if of(s) <= columns {
            return s
        }
        let ellipsisWidth = of(ellipsis)
        let budget = columns - ellipsisWidth
        if budget <= 0 {
            return ellipsisWidth <= columns ? ellipsis : ""
        }
        var result = ""
        var used = 0
        for cluster in s {
            let w = of(String(cluster))
            if used + w > budget {
                break
            }
            result.append(cluster)
            used += w
        }
        return result + ellipsis
    }

    /// Right-pads `s` with spaces to exactly `columns` display columns,
    /// truncating first if `s` is already wider.
    public static func pad(_ s: String, to columns: Int) -> String {
        guard columns > 0 else { return "" }
        let truncated = of(s) > columns ? truncate(s, to: columns) : s
        let currentWidth = of(truncated)
        let padding = max(0, columns - currentWidth)
        return truncated + String(repeating: " ", count: padding)
    }
}
