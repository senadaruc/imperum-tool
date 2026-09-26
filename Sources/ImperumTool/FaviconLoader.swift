// Sources/ImperumTool/FaviconLoader.swift
import AppKit

/// Opt-in only. Fetches `https://<host>/favicon.ico` once per host, caches
/// in memory and (unencrypted — public data) on disk.
final class FaviconLoader {
    var onLoaded: (() -> Void)?
    private var cache: [String: NSImage] = [:]
    private var inflight = Set<String>()
    private var failed = Set<String>()

    func icon(forHost host: String, cacheDir: URL?) -> NSImage? {
        if let i = cache[host] { return i }
        if failed.contains(host) || inflight.contains(host) { return nil }
        if let dir = cacheDir, let data = try? Data(contentsOf: dir.appendingPathComponent("\(host).ico")), let img = NSImage(data: data) {
            cache[host] = img; return img
        }
        inflight.insert(host)
        guard let url = URL(string: "https://\(host)/favicon.ico") else { failed.insert(host); return nil }
        var req = URLRequest(url: url); req.timeoutInterval = 5
        URLSession.shared.dataTask(with: req) { [weak self] data, resp, _ in
            DispatchQueue.main.async {
                guard let self else { return }
                self.inflight.remove(host)
                guard let data, (resp as? HTTPURLResponse)?.statusCode == 200, let img = NSImage(data: data) else {
                    self.failed.insert(host); return
                }
                self.cache[host] = img
                if let dir = cacheDir {
                    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                    try? data.write(to: dir.appendingPathComponent("\(host).ico"), options: .atomic)
                }
                self.onLoaded?()
            }
        }.resume()
        return nil
    }
}
