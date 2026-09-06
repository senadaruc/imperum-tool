import AppKit

public func frontAppName() -> String {
    NSWorkspace.shared.frontmostApplication?.localizedName ?? "Unknown"
}
