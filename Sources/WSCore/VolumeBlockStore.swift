import Combine
import Foundation

public struct BlockedVolume: Codable, Identifiable, Equatable {
    public let compositeID: String
    public let name: String
    public var id: String { compositeID }

    public init(compositeID: String, name: String) {
        self.compositeID = compositeID
        self.name = name
    }
}

/// Persists which external volumes are blocked from auto-mounting. Backed by
/// `UserDefaults`, injected so tests can use an isolated suite instead of the
/// app's real preferences.
public final class VolumeBlockStore: ObservableObject {
    @Published public private(set) var blocked: [BlockedVolume]

    private let defaults: UserDefaults
    private static let key = "wsmonitor_blockedVolumes_v1"

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: Self.key),
           let decoded = try? JSONDecoder().decode([BlockedVolume].self, from: data) {
            self.blocked = decoded
        } else {
            self.blocked = []
        }
    }

    public func isBlocked(_ compositeID: String) -> Bool {
        blocked.contains { $0.compositeID == compositeID }
    }

    public func block(_ volume: ExternalVolume) {
        guard !isBlocked(volume.compositeID) else { return }
        blocked.append(BlockedVolume(compositeID: volume.compositeID, name: volume.name))
        save()
    }

    public func unblock(_ compositeID: String) {
        blocked.removeAll { $0.compositeID == compositeID }
        save()
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(blocked) else { return }
        defaults.set(data, forKey: Self.key)
    }
}
