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
        .package(url: "https://github.com/swiftlang/swift-markdown.git", from: "0.8.0"),
        // The Mermaid engine is Quoin's own published package — consumed from
        // GitHub exactly like any other host app would (first-party, so exempt
        // from the one-third-party-dependency policy).
        .package(url: "https://github.com/clintecker/MermaidKit.git", from: "0.8.0"),
    ],
    targets: [
        .target(
            name: "QuoinCore",
            dependencies: [
                .product(name: "Markdown", package: "swift-markdown"),
                .product(name: "MermaidLayout", package: "MermaidKit"),
            ],
            path: "Sources/QuoinCore"
        ),
        .target(
            name: "QuoinRender",
            dependencies: [
                "QuoinCore",
                .product(name: "MermaidRender", package: "MermaidKit"),
            ],
            path: "Sources/QuoinRender"
        ),
        .testTarget(
            name: "QuoinCoreTests",
            dependencies: ["QuoinCore"],
            path: "Tests/QuoinCoreTests",
            // The conformance snapshot is read via #filePath, not the bundle.
            exclude: ["Snapshots/renderer-metrics.json"]
        ),
        // The render layer only compiles with AppKit/UIKit present, so this
        // target's sources are all guarded `#if canImport(AppKit) || UIKit`
        // and it runs on the macOS CI runner (empty elsewhere, e.g. Linux).
        .testTarget(
            name: "QuoinRenderTests",
            dependencies: ["QuoinRender", "QuoinCore"],
            path: "Tests/QuoinRenderTests",
            // The golden digest is read via #filePath, not the test bundle.
            exclude: ["Snapshots/render-digests.json"]
        ),
    ]
)
