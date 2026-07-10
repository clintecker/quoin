#if canImport(AppKit)
import XCTest
import AppKit
import MermaidRender
import QuoinCore
@testable import QuoinRender

/// The preview-anchored reveal (embed-editing brief, Phase 4 — the
/// flagship): while a mermaid/math block's source is open, the rendered
/// artifact stays visible ABOVE the source, re-rendered live as the source
/// changes; unparseable mid-edit source keeps the last good render plus a
/// calm note — never blank, never flashing. The editable range is the
/// SOURCE subrange only, still character-for-character 1:1 with the file.
final class PreviewAnchoredRevealTests: XCTestCase {

    private let source = """
    # Doc

    ```mermaid
    flowchart TD
        A[Start] --> B[End]
    ```

    Tail paragraph.
    """

    private func mermaidBlock(in document: QuoinDocument) throws -> Block {
        try XCTUnwrap(document.blocks.first {
            if case .mermaid = $0.kind { return true }
            return false
        })
    }

    private func hasAttachment(_ attributed: NSAttributedString, in range: NSRange) -> Bool {
        var found = false
        attributed.enumerateAttribute(.attachment, in: range) { value, _, stop in
            if value != nil { found = true; stop.pointee = true }
        }
        return found
    }

    func testOpenDiagramKeepsItsPreviewAboveTheSource() throws {
        let document = MarkdownConverter.parse(source)
        let block = try mermaidBlock(in: document)
        let renderer = AttributedRenderer()
        var cache: [BlockID: NSAttributedString] = [:]
        let editing = renderer.render(document, activeBlockID: block.id, activeCaret: 0, cache: &cache)
        let active = try XCTUnwrap(editing.activeEditableRange)
        let blockRange = try XCTUnwrap(editing.blockRanges[block.id])

        // The artifact never disappears: an attachment leads the fragment,
        // BEFORE the editable source.
        let previewRegion = NSRange(location: blockRange.location,
                                    length: active.location - blockRange.location)
        XCTAssertGreaterThan(previewRegion.length, 0, "the preview leads the fragment")
        XCTAssertTrue(hasAttachment(editing.attributed, in: previewRegion),
                      "the diagram must stay rendered while its source is open")

        // And the editable range is EXACTLY the source slice — 1:1.
        let slice = try XCTUnwrap(document.source.substring(in: block.range))
        XCTAssertEqual((editing.attributed.string as NSString).substring(with: active), slice,
                       "the 1:1 mapping is untouchable")
    }

    func testBrokenSourceHoldsTheLastGoodRenderWithANote() throws {
        let document = MarkdownConverter.parse(source)
        let block = try mermaidBlock(in: document)
        let renderer = AttributedRenderer()
        var cache: [BlockID: NSAttributedString] = [:]
        // A successful open primes the held preview…
        _ = renderer.render(document, activeBlockID: block.id, activeCaret: 0, cache: &cache)

        // …then the user breaks the source mid-edit (the per-keystroke
        // fragment path).
        let brokenSlice = "```mermaid\nflowchart TD %% now broken %%%%\n<<<>>>\n```"
        let brokenDocument = MarkdownConverter.parse("# Doc\n\n\(brokenSlice)\n\nTail.\n")
        let brokenBlock = try mermaidBlock(in: brokenDocument)
        let revealed = renderer.renderEditableSourceFragment(
            brokenSlice, caretOffset: 12, block: brokenBlock, document: brokenDocument)

        let previewRegion = NSRange(location: 0, length: revealed.editableRange.location)
        if MermaidRenderer.attachmentString(source: brokenSlice, theme: Theme().diagramTheme) != nil {
            throw XCTSkip("fixture unexpectedly parses; broken-source path not exercised")
        }
        XCTAssertTrue(hasAttachment(revealed.attributed, in: previewRegion),
                      "the last GOOD render must stay up — never blank")
        let head = (revealed.attributed.string as NSString).substring(with: previewRegion)
        XCTAssertTrue(head.contains("paused"),
                      "one calm note explains the held frame, got: \(head)")
        // Editable range still 1:1 with the broken slice.
        XCTAssertEqual((revealed.attributed.string as NSString).substring(with: revealed.editableRange),
                       brokenSlice)
    }

    func testOpeningABrokenDiagramFreshShowsPlainSource() throws {
        let brokenSlice = "```mermaid\nflowchart TD %% broken %%%%\n<<<>>>\n```"
        let brokenDocument = MarkdownConverter.parse("# Doc\n\n\(brokenSlice)\n\nTail.\n")
        let brokenBlock = try mermaidBlock(in: brokenDocument)
        let renderer = AttributedRenderer()
        renderer.resetActivePreview()
        let revealed = renderer.renderEditableSourceFragment(
            brokenSlice, caretOffset: 0, block: brokenBlock, document: brokenDocument)
        XCTAssertEqual(revealed.editableRange.location, 0,
                       "no held render, no preview — plain source, same as before the feature")
    }

    func testUnchangedSourceReusesThePreviewInstance() throws {
        let document = MarkdownConverter.parse(source)
        let block = try mermaidBlock(in: document)
        let slice = try XCTUnwrap(document.source.substring(in: block.range))
        let renderer = AttributedRenderer()

        func previewAttachment(_ revealed: AttributedRenderer.RevealedFragment) -> NSTextAttachment? {
            var found: NSTextAttachment?
            revealed.attributed.enumerateAttribute(
                .attachment, in: NSRange(location: 0, length: revealed.editableRange.location)
            ) { value, _, stop in
                if let attachment = value as? NSTextAttachment { found = attachment; stop.pointee = true }
            }
            return found
        }
        // Caret moves re-reveal the block; the diagram must not re-render.
        let first = previewAttachment(renderer.renderEditableSourceFragment(
            slice, caretOffset: 0, block: block, document: document))
        let second = previewAttachment(renderer.renderEditableSourceFragment(
            slice, caretOffset: 20, block: block, document: document))
        XCTAssertNotNil(first)
        XCTAssertTrue(first === second,
                      "same source → same preview instance (no re-render on caret moves, " +
                      "and the flip-patch/full-render projections stay attribute-identical)")
    }

    func testMathBlockGetsThePreviewToo() throws {
        let mathSource = "# Doc\n\n$$x^2 + y^2 = z^2$$\n\nTail.\n"
        let document = MarkdownConverter.parse(mathSource)
        let block = try XCTUnwrap(document.blocks.first {
            if case .mathBlock = $0.kind { return true }
            return false
        })
        let renderer = AttributedRenderer()
        var cache: [BlockID: NSAttributedString] = [:]
        let editing = renderer.render(document, activeBlockID: block.id, activeCaret: 0, cache: &cache)
        let active = try XCTUnwrap(editing.activeEditableRange)
        let blockRange = try XCTUnwrap(editing.blockRanges[block.id])
        XCTAssertTrue(hasAttachment(
            editing.attributed,
            in: NSRange(location: blockRange.location, length: active.location - blockRange.location)),
            "the equation stays typeset while its LaTeX is open")
    }
}
#endif
