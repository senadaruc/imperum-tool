import Foundation

/// A decoded terminal input event.
public enum Key: Equatable {
    case char(Character)            // printable text incl. space; UTF-8 assembled across feeds
    case up, down, left, right, pageUp, pageDown, home, end
    case enter, backspace, escape, tab
    case ctrl(Character)            // ctrl("c"), ctrl("p"), ctrl("d"), ctrl("u"), ctrl("n"), ctrl("k"), ctrl("j")... lowercase letter
    case alt(Character)             // ESC followed by a printable within the same feed or before flush: alt("1")…alt("9")
    case paste(String)              // bracketed paste ESC[200~ … ESC[201~ (may span feeds)
    case unknown([UInt8])
}

/// Incremental parser for raw terminal input bytes into `Key` events.
///
/// The parser is fed raw bytes as they arrive from the terminal (which may
/// split any multi-byte sequence — a UTF-8 character, a CSI escape sequence,
/// or a bracketed-paste payload — across arbitrary feed boundaries) and
/// produces zero or more complete `Key` values per call.
///
/// ## Escape-key vs. Alt-key disambiguation
/// A bare ESC byte (0x1B) is ambiguous: it could be the Escape key on its
/// own, or the first byte of an Alt-modified key (`ESC` + printable), or the
/// first byte of a CSI/SS3 sequence. This parser resolves the ambiguity by
/// buffering a lone trailing ESC and waiting for one of:
///   - another byte arrives (in the same `feed` call, or a later one) that
///     completes an alt-key, a CSI sequence, or an SS3 sequence, or
///   - `flushTimeout()` is called (the I/O loop calls this after ~30ms with
///     no further bytes), at which point the pending ESC resolves to `.escape`.
/// This mirrors the common terminal convention (used by e.g. readline/vim)
/// of treating "ESC followed quickly by a printable" as Alt+key, and "ESC
/// followed by a pause" as the Escape key itself.
public struct KeyParser {
    private enum State {
        case normal
        case afterEsc                 // saw ESC, waiting for next byte
        case afterEscBracket          // saw ESC [
        case csiParams([UInt8])       // collecting CSI parameter/intermediate bytes after ESC [
        case afterEscO                // saw ESC O (SS3)
        case pasteBody([UInt8])       // inside bracketed paste, collecting bytes until ESC[201~
    }

    private var state: State = .normal
    private var utf8Buffer: [UInt8] = []

    public init() {}

    public var hasPendingEscape: Bool {
        if case .afterEsc = state { return true }
        return false
    }

