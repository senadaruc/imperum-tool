// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "ImperumTool",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.6.0"),
    ],
    targets: [
        .target(name: "ImperumCore"),
        .target(name: "CopyStackKit", dependencies: ["ImperumCore"]),
        .executableTarget(
            name: "ImperumTool",
            dependencies: [
                "ImperumCore", "CopyStackKit",
                .product(name: "Sparkle", package: "Sparkle"),
            ],
            linkerSettings: [
                // build.sh copies Sparkle.framework into Contents/Frameworks;
                // SwiftPM alone leaves the binary with no rpath that reaches it.
                // The second entry lets the bare binary under .build/ find the
                // framework SwiftPM places beside it.
                .unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks",
                              "-Xlinker", "-rpath", "-Xlinker", "@executable_path"]),
            ]
        ),
        .executableTarget(
            name: "copystack",
            dependencies: ["CopyStackKit"]
        ),
        .testTarget(name: "ImperumCoreTests", dependencies: ["ImperumCore"]),
        .testTarget(name: "CopyStackKitTests", dependencies: ["CopyStackKit"]),
    ]
)
