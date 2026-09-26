import Foundation

// `CLIArgs.parse` returns `Result<CLIArgs, String>` per spec (a plain usage
// message, not a typed error enum), which requires `String` to conform to
// `Error` to satisfy `Result`'s `Failure: Error` constraint. Tried scoping
// this down to `internal`: Swift rejects any access modifier at all on a
// conformance-declaring extension ("'internal' modifier cannot be used with
// extensions that declare protocol conformances"), so it stays implicitly
// public, matching the visibility `CLIArgs.parse` already requires of it.
extension String: @retroactive Error {}

/// What `copystack` was invoked to do, as decoded from `CommandLine.arguments`.
public enum CLIMode: Equatable {
    case pick(session: String)
    case paste
    case copy
    case stdout
    case list(json: Bool, limit: Int?)
    case version
    case help
}

/// Parsed `copystack` command-line invocation. Pure (no I/O), so it can be
/// unit-tested directly; `main.swift` owns turning a `CLIArgs` into behavior.
public struct CLIArgs: Equatable {
    public let mode: CLIMode

    public init(mode: CLIMode) {
        self.mode = mode
    }

    /// Grammar:
    ///   (no args)                     -> .stdout
    ///   --paste                       -> .paste
    ///   --copy                        -> .copy
    ///   --pick --session <hex>        -> .pick(session:) (both flags required together)
    ///   list [--json] [--limit N]     -> .list(json:limit:)
    ///   --version                     -> .version
    ///   --help | -h                   -> .help
    /// Any unrecognized flag, `--paste` together with `--copy`, a `--session`
    /// without `--pick` (or vice versa), a `--session` value that isn't
    /// 8-64 hex characters, or a `--limit` value that isn't a positive
    /// integer is a usage error.
    public static func parse(_ argv: [String]) -> Result<CLIArgs, String> {
        guard !argv.isEmpty else {
            return .success(CLIArgs(mode: .stdout))
        }

        if argv[0] == "list" {
            return parseList(Array(argv.dropFirst()))
        }

        var sawPaste = false
        var sawCopy = false
        var sawPick = false
        var sawVersion = false
        var sawHelp = false
        var session: String?

        var i = 0
        while i < argv.count {
            let arg = argv[i]
            switch arg {
            case "--paste":
                sawPaste = true
            case "--copy":
                sawCopy = true
            case "--pick":
                sawPick = true
            case "--session":
                i += 1
                guard i < argv.count else {
                    return .failure("--session requires a value")
                }
                session = argv[i]
            case "--version":
                sawVersion = true
            case "--help", "-h":
                sawHelp = true
            default:
                return .failure("unknown flag: \(arg)")
            }
            i += 1
        }

        if sawHelp {
            return .success(CLIArgs(mode: .help))
        }
        if sawVersion {
            return .success(CLIArgs(mode: .version))
        }
        if sawPaste && sawCopy {
            return .failure("--paste and --copy cannot be used together")
        }
        if sawPick || session != nil {
            guard sawPick, let session else {
                return .failure("--pick and --session must be used together")
            }
            guard CLIArgs.isValidSession(session) else {
                return .failure("--session must be 8-64 hexadecimal characters")
            }
            return .success(CLIArgs(mode: .pick(session: session)))
        }
        if sawPaste {
            return .success(CLIArgs(mode: .paste))
        }
        if sawCopy {
            return .success(CLIArgs(mode: .copy))
        }
        return .failure("unrecognized arguments")
    }

    /// `--session` must look like a session id, not arbitrary text, before
    /// it ever reaches an OSC 2 title-setting escape sequence.
    private static func isValidSession(_ s: String) -> Bool {
        (8...64).contains(s.count) && s.allSatisfy(\.isHexDigit)
    }

    private static func parseList(_ rest: [String]) -> Result<CLIArgs, String> {
        var json = false
        var limit: Int?

        var i = 0
        while i < rest.count {
            let arg = rest[i]
            switch arg {
            case "--json":
                json = true
            case "--limit":
                i += 1
                guard i < rest.count else {
                    return .failure("--limit requires a value")
                }
                guard let n = Int(rest[i]), n >= 1 else {
                    return .failure("--limit must be a positive integer")
                }
                limit = n
            default:
                return .failure("unknown flag: \(arg)")
            }
            i += 1
        }
        return .success(CLIArgs(mode: .list(json: json, limit: limit)))
    }
}
