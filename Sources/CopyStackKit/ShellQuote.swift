import Foundation

/// POSIX single-quote shell quoting.
public enum ShellQuote {
    /// Wraps `s` in single quotes, escaping any embedded single quote as `'\''`.
    /// Always quotes, even when the input contains no special characters.
    public static func single(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
