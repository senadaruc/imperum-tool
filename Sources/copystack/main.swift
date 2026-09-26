import CopyStackKit
import Foundation

// MARK: - Args

let parsedArgs = CLIArgs.parse(Array(CommandLine.arguments.dropFirst()))

func printUsage() {
    print("""
    copystack is the terminal picker for Imperum Tool's clipboard history. \
    It lets you browse, search, and re-paste items from your clipboard stack \
    without leaving the terminal.

    Usage:
      copystack                    Interactive picker; selecting a clip prints
                                    its text to stdout (files: one path per
                                    line; images can't be sent to stdout).
      copystack --paste            Interactive picker; selecting a clip pastes
                                    it into the frontmost app via Imperum Tool.
      copystack --copy             Interactive picker; selecting a clip copies
                                    it to the system clipboard.
      copystack --pick --session <hex>
                                    Interactive picker for a specific paste
                                    session (used internally by Imperum Tool).
      copystack list [--json] [--limit N]
                                    Print the clip list non-interactively, one
                                    line per clip ("<n>\\t<kind>\\t<title>",
                                    <n> a 1-based index), or as JSON with
                                    --json. No terminal needed.
      copystack --version           Print the version and exit.
      copystack --help | -h         Show this message and exit.

    In the picker: type to search, arrows/^N/Home/End/PageUp/PageDown to move,
    left/right to switch category, Enter/Alt+1-9 to select, ^P to pin, ^D to
    delete, Esc/^C to cancel.

    Exit codes: 0 success, 1 usage error, an image was selected in stdout
    mode, no controlling terminal, or input closed, 2 Imperum Tool is not
    running, command-line access is off, or the connection was lost at any
    point, 130 cancelled with Esc/^C.
    """)
}

func fail(_ message: String, exitCode: Int32) -> Never {
    FileHandle.standardError.write((message + "\n").data(using: .utf8)!)
    exit(exitCode)
}

let args: CLIArgs
switch parsedArgs {
case .success(let a):
    args = a
case .failure(let message):
    fail("copystack: \(message)", exitCode: 1)
}

switch args.mode {
case .version:
    print("copystack \(CopyStackKit.version)")
    exit(0)
case .help:
    printUsage()
    exit(0)
default:
    break
}

// MARK: - Connect

let socketPath = SocketPath.resolve(home: NSHomeDirectory(), tmp: NSTemporaryDirectory())
let notRunningMessage = "copystack: Imperum Tool is not running (or command-line access is off)"

let client: SocketClient
do {
    client = try SocketClient.connect(path: socketPath)
} catch {
    fail(notRunningMessage, exitCode: 2)
}

func sessionForHello() -> String? {
    if case .pick(let session) = args.mode { return session }
    return nil
}

do {
    let hello = try client.send(.hello(session: sessionForHello()))
    if case .error(.disabled, _) = hello {
        fail(notRunningMessage, exitCode: 2)
    }
} catch {
    fail(notRunningMessage, exitCode: 2)
}

// MARK: - list (no tty needed)

func printList(_ summaries: [ClipSummary], json: Bool, limit: Int?) {
    let limited = limit.map { Array(summaries.prefix($0)) } ?? summaries
    if json {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        if let data = try? encoder.encode(limited), let s = String(data: data, encoding: .utf8) {
            print(s)
        }
    } else {
        for (index, summary) in limited.enumerated() {
            // `summary.title` is untrusted clipboard content (whatever the
            // user copied) printed straight to a real terminal's stdout, so
            // it goes through the same escape-sequence defence as the
            // picker's own TUI rather than being trusted verbatim.
            print("\(index + 1)\t\(summary.kind.rawValue)\t\(Sanitize.line(summary.title))")
        }
    }
}

if case .list(let json, let limit) = args.mode {
    do {
        let response = try client.send(.list)
        switch response {
        case .clips(let summaries):
            printList(summaries, json: json, limit: limit)
            exit(0)
        case .error(let code, let message):
            fail("copystack: \(code.rawValue): \(message)", exitCode: 1)
        default:
            fail("copystack: unexpected response", exitCode: 1)
        }
    } catch {
        fail(notRunningMessage, exitCode: 2)
    }
}

// MARK: - Interactive modes

let pickerMode: PickerModel.Mode
switch args.mode {
case .stdout: pickerMode = .stdout
case .paste: pickerMode = .paste
case .copy: pickerMode = .copy
case .pick: pickerMode = .pick
default:
    fail("copystack: internal error: unhandled mode", exitCode: 1)
}

let tty: TTYSession
do {
    tty = try TTYSession()
} catch {
    fail("copystack: no terminal", exitCode: 1)
}

func exitInteractive(_ code: Int32) -> Never {
    tty.restore()
    client.close()
    exit(code)
}

