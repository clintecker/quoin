#if canImport(AppKit)
import XCTest
import AppKit
import QuoinCore
@testable import QuoinRender

/// Rendering + reveal for CriticMarkup marks (suggestions design, S1).
final class SuggestionRenderTests: XCTestCase {

    private let source = "Alpha {++added++} beta {--removed--} gamma {~~old~>new~~} " +
                         "delta {>>a note<<} epsilon {==flagged==}{#c1} omega.\n"

    func testRenderedProjectionStylesEachKind() throws {
        let document = MarkdownConverter.parse(source)
        let rendered = AttributedRenderer().render(document)
        let text = rendered.attributed.string

        // Marks render as tracked changes, never silently collapsed (RDFM
        // rule): inserted and deleted text BOTH visible; the substitution
        // shows old → new; the comment collapses to a labeled chip.
        XCTAssertTrue(text.contains("added"))
        XCTAssertTrue(text.contains("removed"))
        XCTAssertTrue(text.contains("old → new"))
        XCTAssertTrue(text.contains("💬 a note"))
        XCTAssertTrue(text.contains("flagged"))
        // The raw delimiters do NOT appear in the rendered projection.
        XCTAssertFalse(text.contains("{++"))
        XCTAssertFalse(text.contains("~>"))
        XCTAssertFalse(text.contains("{#c1}"))

        // Kind styling: insertion carries the insert fill; deletion is struck.
        let theme = Theme()
        let ns = text as NSString
        let insertAt = ns.range(of: "added").location
        XCTAssertEqual(
            rendered.attributed.attribute(.backgroundColor, at: insertAt, effectiveRange: nil) as? PlatformColor,
            theme.suggestionInsertFill)
        let deleteAt = ns.range(of: "removed").location
        XCTAssertNotNil(rendered.attributed.attribute(.strikethroughStyle, at: deleteAt, effectiveRange: nil))
    }

    func testRevealIsOneToOneAndClaimsBeforeStrikethroughAndHighlight() throws {
        let document = MarkdownConverter.parse(source)
        let block = try XCTUnwrap(document.blocks.first)
        let slice = try XCTUnwrap(document.source.substring(in: block.range))
        let renderer = AttributedRenderer()
        let revealed = renderer.renderEditableSourceFragment(
            slice, caretOffset: 0, block: block, document: document)

        // The 1:1 contract: revealed characters are exactly the source slice.
        XCTAssertEqual((revealed.attributed.string as NSString)
            .substring(with: revealed.editableRange), slice)

        // The critic pass claimed `{~~…~~}` before the `~~` strikethrough
        // pass: the substitution's OLD half is struck (kind styling), but the
        // sigils themselves are faded delimiters, not strikethrough content.
        let ns = revealed.attributed.string as NSString
        let oldAt = ns.range(of: "old~>").location
        XCTAssertNotNil(revealed.attributed.attribute(.strikethroughStyle, at: oldAt, effectiveRange: nil),
                        "substitution old half styles as deletion in the reveal")
        // And `{==flagged==}` took the critic highlight fill, not the lime
        // `==` highlight fill.
        let flaggedAt = ns.range(of: "flagged").location
        XCTAssertEqual(
            revealed.attributed.attribute(.backgroundColor, at: flaggedAt, effectiveRange: nil) as? PlatformColor,
            Theme().suggestionHighlightFill)
    }
}

// MARK: - The endmatter chip is panel UI, never inline YAML (redline)

extension SuggestionRenderTests {
    func testEndmatterChipLinksToReviewPanelAndHasNoEditAffordance() throws {
        let source = "Body {++x++}{#s1}.\n\n---\nsuggestions:\n  s1: { by: AI }\n"
        let document = MarkdownConverter.parse(source)
        let rendered = AttributedRenderer().render(document)
        let block = try XCTUnwrap(document.blocks.first {
            if case .reviewEndmatter = $0.kind { return true }
            return false
        })
        let range = try XCTUnwrap(rendered.blockRanges[block.id])
        var foundReviewLink = false
        var foundEditLink = false
        rendered.attributed.enumerateAttribute(.link, in: range) { value, _, _ in
            guard let url = value as? URL else { return }
            if QuoinLink.isReviewURL(url) { foundReviewLink = true }
            if QuoinLink.isEditURL(url) { foundEditLink = true }
        }
        XCTAssertTrue(foundReviewLink, "the chip opens the Review panel")
        XCTAssertFalse(foundEditLink, "no inline-YAML edit affordance")
    }
}
#endif
