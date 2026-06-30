import Foundation
import Darwin

/// All processes via sysctl(KERN_PROC_ALL): (pid, comm) where comm is the
/// kernel's 16-char truncated process name. Works without elevated privileges
/// even for processes owned by other users (e.g. WindowServer / _windowserver).
public func allProcessComms() -> [(pid: Int32, comm: String)] {
    var mib = [CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0]
    var size = 0
    guard sysctl(&mib, 4, nil, &size, nil, 0) == 0, size > 0 else { return [] }
    let stride = MemoryLayout<kinfo_proc>.stride
    var procs = [kinfo_proc](repeating: kinfo_proc(), count: size / stride)
    guard sysctl(&mib, 4, &procs, &size, nil, 0) == 0 else { return [] }
    let real = size / stride
    var out: [(Int32, String)] = []
    out.reserveCapacity(real)
    for i in 0..<real {
        var p = procs[i]
        let pid = p.kp_proc.p_pid
        let comm = withUnsafeBytes(of: &p.kp_proc.p_comm) { raw -> String in
            String(cString: raw.bindMemory(to: CChar.self).baseAddress!)
        }
        out.append((pid, comm))
    }
    return out
}

/// Finds the WindowServer pid via sysctl (proc_name fails on it for non-root).
public func windowServerPID() -> Int32? {
    allProcessComms().first { $0.comm == "WindowServer" }?.pid
}

/// Process name for a same-user pid (proc_name; returns nil for cross-user pids).
public func processName(pid: Int32) -> String? {
    var buf = [CChar](repeating: 0, count: 4096)
    let n = proc_name(pid, &buf, UInt32(buf.count))
    return n > 0 ? String(cString: buf) : nil
}
