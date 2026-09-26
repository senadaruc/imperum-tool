// Sources/ImperumTool/ClipboardController.swift
import AppKit
import Combine
import ImperumCore

/// Owns the whole clipboard subsystem and reacts to settings live.
///
/// Main-thread invariant: every call into `ClipStore`, `ClipArchive`, `CmdVTap`,
/// the panel and the status item happens on the main thread, with one
/// exception: `scheduleSave()`'s debounced index write runs on `saveQueue`, a
/// private serial background queue, since `ClipArchive` has no shared
/// mutable state and is safe to call from any single queue at a time. The
/// poll `Timer` runs on the main run loop, the settings sink receives on
/// `DispatchQueue.main`, and `tap.onOpenPanel` is already dispatched to main
/// by the tap.
final class ClipboardController {
    private let settings: ClipboardSettingsStore
    private let store = ClipStore()
    private let keyProvider = KeychainArchiveKey()
    private var archive: ClipArchive?
    private let reader = NSPasteboardReader()
    private let tap = CmdVTap()
    /// Session-only image cache; makes paste and thumbnails work even when
    /// the archive never sees the blob (session-only mode) or is unavailable.
    private let blobCache = BlobCache()
    private lazy var paster = ClipPaster(blobLookup: { [weak self] id, suffix in self?.lookupBlob(id, suffix: suffix) })
    private lazy var model = CopyStackModel(
        store: store, settings: settings,
        blobLookup: { [weak self] id, suffix in self?.lookupBlob(id, suffix: suffix) },
        faviconCacheDir: { [weak self] in
            guard let self, !self.settings.settings.clearOnQuit else { return nil }
            return self.archive?.directory.appendingPathComponent("favicons")
        })
    private lazy var panel = CopyStackPanel(model: model)
    private lazy var statusItem = ClipboardStatusItem(store: store, settings: settings)
    private var pollTimer: Timer?
    private var saveWork: DispatchWorkItem?
    /// Encoding + sealing the index can take ~200ms once it grows large;
    /// running that on main would stall the event tap's run loop (every
    /// keystroke, system-wide) for the duration. Serial so saves can't race.
    private let saveQueue = DispatchQueue(label: "io.imperum.tool.clipboard.save", qos: .utility)
    private var lastChangeCount = NSPasteboard.general.changeCount
    private var bag = Set<AnyCancellable>()

    /// True when the archive could not be loaded for a reason other than
    /// corruption (e.g. a Keychain error or an unreadable file). While set,
    /// saves are skipped so the debounced save can never overwrite an intact
    /// on-disk archive with an empty in-memory index.
    private var archiveUnavailable = false

    /// Last settings values `apply(_:)` actually acted on, so repeated calls
    /// (the settings sink fires on every edit) don't restart the tap or wipe
    /// the archive redundantly.
    private var lastApplied: (enabled: Bool, trigger: ClipboardTrigger, clearOnQuit: Bool)?

    /// True when `tap.start` returned false because Accessibility isn't
    /// granted yet. Cleared, and the tap restarted, once the app becomes
    /// active again and trust has been granted.
    private var tapNeedsAccessibility = false

    static let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Imperum Tool/Clipboard", isDirectory: true)

    init(settings: ClipboardSettingsStore) {
        self.settings = settings
        archive = ClipArchive(directory: Self.directory, keyProvider: keyProvider)
        load()
        store.onChange = { [weak self] in self?.scheduleSave() }
        store.onBlobsDropped = { [weak self] ids in self?.archive?.deleteBlobs(ids); self?.blobCache.remove(ids) }
        model.onPaste = { [weak self] clip in self?.paste(clip) }
        model.onClose = { [weak self] in self?.panel.hide() }
        tap.onOpenPanel = { [weak self] in self?.showPanel(anchor: .mouseScreen) }
        statusItem.onShow = { [weak self] in self?.showPanel(anchor: .mainScreen) }
        statusItem.onClear = { [weak self] in self?.confirmClear() }
        statusItem.onSettings = { SettingsTabs.requestedTab = "clipboard"; NSApp.sendAction(#selector(AppController.showSettings), to: nil, from: nil) }
        statusItem.onGrantAccessibility = { ActionRunner.ensureAccessibility() }
        ActionRunner.showCopyStack = { [weak self] in self?.showPanel(anchor: .mainScreen) }
        settings.$settings.removeDuplicates().receive(on: DispatchQueue.main).sink { [weak self] s in self?.apply(s) }.store(in: &bag)
        NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            self?.retryTapIfTrusted()
        }
    }

    private func retryTapIfTrusted() {
        guard tapNeedsAccessibility, ActionRunner.isTrusted else { return }
        tapNeedsAccessibility = false
        statusItem.needsAccessibility = false
        lastApplied = nil   // force apply(_:) to restart the tap
        apply(settings.settings)
    }

    // MARK: Settings → behaviour

    private func apply(_ s: ClipboardSettings) {
        statusItem.setVisible(s.enabled && s.showBadge)
        tap.window = s.doubleTapWindow

        let triggerChanged = lastApplied.map { $0.enabled != s.enabled || $0.trigger != s.trigger } ?? true
        if triggerChanged {
            if s.enabled {
                let ok = tap.start(doubleTap: s.trigger.usesDoubleTap, hotkey: s.trigger.usesHotkey)
                tapNeedsAccessibility = !ok
                statusItem.needsAccessibility = !ok
            } else {
                tap.stop()
                tapNeedsAccessibility = false
                statusItem.needsAccessibility = false
            }
        }
        if s.enabled { startPolling() } else { stopPolling(); panel.hide() }

        let clearOnQuitTurnedOn = lastApplied.map { !$0.clearOnQuit && s.clearOnQuit } ?? false
        if clearOnQuitTurnedOn { try? archive?.deleteAll() }   // session-only from now on: nothing left on disk

        store.enforce(limits: s.limits)
        lastApplied = (s.enabled, s.trigger, s.clearOnQuit)
    }

    // MARK: Capture

    private func startPolling() {
        guard pollTimer == nil else { return }
        pollTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in self?.poll() }
    }
    private func stopPolling() { pollTimer?.invalidate(); pollTimer = nil }

