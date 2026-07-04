// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "Quoin",
    platforms: [
        .macOS(.v14),
        .iOS(.v17),
        .visionOS(.v1),
    ],
    products: [
        .library(name: "QuoinCore", targets: ["QuoinCore"]),
        .library(name: "QuoinRender", targets: ["QuoinRender"]),
    ],
    dependencies: [
        .package(url: "https://github.com/swiftlang/swift-markdown.git", from: "0.5.0"),
    ],
    targets: [
        .target(
            name: "QuoinCore",
            dependencies: [
                .product(name: "Markdown", package: "swift-markdown"),
            ],
            path: "Sources/QuoinCore"
        ),
        .target(
            name: "QuoinRender",
            dependencies: ["QuoinCore"],
            path: "Sources/QuoinRender"
        ),
        .testTarget(
            name: "QuoinCoreTests",
            dependencies: ["QuoinCore"],
            path: "Tests/QuoinCoreTests",
            // The conformance snapshot is read via #filePath, not the bundle.
            exclude: ["Snapshots/renderer-metrics.json"]
        ),
    ]
)
