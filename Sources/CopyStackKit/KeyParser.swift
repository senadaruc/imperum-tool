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
        case csiParams                // collecting CSI parameter/intermediate bytes after ESC [ (buffered in `csiBuffer`)
        case afterEscO                // saw ESC O (SS3)
        case pasteBody                // inside bracketed paste, collecting bytes until ESC[201~ (buffered in `pasteBuffer`)
    }

    /// Guards against unbounded growth (and the O(n²) blowup a growing
    /// associated-value array would cause) when a CSI sequence is never
    /// terminated. Exceeding this many collected parameter/intermediate
    /// bytes emits `.unknown` for what was collected and resets to `.normal`.
    private static let maxCSIParamBytes = 64

    /// Guards against unbounded memory growth when a bracketed paste is
    /// never terminated (e.g. a dropped ESC[201~). Exceeding this many
    /// collected bytes emits `.paste` with what was collected so far and
    /// resets to `.normal`; subsequent bytes are parsed as ordinary input.
    private static let maxPasteBytes = 1 * 1024 * 1024 // 1 MiB

    private var state: State = .normal
    // These buffers are stored properties (not enum associated values) so
    // that appending a byte mutates them in place (amortized O(1)) instead
    // of copy-on-write duplicating the whole buffer on every byte, which
    // previously made an unterminated CSI/paste run O(n²) in its length.
    private var csiBuffer: [UInt8] = []
    private var pasteBuffer: [UInt8] = []
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
                if b == 0x00 {
                    discardIncompleteUTF8IfAny()
                    out.append(.unknown([0]))
                } else if b == 0x1B {
                    discardIncompleteUTF8IfAny()
                    state = .afterEsc
                } else if let key = mapControlByte(b) {
                    discardIncompleteUTF8IfAny()
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
                        csiBuffer = [b]
                        state = .csiParams
                    } else if b >= 0x40 && b <= 0x7E {
                        // Final byte with no params collected: unknown CSI.
                        out.append(.unknown([0x1B, 0x5B, b]))
                        state = .normal
                    } else {
                        // Intermediate byte (e.g. '?'); keep collecting as params.
                        csiBuffer = [b]
                        state = .csiParams
                    }
                }

            case .csiParams:
                if b >= 0x40 && b <= 0x7E {
                    // Final byte reached.
                    let params = csiBuffer
                    csiBuffer.removeAll()
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
                            pasteBuffer.removeAll()
                            state = .pasteBody
                        default:
                            out.append(.unknown([0x1B, 0x5B] + params + [b]))
                            state = .normal
                        }
                    } else {
                        out.append(.unknown([0x1B, 0x5B] + params + [b]))
                        state = .normal
                    }
                } else {
                    csiBuffer.append(b)
                    if csiBuffer.count > Self.maxCSIParamBytes {
                        out.append(.unknown([0x1B, 0x5B] + csiBuffer))
                        csiBuffer.removeAll()
                        state = .normal
                    }
                }

            case .pasteBody:
                // Look for ESC [ 2 0 1 ~ terminator.
                let terminator: [UInt8] = [0x1B, 0x5B, 0x32, 0x30, 0x31, 0x7E]
                pasteBuffer.append(b)
                if pasteBuffer.count >= terminator.count && Array(pasteBuffer.suffix(terminator.count)) == terminator {
                    let payload = Array(pasteBuffer.prefix(pasteBuffer.count - terminator.count))
                    let text = String(decoding: payload, as: UTF8.self)
                    out.append(.paste(text))
                    pasteBuffer.removeAll()
                    state = .normal
                } else if pasteBuffer.count > Self.maxPasteBytes {
                    let text = String(decoding: pasteBuffer, as: UTF8.self)
                    out.append(.paste(text))
                    pasteBuffer.removeAll()
                    state = .normal
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
    ///
    /// If a byte arrives that is not a valid continuation byte (0x80–0xBF)
    /// while a multi-byte sequence is pending, the stale, incomplete bytes
    /// are discarded first so a later valid byte isn't mistaken for more of
    /// the abandoned sequence and swallowed.
    private mutating func consumeUTF8Byte(_ b: UInt8) -> [Character]? {
        if !utf8Buffer.isEmpty && (b & 0xC0) != 0x80 {
            utf8Buffer.removeAll()
        }
        utf8Buffer.append(b)
        let expected = utf8ExpectedLength
        if utf8Buffer.count >= expected {
            let s = String(decoding: utf8Buffer, as: UTF8.self)
            utf8Buffer.removeAll()
            return Array(s)
        }
        return nil
    }

    /// Discards a pending, incomplete UTF-8 sequence when it is interrupted
    /// by a byte that is handled outside `consumeUTF8Byte` entirely (a NUL,
    /// an ESC, or a mapped control byte). Without this, the abandoned bytes
    /// would remain buffered and corrupt the next character's decoding.
    private mutating func discardIncompleteUTF8IfAny() {
        if !utf8Buffer.isEmpty {
            utf8Buffer.removeAll()
        }
    }

    private func paramsString(_ params: [UInt8]) -> String {
        String(decoding: params, as: UTF8.self)
    }
}
