import Foundation
import ImperumCore

// MARK: - Wire format
//
// Newline-delimited JSON, UTF-8, one JSON object per line, no trailing
// newline inside an encoded line (the framer/writer owns line separators).
//
// Request:  {"v":1,"op":"<op>", ...fields}
//   hello:  {"v":1,"op":"hello","session":"…"?,"pid":123?}
//           (`pid`: the picker's own getpid(), sent by `--pick` pickers so
//           the app can end one whose host window closed without it; older
//           pickers omit it.)
//   list:   {"v":1,"op":"list"}
//   get/paste/copy/pin/delete: {"v":1,"op":"<op>","id":"<uuid>"}
//
// Response: {"ok":true, ...} | {"ok":false,"error":"<code>","message":"…"}
//   ok:     {"ok":true}
//   clips:  {"ok":true,"clips":[<ClipSummary>...]}
//   content:{"ok":true,"content":<ClipContent>}
//
// ClipContent: {"type":"text","text":"…"} | {"type":"files","files":["…"]}
//            | {"type":"image","width":123,"height":456}
//
// Dates encode as ISO 8601 with fractional seconds.

/// A lightweight, transport-friendly stand-in for `Clip` sent over the wire.
public struct ClipSummary: Codable, Equatable, Identifiable {
    public static let defaultPreviewLimit = 2048

    public let id: UUID
    public let kind: ClipKind
    public let title: String
    public let sourceAppName: String
    public let capturedAt: Date
    public let isPinned: Bool
    /// text-family: payload text cut to at most `previewLimit` UTF-8 bytes at a
    /// grapheme boundary. files/video: file names joined by "\n". image: "".
    public let preview: String
    /// file/video clips: the file names (last path component only).
    public let fileNames: [String]?
    /// image clips: pixel dimensions.
    public let image: ImageInfo?

    public struct ImageInfo: Codable, Equatable {
        public let width: Int
        public let height: Int

        public init(width: Int, height: Int) {
            self.width = width
            self.height = height
        }
    }

    public init(clip: Clip, previewLimit: Int = ClipSummary.defaultPreviewLimit) {
        id = clip.id
        kind = clip.kind
        title = clip.title
        sourceAppName = clip.sourceAppName
        capturedAt = clip.capturedAt
        isPinned = clip.isPinned

        switch clip.kind {
        case .text, .link, .email, .color:
            if case .text(let text) = clip.payload {
                preview = ClipSummary.truncated(text, toUTF8ByteLimit: previewLimit)
            } else {
                preview = ""
            }
            fileNames = nil
            image = nil
        case .file, .video:
            if case .fileURLs(let urls) = clip.payload {
                let names = urls.map { $0.lastPathComponent }
                fileNames = names
                preview = names.joined(separator: "\n")
            } else {
                fileNames = nil
                preview = ""
            }
            image = nil
        case .image:
            preview = ""
            fileNames = nil
            if case .blob(_, _, let width, let height) = clip.payload {
                image = ImageInfo(width: width, height: height)
            } else {
                image = nil
            }
        }
    }

    /// Rebuild a `Clip` so `PanelState`/`ClipFilter`/`ClipGrouper` work unchanged.
    public func asClip() -> Clip {
        let payload: ClipPayload
        switch kind {
        case .text, .link, .email, .color:
            payload = .text(preview)
        case .file, .video:
            payload = .fileURLs((fileNames ?? []).map { URL(fileURLWithPath: "/" + $0) })
        case .image:
            payload = .blob(id: id, utType: "public.png", width: image?.width ?? 0, height: image?.height ?? 0)
        }
        return Clip(
            id: id, kind: kind, capturedAt: capturedAt,
            sourceAppName: sourceAppName, sourceBundleID: nil, isPinned: isPinned,
            title: title, payload: payload, richText: nil
        )
    }

