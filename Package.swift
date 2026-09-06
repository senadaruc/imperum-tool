// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "ImperumTool",
    platforms: [.macOS(.v14)],
    targets: [
        .target(name: "ImperumCore"),
        .executableTarget(
            name: "ImperumTool",
            dependencies: ["ImperumCore"]
        ),
        .testTarget(name: "ImperumCoreTests", dependencies: ["ImperumCore"]),
    ]
)
