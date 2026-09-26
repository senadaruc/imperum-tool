// Sources/ImperumTool/PickerReaper.swift
import CopyStackKit
import Darwin
import Foundation

/// Ends a `copystack --pick` process that outlived its session's teardown
/// (e.g. its host window was closed without the host terminating its pty):
/// SIGHUP after a grace period, SIGKILL after another. Every signal is
/// re-guarded, so a pid that exited and was reused by an unrelated process
/// in the meantime is never signalled.
enum PickerReaper {
    static func reap(pid: pid_t, grace: TimeInterval = 1.0) {
        DispatchQueue.main.asyncAfter(deadline: .now() + grace) {
            guard isLivePicker(pid) else { return }
            kill(pid, SIGHUP)
            DispatchQueue.main.asyncAfter(deadline: .now() + grace) {
                guard isLivePicker(pid) else { return }
                kill(pid, SIGKILL)
            }
        }
    }

    /// Alive (`kill(pid, 0)` succeeds), not us or launchd, and its
    /// executable is a `copystack` binary.
    static func isLivePicker(_ pid: pid_t) -> Bool {
        guard pid > 1, pid != getpid(), kill(pid, 0) == 0 else { return false }
        var buffer = [CChar](repeating: 0, count: 4096)   // PROC_PIDPATHINFO_MAXSIZE
        let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        guard length > 0 else { return false }
        return HostCommand.isPickerExecutable(path: String(cString: buffer))
    }
}
