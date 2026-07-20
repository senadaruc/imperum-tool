import Combine
import DiskArbitration
import Foundation
import WSCore

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

            guard let rawVolumeUUID = desc[kDADiskDescriptionVolumeUUIDKey as String] as CFTypeRef?,
                  CFGetTypeID(rawVolumeUUID) == CFUUIDGetTypeID()
            else { return nil }
            let volumeUUID = CFUUIDCreateString(nil, (rawVolumeUUID as! CFUUID)) as String

            let diskUUID: String
            if let rawDiskUUID = desc[kDADiskDescriptionMediaUUIDKey as String] as CFTypeRef?,
               CFGetTypeID(rawDiskUUID) == CFUUIDGetTypeID() {
                diskUUID = CFUUIDCreateString(nil, (rawDiskUUID as! CFUUID)) as String
            } else {
                diskUUID = "NONE"
            }

            let compositeID = "\(diskUUID)-\(volumeUUID)"
            guard this.blockedIDs.contains(compositeID) else { return nil }

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
