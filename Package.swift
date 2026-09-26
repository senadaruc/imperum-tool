// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "ImperumTool",
    platforms: [.macOS(.v14)],
    targets: [
        .target(name: "ImperumCore"),
        .target(name: "CopyStackKit", dependencies: ["ImperumCore"]),
        .executableTarget(
            name: "ImperumTool",
            dependencies: ["ImperumCore", "CopyStackKit"]
        ),
        .executableTarget(
            name: "copystack",
            dependencies: ["CopyStackKit"]
        ),
        .testTarget(name: "ImperumCoreTests", dependencies: ["ImperumCore"]),
        .testTarget(name: "CopyStackKitTests", dependencies: ["CopyStackKit"]),
    ]
)
