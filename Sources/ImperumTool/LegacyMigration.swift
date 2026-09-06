import Foundation

/// One-time copy of settings saved under the pre-rename bundle identifier
/// (`io.imperum.wsmonitor`) into this app's defaults (`io.imperum.tool`).
/// Never overwrites a value that already exists in the new domain.
enum LegacyMigration {
    private static let legacyDomain = "io.imperum.wsmonitor"
    private static let marker = "imperumTool_migratedFromWSMonitor"
    /// old key → new key (unchanged keys map to themselves)
    private static let keys: [String: String] = [
        "intervalSeconds": "intervalSeconds",
        "cpuThreshold": "cpuThreshold",
        "gpuThreshold": "gpuThreshold",
        "wsmonitor_blockedVolumes_v1": "imperumTool_blockedVolumes_v1",
        "wsmonitor_tapGestures_v1": "imperumTool_tapGestures_v1",
        // Menu-bar item placement — without it the gauge lands at the far left
        // of a crowded menu bar and gets hidden behind the notch.
        "NSStatusItem Preferred Position Item-0": "NSStatusItem Preferred Position Item-0",
        "NSStatusItem Visible Item-0": "NSStatusItem Visible Item-0",
    ]

    static func run(defaults: UserDefaults = .standard) {
        guard !defaults.bool(forKey: marker) else { return }
        defer { defaults.set(true, forKey: marker) }
        guard let old = UserDefaults.standard.persistentDomain(forName: legacyDomain), !old.isEmpty else { return }
        var copied = 0
        for (oldKey, newKey) in keys {
            guard let v = old[oldKey], defaults.object(forKey: newKey) == nil else { continue }
            defaults.set(v, forKey: newKey); copied += 1
        }
        NSLog("Imperum Tool: migrated \(copied) setting(s) from \(legacyDomain)")
    }
}
