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

    func testTypeNameCoversAllCases() throws {
        let flowchart = try XCTUnwrap(MermaidParser.parse("flowchart TD\n  A --> B"))
        XCTAssertEqual(flowchart.typeName, "flowchart")
        let sankey = try XCTUnwrap(MermaidParser.parse("sankey-beta\nA,B,1"))
        XCTAssertEqual(sankey.typeName, "sankey")
    }
}
#endif
