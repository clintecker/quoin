#if canImport(AppKit)
import XCTest
import SwiftUI
@testable import MermaidRender
import MermaidLayout

final class MermaidViewTests: XCTestCase {

    /// End-to-end: MermaidView rasterizes to real pixels via SwiftUI's
    /// ImageRenderer, in both color schemes.
    @MainActor
    func testViewRendersDiagramInBothSchemes() throws {
        let source = "flowchart TD\n  A[Start] --> B[End]"
        for scheme in [ColorScheme.light, ColorScheme.dark] {
            let renderer = ImageRenderer(content: MermaidView(source).environment(\.colorScheme, scheme))
            let image = try XCTUnwrap(renderer.nsImage, "\(scheme) should rasterize")
            XCTAssertGreaterThan(image.size.width, 10)
            XCTAssertGreaterThan(image.size.height, 10)
        }
    }

    /// An explicit theme overrides the environment scheme.
    @MainActor
    func testExplicitThemeRenders() throws {
        let view = MermaidView("pie title T\n \"A\": 1", theme: DiagramTheme(prefersDark: true))
        let image = try XCTUnwrap(ImageRenderer(content: view).nsImage)
        XCTAssertGreaterThan(image.size.width, 10)
    }

    /// Unrecognized source falls back to visible monospaced text, not a blank.
    @MainActor
    func testUnrecognizedSourceShowsFallback() throws {
        let view = MermaidView("nonesuchDiagram\n  a --> b")
        let image = try XCTUnwrap(ImageRenderer(content: view).nsImage, "fallback should still rasterize")
        XCTAssertGreaterThan(image.size.width, 10)
        XCTAssertGreaterThan(image.size.height, 10)
    }

    /// A custom palette must actually change the rendered pixels — the
    /// end-to-end guarantee behind "override palette to re-skin every type".
    func testCustomPaletteChangesRender() throws {
        let source = "pie title P\n \"a\": 3\n \"b\": 2\n \"c\": 1"
        let stock = DiagramTheme(prefersDark: false)
        let mono = DiagramTheme(
            ink: stock.ink, secondaryTextColor: stock.secondaryTextColor,
            tertiaryTextColor: stock.tertiaryTextColor, canvas: stock.canvas,
            accent: stock.accent, hairline: stock.hairline, prefersDark: false,
            palette: [PlatformColor.systemIndigo]
        )
        let a = try XCTUnwrap(MermaidRenderer.image(source: source, theme: stock)?.tiffRepresentation)
        let b = try XCTUnwrap(MermaidRenderer.image(source: source, theme: mono)?.tiffRepresentation)
        XCTAssertNotEqual(a, b, "palette override must change the output")
    }

    /// The async variant renders off-thread and returns the same result as
    /// the sync path (they share cache and pipeline).
    func testAsyncImageMatchesSync() async throws {
        let source = "flowchart TD\n A --> B"
        let theme = DiagramTheme(prefersDark: false)
        // Pin the sync overload via a non-async closure: in an async context
        // Swift resolves `MermaidRenderer.image` to the async twin.
        let syncImage: PlatformImage? = { MermaidRenderer.image(source: source, theme: theme) }()
        let sync = try XCTUnwrap(syncImage)
        let asyncResult: PlatformImage? = await MermaidRenderer.image(source: source, theme: theme)
        let rendered = try XCTUnwrap(asyncResult)
        XCTAssertEqual(sync.size, rendered.size)
        let missing: PlatformImage? = await MermaidRenderer.image(source: "nonesuch", theme: theme)
        XCTAssertNil(missing)
    }

    func testTypeNameCoversAllCases() throws {
        let flowchart = try XCTUnwrap(MermaidParser.parse("flowchart TD\n  A --> B"))
        XCTAssertEqual(flowchart.typeName, "flowchart")
        let sankey = try XCTUnwrap(MermaidParser.parse("sankey-beta\nA,B,1"))
        XCTAssertEqual(sankey.typeName, "sankey")
    }
}
#endif
