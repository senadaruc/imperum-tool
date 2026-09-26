import Foundation

/// Terminal-injection defence for clip text rendered in the TUI.
///
/// Untrusted clipboard content could contain raw escape sequences designed
/// to manipulate the terminal (color/cursor tricks, or data-exfiltration
/// sequences like OSC 52 clipboard writes). `Sanitize` strips anything that
/// could be interpreted as a control or escape sequence before it is drawn,
/// replacing each such sequence with a single visible "·" marker so the
/// presence of stripped content is not silently hidden.
public enum Sanitize {
    /// Sanitises a single line of text: C0 controls (except `\t`), DEL, C1
    /// controls (0x80–0x9F), and any ESC-initiated sequence (CSI, OSC, or a
    /// generic two-byte escape) are replaced by "·"; `\n` becomes "⏎"; `\r`
    /// is dropped; `\t` becomes four spaces.
    public static func line(_ s: String) -> String {
        let scalars = Array(s.unicodeScalars)
        var result = String.UnicodeScalarView()
        var i = 0
        while i < scalars.count {
            let scalar = scalars[i]
            let v = scalar.value

            if v == 0x1B {
                i = consumeEscapeSequence(scalars, from: i)
                result.append("·")
                continue
            }
            if v == 0x9B { // C1 CSI, single-byte introducer
                i = consumeC1CSI(scalars, from: i)
                result.append("·")
                continue
            }
            if v >= 0x80 && v <= 0x9F { // other C1 controls
                result.append("·")
                i += 1
                continue
            }

            switch v {
            case 0x0A:
                result.append("⏎")
            case 0x0D:
                break // dropped; a following \n (CRLF) still yields one ⏎
            case 0x09:
                result.append(contentsOf: "    ".unicodeScalars)
            case 0x00...0x1F, 0x7F:
                result.append("·")
            default:
                result.append(scalar)
            }
            i += 1
        }
        return String(result)
    }

    /// Splits `s` on `\n` (before any replacement), sanitises each line, and
    /// returns at most `max` lines.
    public static func lines(_ s: String, max: Int) -> [String] {
        let rawLines = s.split(separator: "\n", omittingEmptySubsequences: false)
        return rawLines.prefix(max).map { line(String($0)) }
    }

    // MARK: - Sequence consumption

    /// Consumes an ESC-initiated sequence starting at `index` (which must
    /// point at the ESC scalar) and returns the index just past it.
    private static func consumeEscapeSequence(_ scalars: [Unicode.Scalar], from index: Int) -> Int {
        guard index + 1 < scalars.count else {
            return index + 1 // lone trailing ESC
        }
        let next = scalars[index + 1]
        if next.value == 0x5B { // '[' -> CSI
            return consumeCSIBody(scalars, from: index + 2)
        }
        if next.value == 0x5D { // ']' -> OSC
            return consumeOSCBody(scalars, from: index + 2)
        }
        // Generic two-byte escape (e.g. alt-key or simple ESC sequences).
        return index + 2
    }

    /// Consumes CSI parameter/intermediate bytes starting at `index` up to
    /// and including the final byte (0x40–0x7E), given the introducer has
    /// already been consumed by the caller.
    private static func consumeCSIBody(_ scalars: [Unicode.Scalar], from index: Int) -> Int {
        var i = index
        while i < scalars.count {
            let v = scalars[i].value
            if v >= 0x40 && v <= 0x7E {
                return i + 1
            }
            i += 1
        }
        return i
    }

    /// Consumes a C1 CSI sequence (introduced by U+009B) starting at `index`,
    /// which must point at the 0x9B scalar itself.
    private static func consumeC1CSI(_ scalars: [Unicode.Scalar], from index: Int) -> Int {
        return consumeCSIBody(scalars, from: index + 1)
    }

    /// Consumes an OSC body starting at `index` (just past `ESC ]`) up to and
    /// including its terminator: BEL (0x07) or ST (`ESC \`).
    private static func consumeOSCBody(_ scalars: [Unicode.Scalar], from index: Int) -> Int {
        var i = index
        while i < scalars.count {
            let v = scalars[i].value
            if v == 0x07 {
                return i + 1
            }
            if v == 0x1B && i + 1 < scalars.count && scalars[i + 1].value == 0x5C {
                return i + 2
            }
            i += 1
        }
        return i
    }
}
