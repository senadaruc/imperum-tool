import Combine
import DiskArbitration
import Foundation
import ImperumCore

/// Dissents automatic OS mounts for volumes present in a `VolumeBlockStore`,
/// via a DiskArbitration mount-approval callback. Started once at app
/// launch and lives for the whole run, independent of Settings window
/// visibility — a docking station can connect anytime.
///
/// Unlike MountMate's equivalent `DiskMounter`, there is no "approve this one
/// manual mount" grace window: Imperum Tool has no mount button to whitelist
/// against, so to mount a blocked volume the user unblocks it first (in
/// Settings), then mounts it normally (Finder / Disk Utility / reconnect).
final class VolumeAutoMountBlocker {
    private var session: DASession?
    private var blockedIDs: Set<String> = []
    private var cancellable: AnyCancellable?

    init(store: VolumeBlockStore) {
        blockedIDs = Set(store.blocked.map(\.compositeID))
        cancellable = store.$blocked
            .receive(on: DispatchQueue.main)
            .sink { [weak self] blocked in
                self?.blockedIDs = Set(blocked.map(\.compositeID))
            }
        startSession()
    }

    deinit {
        stopSession()
    }

    private func startSession() {
        guard session == nil else { return }
        guard let session = DASessionCreate(kCFAllocatorDefault) else {
            NSLog("Imperum Tool: failed to create DiskArbitration session — auto-mount blocking is inactive until the app restarts.")
            return
        }
        self.session = session

        let callback: DADiskMountApprovalCallback = { (disk, context) -> Unmanaged<DADissenter>? in
            guard let context else { return nil }
            let this = Unmanaged<VolumeAutoMountBlocker>.fromOpaque(context).takeUnretainedValue()

            guard let desc = DADiskCopyDescription(disk) as? [String: Any] else { return nil }

            // Disk images (mounted .dmg files) are never blocked — you mount
            // those by explicitly opening them, so there's no "auto-mount on
            // connect" annoyance to prevent here.
            if let model = desc[kDADiskDescriptionDeviceModelKey as String] as? String, model == "Disk Image" {
                return nil
            }

            let volumeUUID: String
            if let rawVolumeUUID = desc[kDADiskDescriptionVolumeUUIDKey as String] as CFTypeRef?,
               CFGetTypeID(rawVolumeUUID) == CFUUIDGetTypeID() {
                volumeUUID = CFUUIDCreateString(nil, (rawVolumeUUID as! CFUUID)) as String
            } else if let deviceIdentifier = DADiskGetBSDName(disk).map({ String(cString: $0) }) {
                // Some volumes (e.g. EFI partitions) have no genuine
                // VolumeUUID; ExternalVolume falls back to the device
                // identifier for these, so this callback must match that
                // same fallback or blocking such a volume would silently
                // never take effect.
                volumeUUID = deviceIdentifier
            } else {
                return nil
            }

            let diskUUID: String
            if let rawDiskUUID = desc[kDADiskDescriptionMediaUUIDKey as String] as CFTypeRef?,
               CFGetTypeID(rawDiskUUID) == CFUUIDGetTypeID() {
                diskUUID = CFUUIDCreateString(nil, (rawDiskUUID as! CFUUID)) as String
            } else {
                diskUUID = "NONE"
            }

            let compositeID = "\(diskUUID)-\(volumeUUID)"
            guard this.blockedIDs.contains(compositeID) else {
                // Only log misses when the block list is non-empty — this
                // callback fires for essentially every volume mount
                // system-wide (including disk images and Time Machine
                // snapshots), and most users have nothing blocked. This is
                // the diagnostic trail for compositeID drift: if a blocked
                // volume ever auto-mounts anyway, Console.app will show the
                // computed ID that failed to match.
                if !this.blockedIDs.isEmpty {
                    NSLog("Imperum Tool: mount approved for \(compositeID) — not in the \(this.blockedIDs.count)-entry block list")
                }
                return nil
            }

            NSLog("Imperum Tool: dissenting auto-mount for blocked volume \(compositeID)")
            let dissenter = DADissenterCreate(kCFAllocatorDefault, DAReturn(kDAReturnNotPermitted), nil)
            return Unmanaged.passRetained(dissenter)
        }

        let matching: [String: Any] = [kDADiskDescriptionVolumeMountableKey as String: kCFBooleanTrue!]
        let context = Unmanaged.passUnretained(self).toOpaque()
        DARegisterDiskMountApprovalCallback(session, matching as CFDictionary, callback, context)
        DASessionSetDispatchQueue(session, DispatchQueue.main)
    }

    private func stopSession() {
        guard let session else { return }
        DASessionSetDispatchQueue(session, nil)
        self.session = nil
    }
}
