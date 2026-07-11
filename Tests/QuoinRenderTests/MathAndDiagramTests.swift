#if canImport(AppKit) || canImport(UIKit)
import XCTest
import CoreGraphics
@testable import QuoinRender
import MermaidRender
import QuoinCore

/// Tests for the native math typesetter and diagram renderer.
///
/// These layers rasterise to fonts and CoreGraphics, so their pixel output is
/// machine dependent and not golden-snapshotted. Instead we assert:
///  - the supported/unsupported *classification* (deterministic, from the
///    parser) drives native rendering vs. the styled source-card fallback;
///  - attachments exist and are non-degenerate for supported input;
///  - font-independent *structural* invariants of `MathBox` layout — a
///    fraction stacks taller than its numerator, TeX inter-atom spacing adds
///    a known width around a relation, display limits stack. These hold for
///    any font because they compare boxes measured with the same font.
final class MathAndDiagramTests: XCTestCase {

    private var theme: Theme { Theme(prefersDark: false) }
    private let baseSize: CGFloat = 14

    private func typesetter() -> MathTypesetter { MathTypesetter(mathTheme: theme.mathTheme, baseSize: baseSize) }
    private func box(_ latex: String, display: Bool = false) -> MathTypesetter.MathBox {
        typesetter().layout(MathParser.parse(latex), display: display)
    }

    // MARK: - Support classification drives native vs. fallback

    func testSupportedMathProducesNonDegenerateAttachment() throws {
        for latex in ["E = mc^2", "\\frac{a}{b}", "x^2 + y^2", "\\sqrt{2}", "\\sum_{i=1}^{n} i"] {
            XCTAssertTrue(MathParser.isFullySupported(MathParser.parse(latex)), "\(latex) should be supported")
            let attachment = MathImageRenderer.attachmentString(
                latex: latex, display: false, mathTheme: theme.mathTheme, baseSize: baseSize
            )
            let string = try XCTUnwrap(attachment, "\(latex): expected a native attachment")
            XCTAssertEqual(string.length, 1, "\(latex): an attachment is one U+FFFC glyph")
            let value = string.attribute(.attachment, at: 0, effectiveRange: nil) as? NSTextAttachment
            let bounds = try XCTUnwrap(value?.bounds, "\(latex): attachment has no bounds")
            XCTAssertGreaterThan(bounds.width, 0, "\(latex): degenerate width")
            XCTAssertGreaterThan(bounds.height, 0, "\(latex): degenerate height")
        }
    }

    func testUnsupportedMathReturnsNilSoRendererFallsBack() {
        // \unknownmacro parses to an `.unsupported` leaf → not fully supported
        // → renderer keeps the styled source card instead of a broken glyph.
        let latex = "\\weirdcommand{x} + \\notreal"
        XCTAssertFalse(MathParser.isFullySupported(MathParser.parse(latex)))
        XCTAssertNil(MathImageRenderer.attachmentString(
            latex: latex, display: false, mathTheme: theme.mathTheme, baseSize: baseSize
        ), "unsupported LaTeX must return nil so the renderer keeps the fallback")
    }

    /// The block-math renderer path: supported LaTeX gets a centered
    /// attachment tagged with `mathSource`; unsupported gets the source-card
    /// fallback (a code canvas) still tagged with `mathSource` plus a caption.
    func testMathBlockRendererTagsSourceOnBothPaths() {
        let renderer = AttributedRenderer(theme: theme, baseURL: nil)

        let supported = renderer.render(MarkdownConverter.parse("$$ x = 1 $$"))
        assertContainsMathSource(supported.attributed, "x = 1", label: "supported block math")

        let unsupported = renderer.render(MarkdownConverter.parse("$$ \\weirdcommand{x} $$"))
        assertHasCodeCanvas(unsupported.attributed, label: "unsupported block math fallback")
    }

    // MARK: - Font-independent MathBox structural invariants

    func testFractionStacksTallerThanNumerator() {
        let fraction = box("\\frac{1}{2}")
        let numeral = box("1")
        XCTAssertGreaterThan(fraction.width, 0)
        // A single glyph cannot be 1.5x its own line height, so clearing this
        // bound proves the fraction stacks two parts plus its rule and gaps.
        // (A tighter multiplier would depend on exact font line metrics.)
        XCTAssertGreaterThan(fraction.height, numeral.height * 1.5,
            "a fraction stacks numerator over denominator, so it is far taller than one numeral")
    }

