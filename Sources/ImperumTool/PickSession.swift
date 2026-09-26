// Sources/ImperumTool/PickSession.swift
import AppKit
import ApplicationServices
import CopyStackKit
import Foundation
import ImperumCore

/// One in-flight "double-tap ⌘V opened a terminal picker" session: owns the
/// host window from `open` through the picker exiting, the wait for focus to
/// settle back on the origin terminal, and posting ⌘V there.
///
/// Main-thread invariant: every method here, and every closure passed to it,
/// is called on main — `TerminalHost.open`/`position` complete on main (see
/// `TerminalHosts.swift`), `ClipboardController` drives `onConnected`/
/// `onPasteRequested`/`onClosed` from its own main-thread server callbacks,
/// and the focus-poll `Timer` runs on the main run loop.
final class PickSession {
    let token: String
    let originPID: pid_t
    let originWindow: AXUIElement?
    let host: TerminalHost
    let hostApp: TerminalApp

    private let copystackPath: String
    private let commitPasted: (Clip) -> Void
    /// Called when the session can't proceed (open failed, or no `hello`
    /// arrived within the connect timeout): the caller falls back to the
    /// SwiftUI panel.
    private let onFallback: () -> Void
    /// Called exactly once, whenever this session is done for any reason
    /// (fallback, cancel, or a completed/timed-out paste-back), so the owner
    /// can drop its reference.
    private let onFinished: () -> Void

    private(set) var handle: HostHandle?
    private(set) var connected = false
    private(set) var pending: Clip?

    private var connectTimeoutWork: DispatchWorkItem?
    private var focusWait = FocusWait()
    private var focusTimer: Timer?
    private var finished = false

    init(originPID: pid_t, originWindow: AXUIElement?, host: TerminalHost, hostApp: TerminalApp,
         copystackPath: String, commitPasted: @escaping (Clip) -> Void,
         onFallback: @escaping () -> Void, onFinished: @escaping () -> Void) {
        self.token = Self.randomToken()
        self.originPID = originPID
        self.originWindow = originWindow
        self.host = host
        self.hostApp = hostApp
        self.copystackPath = copystackPath
        self.commitPasted = commitPasted
        self.onFallback = onFallback
        self.onFinished = onFinished
    }

    func start() {
        host.open(session: token, copystackPath: copystackPath) { [weak self] result in
            guard let self, !self.finished else { return }
            switch result {
            case .success(let handle):
                self.handle = handle
                self.host.position(handle, windowTitle: HostCommand.windowTitle(session: self.token))
                self.armConnectTimeout()
            case .failure:
                self.onFallback()
                self.finish(callFinished: true)
            }
        }
    }

    /// A `hello` carrying this session's token arrived over the socket.
    func onConnected() {
        guard !finished else { return }
        connected = true
        connectTimeoutWork?.cancel()
        connectTimeoutWork = nil
    }

    /// The server relayed a `paste` request made inside the picker.
    func onPasteRequested(_ clip: Clip) {
        guard !finished else { return }
        pending = clip
    }

    /// The picker's connection closed (EOF): the picker has exited, one way
    /// or another (Enter, Esc, or the process being killed).
    func onClosed() {
        guard !finished else { return }
        guard let handle else { return finish(callFinished: true) }
        host.close(handle)
        startFocusWait()
    }

    /// A second trigger arrived while this session is still open: close the
    /// host window, give the origin one refocus nudge, and tear down.
    func cancel() {
        guard !finished else { return }
        connectTimeoutWork?.cancel()
        connectTimeoutWork = nil
        if let handle { host.close(handle) }
        AXWindow.setFrontmost(pid: originPID)
        if let originWindow { AXWindow.raise(originWindow) }
        finish(callFinished: true)
    }

    // MARK: Connect timeout

    private func armConnectTimeout() {
        let work = DispatchWorkItem { [weak self] in self?.connectTimedOut() }
        connectTimeoutWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.0, execute: work)
    }

    private func connectTimedOut() {
        guard !finished, !connected else { return }
        if let handle { host.close(handle) }
        onFallback()
        finish(callFinished: true)
    }

    // MARK: Focus wait / paste-back

    private func startFocusWait() {
        focusWait = FocusWait()
        let startedAt = Date()
        focusTimer = Timer.scheduledTimer(withTimeInterval: 0.02, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.tickFocusWait(elapsedMs: Int(Date().timeIntervalSince(startedAt) * 1000))
        }
    }

    private func tickFocusWait(elapsedMs: Int) {
        guard let handle else { return }
        let frontPID = NSWorkspace.shared.frontmostApplication?.processIdentifier
        let originIsFrontmost = frontPID == originPID
        let originWindowFocused: Bool
        if let originWindow {
            if let focused = AXWindow.focusedWindow(pid: originPID) {
                originWindowFocused = CFEqual(focused, originWindow)
            } else {
                originWindowFocused = false
            }
        } else {
            // Nothing was recorded to compare against (the origin had no
            // focused window when the session started) — don't block
            // forever on a check that can never succeed.
            originWindowFocused = true
        }
        let pickerGone = AXWindow.find(pid: handle.hostPID, titleContains: HostCommand.windowTitle(session: token)) == nil
        let observation = FocusWait.Observation(originIsFrontmost: originIsFrontmost, originWindowFocused: originWindowFocused,
                                                 pickerWindowGone: pickerGone, elapsedMs: elapsedMs)
        switch focusWait.step(observation) {
        case .wait:
            break
        case .nudge:
            AXWindow.setFrontmost(pid: originPID)
            if let originWindow { AXWindow.raise(originWindow) }
        case .post:
            focusTimer?.invalidate(); focusTimer = nil
            if let clip = pending {
                ClipPaster.postPaste()
                commitPasted(clip)
            }
            finish(callFinished: true)
        case .timeout:
            focusTimer?.invalidate(); focusTimer = nil
            if let clip = pending {
                HUD.shared.show("Copied — press ⌘V to paste", symbol: "doc.on.clipboard")
                commitPasted(clip)
            }
            finish(callFinished: true)
        }
    }

    // MARK: Teardown

    private func finish(callFinished: Bool) {
        guard !finished else { return }
        finished = true
        focusTimer?.invalidate(); focusTimer = nil
        connectTimeoutWork?.cancel(); connectTimeoutWork = nil
        if callFinished { onFinished() }
    }

    private static func randomToken() -> String {
        var bytes = [UInt8](repeating: 0, count: 16)   // 128 bits
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        precondition(status == errSecSuccess, "SecRandomCopyBytes failed with status \(status)")
        return bytes.map { String(format: "%02x", $0) }.joined()
    }
}
