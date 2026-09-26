import CopyStackKit
import Darwin
import Foundation

/// Result of one `TTYSession.poll` call.
enum PollResult {
    case bytes([UInt8])
    case resize
    case timeout
    case eof
    /// The optional watched fd (the app socket) became readable while the
    /// loop was idle; the caller decides what that means.
    case watchedReadable
}

/// Owns a controlling-terminal (`/dev/tty`) session for the interactive
/// picker: raw mode, the alternate screen, window-size queries, and signal
/// handling. Never touches stdout, so the process can still be piped
/// (`copystack | cat`) while drawing the UI on the tty.
final class TTYSession {
    private let fd: Int32
    private var savedTermios = termios()
    /// Self-pipe: SIGWINCH's handler (async-signal-safe) writes one byte here;
    /// `poll` includes the read end in its `poll(2)` set so a resize wakes it
    /// promptly without racing a `read` on the tty itself.
    private static var resizePipe: (read: Int32, write: Int32) = (-1, -1)

    /// Guards `restore()`'s body so it only runs once, including when called
    /// from a signal handler racing the normal exit path. `sig_atomic_t` is
    /// the only type POSIX guarantees is safe to read/write from a signal
    /// handler without a lock.
    private static var restored: sig_atomic_t = 0
    private static var restoreTermios = termios()
    private static var restoreFD: Int32 = -1

    /// The exact bytes `restore()` writes, as a compile-time literal: no
    /// heap allocation at call time (see `restore()`), so it's safe to run
    /// from a signal handler that may have interrupted the main thread while
    /// it held malloc's internal lock. Leads with `\e[23;0t` (XTWINOPS "pop
    /// window title from stack"), undoing the `\e[22;0t` push `setTitle`
    /// does before setting the title via OSC 2 — so a host terminal that
    /// understands the title stack has its original title back, not just
    /// whatever OSC 2 string this process happened to set last.
    private static let restoreSequence: StaticString = "\u{1b}[23;0t\u{1b}[?2004l\u{1b}[?25h\u{1b}[?1049l"

    /// Thrown by `init()` when `/dev/tty` cannot be opened (no controlling
    /// terminal, e.g. running under a non-interactive harness).
    struct NoTerminalError: Error {}

    init() throws {
        let opened = open("/dev/tty", O_RDWR)
        guard opened >= 0 else {
            throw NoTerminalError()
        }
        fd = opened

        var pipeFDs: [Int32] = [0, 0]
        if TTYSession.resizePipe.read < 0 {
            pipeFDs.withUnsafeMutableBufferPointer { buf in
                _ = pipe(buf.baseAddress)
            }
            // Non-blocking write end: the SIGWINCH handler must never block.
            let flags = fcntl(pipeFDs[1], F_GETFL, 0)
            _ = fcntl(pipeFDs[1], F_SETFL, flags | O_NONBLOCK)
            TTYSession.resizePipe = (pipeFDs[0], pipeFDs[1])
        }

        installSignalHandlers()
        atexit { TTYSession.restore() }
    }

    // MARK: - Raw mode / alternate screen

    func enterRawMode() {
        var raw = termios()
        tcgetattr(fd, &raw)
        savedTermios = raw
        // Set restoreTermios before restoreFD: a signal that lands between
        // the two assignments must never see a valid restoreFD paired with
        // stale/zeroed restoreTermios (which would restore the wrong tty
        // settings), so restoreFD — the field restore() gates on — is
        // published last.
        TTYSession.restoreTermios = raw
        TTYSession.restoreFD = fd

        raw.c_lflag &= ~UInt(ICANON | ECHO | ISIG | IEXTEN)
        raw.c_iflag &= ~UInt(IXON | ICRNL)
        raw.c_oflag &= ~UInt(OPOST)
        withUnsafeMutableBytes(of: &raw.c_cc) { ptr in
            ptr[Int(VMIN)] = 1
            ptr[Int(VTIME)] = 0
        }
        tcsetattr(fd, TCSANOW, &raw)

        write("\u{1b}[?1049h") // alternate screen
        write("\u{1b}[?25l")   // hide cursor
        write("\u{1b}[?2004h") // bracketed paste on
    }

    func setTitle(_ title: String) {
        // Push the terminal's current title onto its title stack (XTWINOPS
        // `\e[22;0t`) before overwriting it via OSC 2, so `restore()`'s
        // `\e[23;0t` pop can hand the original title back rather than leave
        // this process's title behind after it exits.
        write("\u{1b}[22;0t")
        write("\u{1b}]2;\(title)\u{07}")
    }

    /// Restores the terminal to its pre-raw-mode state: idempotent, and safe
    /// to call from a signal handler (its body only touches already-captured
    /// fd/termios values and makes async-signal-safe syscalls).
    func restore() {
        TTYSession.restore()
    }

