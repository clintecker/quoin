// swift-tools-version: 5.10
import PackageDescription

// MermaidKit — native Mermaid diagram parsing, layout, and rendering.
// MermaidLayout is platform-free geometry (parse → layout → scene IR + a
// geometric layout linter); MermaidRender draws with CoreGraphics/CoreText on
// Apple platforms. No JavaScript, no WebView, no dependencies.
let package = Package(
    name: "MermaidKit",
    platforms: [.macOS(.v14), .iOS(.v17), .visionOS(.v1)],
    products: [
        .library(name: "MermaidLayout", targets: ["MermaidLayout"]),
        .library(name: "MermaidRender", targets: ["MermaidRender"]),
    ],
    targets: [
        .target(name: "MermaidLayout", path: "Sources/MermaidLayout"),
        .target(name: "MermaidRender", dependencies: ["MermaidLayout"], path: "Sources/MermaidRender"),
        .testTarget(name: "MermaidLayoutTests", dependencies: ["MermaidLayout"], path: "Tests/MermaidLayoutTests"),
        .testTarget(name: "MermaidRenderTests", dependencies: ["MermaidRender", "MermaidLayout"], path: "Tests/MermaidRenderTests"),
    ]
)