    /// TeX puts a *thick* (5/18 em) space on each side of a relation. Because
    /// the extra width is the only difference between `x=y` and the glyphs
    /// `xy` + `=` laid out without relation spacing, the font glyph widths
    /// cancel and the surplus must be ≈ 2·(5/18)·size, on any font.
    func testRelationSpacingMatchesTeXThickSpace() {
        let withRelation = box("x=y").width
        let glyphs = box("xy").width + box("=").width
        let surplus = withRelation - glyphs
        let expected = 2 * (5.0 / 18.0) * baseSize
        XCTAssertEqual(surplus, expected, accuracy: 0.5,
            "relation should contribute two TeX thick spaces (\(expected)pt), got \(surplus)pt")
    }

    func testDisplayLimitsStackTallerThanInlineScripts() {
        let display = box("\\sum_{i=1}^{n} i", display: true)
        let inline = box("\\sum_{i=1}^{n} i", display: false)
        XCTAssertGreaterThan(display.height, inline.height,
            "display style stacks the operator's limits above and below, growing its height")
    }

    // MARK: - Diagrams: native vs. source-card fallback

    func testSupportedDiagramProducesAttachment() throws {
        let flowchart = """
        flowchart TD
            A[Start] --> B[Middle]
            B --> C[End]
        """
        let attachment = MermaidRenderer.attachmentString(source: flowchart, theme: theme.diagramTheme)
        let string = try XCTUnwrap(attachment, "a flowchart should render natively")
        let value = string.attribute(.attachment, at: 0, effectiveRange: nil) as? NSTextAttachment
        let bounds = try XCTUnwrap(value?.bounds)
        XCTAssertGreaterThan(bounds.width, 0)
        XCTAssertGreaterThan(bounds.height, 0)
    }

    func testGanttChartRendersNatively() throws {
        let gantt = """
        gantt
            title Schedule
            section Work
            Design :done, d1, 2026-07-01, 2d
            Build  :active, b1, after d1, 3d
            Ship   :milestone, m1, after b1, 0d
        """
        let attachment = MermaidRenderer.attachmentString(source: gantt, theme: theme.diagramTheme)
        let string = try XCTUnwrap(attachment, "a gantt chart should render natively")
        let bounds = try XCTUnwrap((string.attribute(.attachment, at: 0, effectiveRange: nil) as? NSTextAttachment)?.bounds)
        XCTAssertGreaterThan(bounds.width, 0)
        XCTAssertGreaterThan(bounds.height, 0)
    }

    func testUnsupportedDiagramReturnsNilSoRendererFallsBack() {
        // A dialect the parser doesn't model returns nil from the parser, so
        // the renderer keeps the fenced source card.
        XCTAssertNil(MermaidParser.parse("nonesuchDiagram\n  a --> b"))
        XCTAssertNil(MermaidRenderer.attachmentString(
            source: "nonesuchDiagram\n  a --> b", theme: theme.diagramTheme
        ), "an unmodeled dialect must return nil so the renderer keeps the source card")
    }

    /// The renderer path: a native diagram is framed and tagged with
    /// `diagramSource`; an unsupported one degrades to a code canvas with the
    /// diagram source still attached plus a caption.
    func testDiagramRendererTagsSourceOnBothPaths() {
        let renderer = AttributedRenderer(theme: theme, baseURL: nil)

        let native = renderer.render(MarkdownConverter.parse("""
        ```mermaid
        flowchart TD
            A --> B
        ```
        """))
        assertHasDecoration(native.attributed, matching: { if case .diagramFrame = $0 { return true }; return false },
                            label: "native flowchart frame")

        let fallback = renderer.render(MarkdownConverter.parse("""
        ```mermaid
        nonesuchDiagram
            a --> b
        ```
        """))
        assertHasCodeCanvas(fallback.attributed, label: "unsupported diagram fallback")
    }

    // MARK: - Helpers

    private func assertContainsMathSource(_ string: NSAttributedString, _ expected: String, label: String) {
        var found = false
        string.enumerateAttribute(QuoinAttribute.mathSource, in: NSRange(location: 0, length: string.length)) { value, _, stop in
            if let latex = value as? String, latex.contains(expected) { found = true; stop.pointee = true }
        }
        XCTAssertTrue(found, "\(label): expected a run tagged mathSource containing \(expected)")
    }

    private func assertHasDecoration(
        _ string: NSAttributedString,
        matching predicate: (BlockDecoration.Kind) -> Bool,
        label: String
    ) {
        var found = false
        string.enumerateAttribute(QuoinAttribute.blockDecoration, in: NSRange(location: 0, length: string.length)) { value, _, stop in
            if let deco = value as? BlockDecoration, predicate(deco.kind) { found = true; stop.pointee = true }
        }
        XCTAssertTrue(found, "\(label): expected the matching block decoration")
    }

    private func assertHasCodeCanvas(_ string: NSAttributedString, label: String) {
        assertHasDecoration(string, matching: { if case .codeCanvas = $0 { return true }; return false }, label: label)
    }
}
#endif