    /// Idempotent; safe to call from a signal handler. A signal handler
    /// always preempts and runs to completion on the same thread it
    /// interrupted, so a plain test-and-set on `restored` (rather than a
    /// real atomic/lock) is enough to make a concurrent second call from the
    /// normal exit path and a signal handler mutually exclusive.
    fileprivate static func restore() {
        guard restored == 0 else { return }
        restored = 1
        guard restoreFD >= 0 else { return }
        restoreSequence.withUTF8Buffer { buf in
            _ = Darwin.write(restoreFD, buf.baseAddress, buf.count)
        }
        var t = restoreTermios
        tcsetattr(restoreFD, TCSANOW, &t)
    }

    // MARK: - Size

    var size: TerminalSize {
        var ws = winsize()
        if ioctl(fd, UInt(TIOCGWINSZ), &ws) == 0, ws.ws_col > 0, ws.ws_row > 0 {
            return TerminalSize(cols: Int(ws.ws_col), rows: Int(ws.ws_row))
        }
        return TerminalSize(cols: 80, rows: 24)
    }

    // MARK: - I/O

    func write(_ s: String) {
        let bytes = Array(s.utf8)
        bytes.withUnsafeBufferPointer { buf in
            var offset = 0
            while offset < buf.count {
                let n = Darwin.write(fd, buf.baseAddress! + offset, buf.count - offset)
                if n <= 0 { break }
                offset += n
            }
        }
    }

    /// Waits up to `timeoutMs` for input, a resize, or EOF on the tty.
    ///
    /// Uses `select(2)` rather than `poll(2)`: verified independently (a
    /// minimal standalone repro, outside this class entirely) that on this
    /// macOS build `poll()` spuriously reports `POLLNVAL` on the very first
    /// call for a `/dev/tty` fd obtained via `open()`, even though the fd is
    /// perfectly valid — `fcntl()` on it succeeds, and `select()` on the
    /// exact same fd blocks and times out correctly. Since `poll()` returns
    /// immediately instead of honoring `timeoutMs`, using it here would spin
    /// the caller's event loop at 100% CPU forever instead of ever waiting.
    ///
    /// `watchFD`, when given (the picker's app socket), is added to the same
    /// `select()` set; it being readable is reported as `.watchedReadable`
    /// (checked after resize, before tty input) without reading from it.
    func poll(timeoutMs: Int32, watchFD: Int32? = nil) -> PollResult {
        let resizeReadFD = TTYSession.resizePipe.read
        let maxFD = max(fd, resizeReadFD, watchFD ?? -1)

        var n: Int32
        var readSet = fd_set()
        while true {
            readSet = fd_set()
            withUnsafeMutablePointer(to: &readSet) { fdSetPointer in
                __darwin_fd_set(fd, fdSetPointer)
                __darwin_fd_set(resizeReadFD, fdSetPointer)
                if let watchFD { __darwin_fd_set(watchFD, fdSetPointer) }
            }
            var tv = timeval(tv_sec: Int(timeoutMs / 1000), tv_usec: Int32((timeoutMs % 1000) * 1000))
            n = select(maxFD + 1, &readSet, nil, nil, &tv)
            if n < 0 && errno == EINTR { continue }
            break
        }
        if n == 0 { return .timeout }
        // A real (non-EINTR) select() error means the fd set is no longer
        // usable (e.g. a closed/invalid fd) — treat it the same as EOF
        // rather than silently spinning at .timeout forever.
        guard n > 0 else { return .eof }

        if __darwin_fd_isset(resizeReadFD, &readSet) != 0 {
            var drain = [UInt8](repeating: 0, count: 64)
            _ = drain.withUnsafeMutableBytes { buf in
                Darwin.read(resizeReadFD, buf.baseAddress, buf.count)
            }
            return .resize
        }

        if let watchFD, __darwin_fd_isset(watchFD, &readSet) != 0 {
            return .watchedReadable
        }

        if __darwin_fd_isset(fd, &readSet) != 0 {
            var buffer = [UInt8](repeating: 0, count: 4096)
            let bytesRead = buffer.withUnsafeMutableBytes { buf in
                Darwin.read(fd, buf.baseAddress, buf.count)
            }
            if bytesRead <= 0 {
                return .eof
            }
            return .bytes(Array(buffer.prefix(bytesRead)))
        }
        return .timeout
    }

    // MARK: - Signals

    private func installSignalHandlers() {
        for sig in [SIGTERM, SIGHUP, SIGQUIT, SIGINT] {
            signal(sig, { signalNumber in
                TTYSession.restore()
                _exit(128 + signalNumber)
            })
        }
        signal(SIGTSTP, SIG_IGN)
        signal(SIGWINCH, { _ in
            // A local scalar (stack, not heap) so this allocates nothing,
            // matching `restore()`'s signal-safety requirement above.
            var byte: UInt8 = 0
            withUnsafeBytes(of: &byte) { buf in
                _ = Darwin.write(TTYSession.resizePipe.write, buf.baseAddress, 1)
            }
        })
    }
}
