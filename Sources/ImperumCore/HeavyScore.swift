public struct AppSample: Equatable {
    public var pid: Int32
    public var name: String
    public var windows: Int
    public var area: Int                 // total pixel area across displays
    public var perDisplayArea: [UInt32: Int]
    public var cpu: Double               // instantaneous %, 0..(100*cores)
    public var rss: Double               // MB
    public var heavy: Double
    public init(pid: Int32, name: String, windows: Int, area: Int,
                perDisplayArea: [UInt32: Int] = [:], cpu: Double = 0,
                rss: Double = 0, heavy: Double = 0) {
        self.pid = pid; self.name = name; self.windows = windows; self.area = area
        self.perDisplayArea = perDisplayArea; self.cpu = cpu; self.rss = rss; self.heavy = heavy
    }
}

public enum HeavyWeights {
    public static let cpu = 100.0
    public static let areaDivisor = 100_000.0
    public static let window = 20.0
    public static let rssDivisor = 20.0
}

public func heavyScore(cpu: Double, area: Int, windows: Int, rss: Double) -> Double {
    cpu * HeavyWeights.cpu
        + Double(area) / HeavyWeights.areaDivisor
        + Double(windows) * HeavyWeights.window
        + rss / HeavyWeights.rssDivisor
}
