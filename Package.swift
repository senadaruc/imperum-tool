// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "WSMonitor",
    platforms: [.macOS(.v14)],
    targets: [
        .target(name: "WSCore"),
        .executableTarget(
            name: "WSMonitor",
            dependencies: ["WSCore"]
        ),
        .executableTarget(
            name: "WSHelper",
            dependencies: ["WSCore"]
        ),
        .testTarget(name: "WSCoreTests", dependencies: ["WSCore"]),
    ]
)
