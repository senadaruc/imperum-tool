import Foundation

/// Thin subprocess wrappers around `diskutil`, using `Process` with an
/// argument array (never an interpolated shell string). Kept separate from
/// `parseExternalVolumes` so the parsing logic stays pure and testable
/// without spawning a process — mirrors `CPUSampler`'s `runPS()` split.
enum DiskutilRunner {
    static func listPlist() -> Data? {
        run(arguments: ["list", "-plist"])
    }

    static func infoPlist(for identifier: String) -> Data? {
        run(arguments: ["info", "-plist", identifier])
    }

    private static func run(arguments: [String]) -> Data? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/sbin/diskutil")
        p.arguments = arguments
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = Pipe()
        do { try p.run() } catch { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return data.isEmpty ? nil : data
    }
}

/// Runs `diskutil list -plist` plus one `diskutil info -plist` per root disk
/// identifier found in the list, and returns the parsed external volumes.
/// Synchronous and shells out — call from a background queue.
public func fetchExternalVolumes() -> [ExternalVolume] {
    guard
        let listData = DiskutilRunner.listPlist(),
        let root = try? PropertyListSerialization.propertyList(from: listData, options: [], format: nil) as? [String: Any],
        let allDisksAndPartitions = root["AllDisksAndPartitions"] as? [[String: Any]]
    else { return [] }

    var infoPlists: [String: Data] = [:]
    for diskData in allDisksAndPartitions {
        guard let identifier = diskData["DeviceIdentifier"] as? String else { continue }
        if let data = DiskutilRunner.infoPlist(for: identifier) {
            infoPlists[identifier] = data
        }
    }

    return parseExternalVolumes(listPlist: listData, infoPlists: infoPlists)
}