    /// Removes whole grapheme clusters from the end until the UTF-8 encoding
    /// fits within `limit` bytes, so the cut never lands mid-character.
    private static func truncated(_ text: String, toUTF8ByteLimit limit: Int) -> String {
        guard text.utf8.count > limit else { return text }
        var result = text
        while result.utf8.count > limit {
            result.removeLast()
        }
        return result
    }
}

public enum Request: Codable, Equatable {
    case hello(session: String?, pid: Int32? = nil)
    case list
    case get(id: UUID)
    case paste(id: UUID)
    case copy(id: UUID)
    case pin(id: UUID)
    case delete(id: UUID)

    private enum CodingKeys: String, CodingKey {
        case v, op, id, session, pid
    }

    private enum Op: String {
        case hello, list, get, paste, copy, pin, delete
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let opString = try container.decode(String.self, forKey: .op)
        guard let op = Op(rawValue: opString) else {
            throw DecodingError.dataCorruptedError(
                forKey: .op, in: container, debugDescription: "unknown op '\(opString)'"
            )
        }
        switch op {
        case .hello:
            self = .hello(session: try container.decodeIfPresent(String.self, forKey: .session),
                          pid: try container.decodeIfPresent(Int32.self, forKey: .pid))
        case .list:
            self = .list
        case .get:
            self = .get(id: try container.decode(UUID.self, forKey: .id))
        case .paste:
            self = .paste(id: try container.decode(UUID.self, forKey: .id))
        case .copy:
            self = .copy(id: try container.decode(UUID.self, forKey: .id))
        case .pin:
            self = .pin(id: try container.decode(UUID.self, forKey: .id))
        case .delete:
            self = .delete(id: try container.decode(UUID.self, forKey: .id))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(CopyStackKit.protocolVersion, forKey: .v)
        switch self {
        case .hello(let session, let pid):
            try container.encode(Op.hello.rawValue, forKey: .op)
            try container.encodeIfPresent(session, forKey: .session)
            try container.encodeIfPresent(pid, forKey: .pid)
        case .list:
            try container.encode(Op.list.rawValue, forKey: .op)
        case .get(let id):
            try container.encode(Op.get.rawValue, forKey: .op)
            try container.encode(id, forKey: .id)
        case .paste(let id):
            try container.encode(Op.paste.rawValue, forKey: .op)
            try container.encode(id, forKey: .id)
        case .copy(let id):
            try container.encode(Op.copy.rawValue, forKey: .op)
            try container.encode(id, forKey: .id)
        case .pin(let id):
            try container.encode(Op.pin.rawValue, forKey: .op)
            try container.encode(id, forKey: .id)
        case .delete(let id):
            try container.encode(Op.delete.rawValue, forKey: .op)
            try container.encode(id, forKey: .id)
        }
    }
}

public enum ClipContent: Codable, Equatable {
    case text(String)
    case files([String])
    case image(width: Int, height: Int)

    private enum CodingKeys: String, CodingKey {
        case type, text, files, width, height
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(String.self, forKey: .type)
        switch type {
        case "text":
            self = .text(try container.decode(String.self, forKey: .text))
        case "files":
            self = .files(try container.decode([String].self, forKey: .files))
        case "image":
            let width = try container.decode(Int.self, forKey: .width)
            let height = try container.decode(Int.self, forKey: .height)
            self = .image(width: width, height: height)
        default:
            throw DecodingError.dataCorruptedError(
                forKey: .type, in: container, debugDescription: "unknown content type '\(type)'"
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .text(let text):
            try container.encode("text", forKey: .type)
            try container.encode(text, forKey: .text)
        case .files(let files):
            try container.encode("files", forKey: .type)
            try container.encode(files, forKey: .files)
        case .image(let width, let height):
            try container.encode("image", forKey: .type)
            try container.encode(width, forKey: .width)
            try container.encode(height, forKey: .height)
        }
    }
}

public enum Response: Codable, Equatable {
    case ok
    case clips([ClipSummary])
    case content(ClipContent)
    case error(code: ErrorCode, message: String)