    private func poll() {
        let count = reader.changeCount
        guard count != lastChangeCount else { return }
        lastChangeCount = count
        let front = NSWorkspace.shared.frontmostApplication
        let ctx = CaptureContext(frontBundleID: front?.bundleIdentifier, frontAppName: front?.localizedName ?? "Unknown",
                                 settings: settings.settings, ownChangeCount: paster.lastOwnChangeCount)
        guard let captured = ClipCapture.capture(from: reader, context: ctx) else { return }
        // The pasteboard may have changed again between the veto check above and
        // this content read (e.g. another app copied right behind us). Discard a
        // stale capture and let the next poll pick up the newer change.
        guard reader.changeCount == count else { return }
        if let data = captured.blobData, let id = captured.clip.blobID {
            let thumb = ImageThumbnail.png(from: data, maxEdge: 64)
            // Always cache in memory first: session-only mode (or an
            // unavailable archive) must not leave the paster/thumbnail code
            // with nothing to read.
            blobCache.set(data, thumb: thumb, for: id)
            if !settings.settings.clearOnQuit, !archiveUnavailable {
                try? archive?.saveBlob(data, id: id)
                if let thumb { try? archive?.saveBlob(thumb, id: id, suffix: "thumb.png") }
            }
        }
        store.insert(captured.clip, limits: settings.settings.limits)
    }

    /// Cache-first, then archive: the lookup the paster and panel use so
    /// image clips work even when nothing was ever written to disk.
    private func lookupBlob(_ id: UUID, suffix: String) -> Data? {
        if suffix == "thumb.png" { return blobCache.thumb(for: id) ?? archive?.loadBlob(id: id, suffix: suffix) }
        return blobCache[id] ?? archive?.loadBlob(id: id, suffix: suffix)
    }

    // MARK: Panel and paste

    func showPanel(anchor: CopyStackPanel.Anchor) {
        guard settings.settings.enabled else { return }
        if panel.isVisible { panel.hide(); return }
        panel.show(anchor: anchor)
    }

    private func paste(_ clip: Clip) {
        panel.hide()
        if paster.paste(clip) {
            // Our own change is skipped by the watcher's veto, so move the
            // clip to the top here: same id/pin/content, fresh capturedAt.
            let refreshed = Clip(id: clip.id, kind: clip.kind, capturedAt: Date(),
                                 sourceAppName: clip.sourceAppName, sourceBundleID: clip.sourceBundleID,
                                 isPinned: clip.isPinned, title: clip.title, payload: clip.payload)
            store.insert(refreshed, limits: settings.settings.limits)
        } else {
            store.delete(clip.id)
        }
    }

    // MARK: Persistence

    private func load() {
        guard !settings.settings.clearOnQuit else { return }
        do {
            store.replaceAll(try archive?.loadIndex() ?? [])
            archive?.sweepBlobs(keeping: Set(store.clips.compactMap(\.blobID)))
        } catch ClipArchiveError.corrupt {
            NSLog("Imperum Tool clipboard archive corrupt; starting empty and rotating the key")
            try? archive?.deleteAll()
            _ = try? keyProvider.rotate()
        } catch {
            NSLog("Imperum Tool clipboard archive unavailable (\(error)); starting empty this session without touching disk")
            archiveUnavailable = true
        }
    }

    private func scheduleSave() {
        saveWork?.cancel()
        guard !settings.settings.clearOnQuit, !archiveUnavailable else { return }
        let w = DispatchWorkItem { [weak self] in
            guard let self, let archive = self.archive else { return }
            let clips = self.store.clips   // snapshot the value array on main
            self.saveQueue.async {
                do { try archive.saveIndex(clips) } catch { NSLog("Imperum Tool clipboard save failed: \(error)") }
            }
        }
        saveWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: w)
    }

    private func confirmClear() {
        let a = NSAlert()
        a.messageText = "Clear the copy stack?"
        a.informativeText = "This removes every clip from memory and deletes the local archive."
        a.addButton(withTitle: "Clear Stack"); a.addButton(withTitle: "Cancel")
        a.alertStyle = .warning
        NSApp.activate(ignoringOtherApps: true)
        if a.runModal() == .alertFirstButtonReturn { clearAll() }
    }

    func clearAll() {
        saveWork?.cancel()
        store.clearAll()
        try? archive?.deleteAll()
        blobCache.removeAll()
    }

    func willTerminate() {
        saveWork?.cancel()
        saveQueue.sync {}   // drain a pending background save before deciding what to write last
        if settings.settings.clearOnQuit { store.clearAll(); try? archive?.deleteAll() }
        else if !archiveUnavailable { try? archive?.saveIndex(store.clips) }
        blobCache.removeAll()
    }
}
