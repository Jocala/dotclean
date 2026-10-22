// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "dotclean",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "DotCleanCore", targets: ["DotCleanCore"]),
        .executable(name: "bclean", targets: ["bclean"]),
        .executable(name: "DotClean", targets: ["DotCleanApp"]),
    ],
    targets: [
        .target(
            name: "DotCleanCore",
            path: "Sources/DotCleanCore"
        ),
        .executableTarget(
            name: "bclean",
            dependencies: ["DotCleanCore"],
            path: "Sources/bclean"
        ),
        .executableTarget(
            name: "DotCleanApp",
            dependencies: ["DotCleanCore"],
            path: "Sources/DotCleanApp"
        ),
        .testTarget(
            name: "DotCleanCoreTests",
            dependencies: ["DotCleanCore"],
            path: "Tests/DotCleanCoreTests"
        ),
    ],
    swiftLanguageModes: [.v5]
)