    public enum ErrorCode: String, Codable, Error {
        case disabled, notFound, imageMissing, badRequest, version
    }

    private enum CodingKeys: String, CodingKey {
        case ok, clips, content, error, message
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let ok = try container.decode(Bool.self, forKey: .ok)
        if ok {
            if let clips = try container.decodeIfPresent([ClipSummary].self, forKey: .clips) {
                self = .clips(clips)
            } else if let content = try container.decodeIfPresent(ClipContent.self, forKey: .content) {
                self = .content(content)
            } else {
                self = .ok
            }
        } else {
            let code = try container.decode(ErrorCode.self, forKey: .error)
            let message = try container.decode(String.self, forKey: .message)
            self = .error(code: code, message: message)
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .ok:
            try container.encode(true, forKey: .ok)
        case .clips(let clips):
            try container.encode(true, forKey: .ok)
            try container.encode(clips, forKey: .clips)
        case .content(let content):
            try container.encode(true, forKey: .ok)
            try container.encode(content, forKey: .content)
        case .error(let code, let message):
            try container.encode(false, forKey: .ok)
            try container.encode(code, forKey: .error)
            try container.encode(message, forKey: .message)
        }
    }
}

/// Encodes/decodes wire messages, and dates as ISO 8601 with fractional seconds.
public enum ProtocolCodec {
    private static let dateFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(dateFormatter.string(from: date))
        }
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let string = try container.decode(String.self)
            guard let date = dateFormatter.date(from: string) else {
                throw DecodingError.dataCorruptedError(
                    in: container, debugDescription: "invalid ISO 8601 date '\(string)'"
                )
            }
            return date
        }
        return decoder
    }()

    public static func encode(_ r: Request) throws -> Data {
        try encoder.encode(r)
    }

    /// `.version` when `v` is missing or not the current protocol version;
    /// `.badRequest` when the line isn't a well-formed request otherwise.
    public static func decodeRequest(_ line: Data) -> Result<Request, Response.ErrorCode> {
        guard
            let object = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any],
            let version = object["v"] as? Int
        else {
            return .failure(.badRequest)
        }
        guard version == CopyStackKit.protocolVersion else {
            return .failure(.version)
        }
        do {
            return .success(try decoder.decode(Request.self, from: line))
        } catch {
            return .failure(.badRequest)
        }
    }

    public static func encode(_ r: Response) throws -> Data {
        try encoder.encode(r)
    }

    public static func decodeResponse(_ line: Data) throws -> Response {
        try decoder.decode(Response.self, from: line)
    }
}

/// Splits a byte stream into complete newline-delimited lines, keeping a
/// partial tail buffered between `feed` calls.
public struct LineFramer {
    private var buffer = Data()
    private let maxLineLength: Int
    public private(set) var overflowed = false

    public init(maxLineLength: Int = 65_536) {
        self.maxLineLength = maxLineLength
    }

    /// Returns any complete lines (without their trailing "\n") found once
    /// `bytes` is appended to the buffered tail. If a line — complete or
    /// still-buffered — exceeds `maxLineLength`, sets `overflowed` and
    /// stops returning lines (any lines found before the oversized one are
    /// still returned; the caller is expected to close the connection).
    /// Once `overflowed` is set, subsequent calls always return `[]`.
    public mutating func feed(_ bytes: Data) -> [Data] {
        guard !overflowed else { return [] }
        buffer.append(bytes)
        var lines: [Data] = []
        while let newlineIndex = buffer.firstIndex(of: 0x0A) {
            let line = Data(buffer[buffer.startIndex..<newlineIndex])
            buffer.removeSubrange(buffer.startIndex...newlineIndex)
            if line.count > maxLineLength {
                overflowed = true
                return lines
            }
            lines.append(line)
        }
        if buffer.count > maxLineLength {
            overflowed = true
        }
        return lines
    }
}