let initialListResponse: Response
do {
    initialListResponse = try client.send(.list)
} catch {
    fail(notRunningMessage, exitCode: 2)
}

guard case .clips(let initialSummaries) = initialListResponse else {
    fail("copystack: unexpected response", exitCode: 1)
}

let calendar = Calendar.current
let noColor = ProcessInfo.processInfo.environment["NO_COLOR"] != nil

tty.enterRawMode()
switch args.mode {
case .pick(let session):
    tty.setTitle("Copy Stack · \(String(session.prefix(6)))")
default:
    tty.setTitle("Copy Stack")
}

var model = PickerModel(summaries: initialSummaries, mode: pickerMode, now: Date(), calendar: calendar)
var parser = KeyParser()
var currentSize = tty.size

func render() {
    let frame = FrameRenderer.render(model, size: currentSize, now: Date(), calendar: calendar, noColor: noColor)
    tty.write(frame)
}

render()

func handleEffect(_ effect: PickerModel.Effect) {
    switch effect {
    case .none:
        break
    case .redraw:
        render()
    case .pin(let id):
        handleListMutation(try client.send(.pin(id: id)))
    case .delete(let id):
        handleListMutation(try client.send(.delete(id: id)))
    case .paste(let id):
        handlePaste(id: id)
    case .copy(let id):
        handleCopy(id: id)
    case .cancel:
        exitInteractive(130)
    }
}

/// Common tail of `.pin`/`.delete`: on `.clips`, refresh the model's list; on
/// any other response (including `.error`), surface it in the footer rather
/// than silently dropping it; on a socket error the connection is gone, so
/// restore the tty and exit like every other lost-connection path.
func handleListMutation(_ mutation: @autoclosure () throws -> Response) {
    let response: Response
    do {
        response = try mutation()
    } catch {
        tty.restore()
        client.close()
        fail(notRunningMessage, exitCode: 2)
    }
    switch response {
    case .clips(let summaries):
        model.replace(summaries: summaries, listHeight: FrameRenderer.listHeight(for: currentSize), now: Date(), calendar: calendar)
    case .error(let code, let message):
        model.status = "\(code.rawValue): \(message)"
    default:
        model.status = "unexpected response"
    }
    render()
}

func handlePaste(id: UUID) {
    switch pickerMode {
    case .stdout:
        let response: Response
        do {
            response = try client.send(.get(id: id))
        } catch {
            tty.restore()
            client.close()
            fail(notRunningMessage, exitCode: 2)
        }
        switch response {
        case .content(.text(let text)):
            tty.restore()
            print(text, terminator: "")
            client.close()
            exit(0)
        case .content(.files(let files)):
            tty.restore()
            for f in files { print(f) }
            client.close()
            exit(0)
        case .content(.image):
            tty.restore()
            client.close()
            fail("copystack: image clips can only be pasted (use --paste)", exitCode: 1)
        case .error(let code, let message):
            model.status = "\(code.rawValue): \(message)"
            render()
        default:
            model.status = "unexpected response"
            render()
        }
    case .paste, .pick:
        let response: Response
        do {
            response = try client.send(.paste(id: id))
        } catch {
            tty.restore()
            client.close()
            fail(notRunningMessage, exitCode: 2)
        }
        switch response {
        case .ok:
            exitInteractive(0)
        case .error(let code, let message):
            model.status = "\(code.rawValue): \(message)"
            render()
        default:
            model.status = "unexpected response"
            render()
        }
    case .copy:
        break // .paste effect is never produced in .copy mode
    }
}

func handleCopy(id: UUID) {
    let response: Response
    do {
        response = try client.send(.copy(id: id))
    } catch {
        tty.restore()
        client.close()
        fail(notRunningMessage, exitCode: 2)
    }
    switch response {
    case .ok:
        exitInteractive(0)
    case .error(let code, let message):
        model.status = "\(code.rawValue): \(message)"
        render()
    default:
        model.status = "unexpected response"
        render()
    }
}

while true {
    let timeoutMs: Int32 = parser.hasPendingEscape ? 30 : 250
    switch tty.poll(timeoutMs: timeoutMs) {
    case .bytes(let bytes):
        let keys = parser.feed(bytes)
        for key in keys {
            let effect = model.reduce(key, listHeight: FrameRenderer.listHeight(for: currentSize), now: Date(), calendar: calendar)
            handleEffect(effect)
        }
    case .resize:
        currentSize = tty.size
        render()
    case .timeout:
        let keys = parser.flushTimeout()
        for key in keys {
            let effect = model.reduce(key, listHeight: FrameRenderer.listHeight(for: currentSize), now: Date(), calendar: calendar)
            handleEffect(effect)
        }
    case .eof:
        exitInteractive(1)
    }
}