    public mutating func feed(_ bytes: [UInt8]) -> [Key] {
        var out: [Key] = []
        var i = 0
        while i < bytes.count {
            let b = bytes[i]
            switch state {
            case .normal:
                if b == 0x1B {
                    state = .afterEsc
                } else if let key = mapControlByte(b) {
                    out.append(key)
                } else {
                    // Part of a (possibly multi-byte) UTF-8 character.
                    if let chars = consumeUTF8Byte(b) {
                        out.append(contentsOf: chars.map { Key.char($0) })
                    }
                }

            case .afterEsc:
                if b == 0x5B { // '['
                    state = .afterEscBracket
                } else if b == 0x4F { // 'O'
                    state = .afterEscO
                } else if b >= 0x20 && b <= 0x7E {
                    // ESC + printable => alt(char)
                    out.append(.alt(Character(UnicodeScalar(b))))
                    state = .normal
                } else {
                    // Not a recognized escape continuation; treat prior ESC as
                    // standalone .escape and reprocess this byte in .normal.
                    out.append(.escape)
                    state = .normal
                    i -= 1 // reprocess current byte in normal state
                }

            case .afterEscO:
                switch b {
                case 0x41: out.append(.up); state = .normal
                case 0x42: out.append(.down); state = .normal
                case 0x43: out.append(.right); state = .normal
                case 0x44: out.append(.left); state = .normal
                default:
                    // Unknown SS3 sequence; emit as unknown and reset.
                    out.append(.unknown([0x1B, 0x4F, b]))
                    state = .normal
                }

            case .afterEscBracket:
                switch b {
                case 0x41: out.append(.up); state = .normal
                case 0x42: out.append(.down); state = .normal
                case 0x43: out.append(.right); state = .normal
                case 0x44: out.append(.left); state = .normal
                case 0x48: out.append(.home); state = .normal
                case 0x46: out.append(.end); state = .normal
                default:
                    if b >= 0x30 && b <= 0x39 { // digit: start collecting params
                        state = .csiParams([b])
                    } else if b >= 0x40 && b <= 0x7E {
                        // Final byte with no params collected: unknown CSI.
                        out.append(.unknown([0x1B, 0x5B, b]))
                        state = .normal
                    } else {
                        // Intermediate byte (e.g. '?'); keep collecting as params.
                        state = .csiParams([b])
                    }
                }

            case .csiParams(let collected):
                if b >= 0x40 && b <= 0x7E {
                    // Final byte reached.
                    let params = collected
                    if b == 0x7E {
                        switch paramsString(params) {
                        case "5":
                            out.append(.pageUp)
                            state = .normal
                        case "6":
                            out.append(.pageDown)
                            state = .normal
                        case "1":
                            out.append(.home)
                            state = .normal
                        case "4":
                            out.append(.end)
                            state = .normal
                        case "200":
                            state = .pasteBody([])
                            i += 1
                            continue
                        default:
                            out.append(.unknown([0x1B, 0x5B] + params + [b]))
                            state = .normal
                        }
                    } else {
                        out.append(.unknown([0x1B, 0x5B] + params + [b]))
                        state = .normal
                    }
                } else {
                    var next = collected
                    next.append(b)
                    state = .csiParams(next)
                }

            case .pasteBody(let collected):
                // Look for ESC [ 2 0 1 ~ terminator.
                let terminator: [UInt8] = [0x1B, 0x5B, 0x32, 0x30, 0x31, 0x7E]
                var buf = collected
                buf.append(b)
                if buf.count >= terminator.count && Array(buf.suffix(terminator.count)) == terminator {
                    let payload = Array(buf.prefix(buf.count - terminator.count))
                    let text = String(decoding: payload, as: UTF8.self)
                    out.append(.paste(text))
                    state = .normal
                } else {
                    state = .pasteBody(buf)
                }
            }
            i += 1
        }
        return out
    }

    /// Called by the I/O loop when no bytes arrived within ~30 ms while an
    /// ESC is pending: a lone ESC resolves to `.escape`.
    public mutating func flushTimeout() -> [Key] {
        if case .afterEsc = state {
            state = .normal
            return [.escape]
        }
        return []
    }

    // MARK: - Control bytes

    private func mapControlByte(_ b: UInt8) -> Key? {
        switch b {
        case 0x0d, 0x0a: return .enter
        case 0x7f, 0x08: return .backspace
        case 0x09: return .tab
        case 0x01...0x1a:
            // ctrl-letter, except tab(0x09)/lf(0x0a)/cr(0x0d) which are handled above.
            let letterScalar = UnicodeScalar(b - 0x01 + 0x61) // 0x01 -> 'a'
            return .ctrl(Character(letterScalar))
        default:
            return nil
        }
    }

    // MARK: - UTF-8 assembly

    private var utf8ExpectedLength: Int {
        guard let first = utf8Buffer.first else { return 0 }
        if first & 0x80 == 0 { return 1 }
        if first & 0xE0 == 0xC0 { return 2 }
        if first & 0xF0 == 0xE0 { return 3 }
        if first & 0xF8 == 0xF0 { return 4 }
        return 1
    }

    /// Feeds one byte into the UTF-8 assembly buffer. Returns the assembled
    /// Character(s) once a complete scalar is available, or nil if more
    /// continuation bytes are still needed.
    private mutating func consumeUTF8Byte(_ b: UInt8) -> [Character]? {
        utf8Buffer.append(b)
        let expected = utf8ExpectedLength
        if utf8Buffer.count >= expected {
            let s = String(decoding: utf8Buffer, as: UTF8.self)
            utf8Buffer.removeAll()
            return Array(s)
        }
        return nil
    }

    private func paramsString(_ params: [UInt8]) -> String {
        String(decoding: params, as: UTF8.self)
    }
}
