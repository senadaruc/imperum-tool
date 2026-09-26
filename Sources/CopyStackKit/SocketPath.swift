import Foundation

/// Resolves the copystack unix-domain socket path.
public enum SocketPath {
    public static let envOverride = "IMPERUM_COPYSTACK_SOCK"
    /// `sun_path` is 104 bytes including the NUL terminator, so the path itself
    /// (excluding the NUL) must be at most 103 bytes.
    public static let maxLength = 103

    /// `$IMPERUM_COPYSTACK_SOCK` if set; else `home/Library/Application Support/Imperum Tool/copystack.sock`;
    /// if that would exceed `maxLength`, falls back to `tmp/io.imperum.tool.copystack.sock`.
    public static func resolve(
        home: String,
        tmp: String,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> String {
        if let override = environment[envOverride], !override.isEmpty {
            return override
        }
        let defaultPath = home + "/Library/Application Support/Imperum Tool/copystack.sock"
        if defaultPath.utf8.count <= maxLength {
            return defaultPath
        }
        return tmp + "/io.imperum.tool.copystack.sock"
    }
}
