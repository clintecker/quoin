#if canImport(AppKit)
import XCTest
import AppKit
import QuoinCore
@testable import QuoinRender

/// Reveal round-trip fidelity: activating a block must not leave residue
/// when it closes, and must not change the block's height when it opens.
final class RevealFidelityTests: XCTestCase {

    private let source = """
    # Reveal fidelity

    First paragraph of prose, plain as can be, with no markup at all here.

    Second paragraph, equally plain, sitting right below the first one.

    ### A heading to reveal

    Closing paragraph under the heading for good measure.
    """

    /// The sticky-tint regression: a PLAIN paragraph's revealed source is
    /// the same STRING as its rendered text — only attributes differ. When
    /// a deactivation lands via the resync path (string-equal splice), the
    /// old splice "changed nothing" and left the reveal tint behind. The
    /// attribute sync must remove it.
    func testResyncRemovesRevealTintWhenStringsAreEqual() throws {
        let document = MarkdownConverter.parse(source)
        let renderer = AttributedRenderer()
        var cache: [BlockID: NSAttributedString] = [:]
        let para = try XCTUnwrap(document.blocks.first {
            if case .paragraph = $0.kind { return true }
            return false
        }?.id)

        // Storage holds the ACTIVE projection (tinted paragraph)…
        let active = renderer.render(document, activeBlockID: para, activeCaret: 3, cache: &cache)
        let storage = NSTextStorage()
        storage.setAttributedString(active.attributed)
        let tint = renderer.theme.accent.withAlphaComponent(0.05)
        let activeRange = try XCTUnwrap(active.activeEditableRange)
        let tinted = storage.attribute(.backgroundColor, at: activeRange.location, effectiveRange: nil) as? NSColor
        XCTAssertEqual(tinted, tint, "test premise: the revealed block is tinted")

        // …and the model publishes the READING projection with NO patches
        // (the resync path — what a skipped patch revision falls back to).
        cache.removeAll()
        let reading = renderer.render(document, activeBlockID: nil, activeCaret: nil, cache: &cache)
        let projection = RenderedDocument(
            attributed: reading.attributed, blockRanges: reading.blockRanges, revision: 7)
        _ = MarkdownReaderView.Coordinator.applyProjection(projection, to: storage)

        // The tint (and every other reveal attribute) must be gone.
        var residue = 0
        storage.enumerateAttribute(.backgroundColor, in: NSRange(location: 0, length: storage.length)) { value, _, _ in
            if let color = value as? NSColor, color == tint { residue += 1 }
        }
        XCTAssertEqual(residue, 0, "reveal tint survived a string-equal resync")
        XCTAssertEqual(storage.string, reading.attributed.string)
    }

    /// A plain paragraph's revealed fragment must occupy exactly the height
    /// of its rendered fragment — same string, same font, same line metrics,
    /// same outer spacing — so click-to-edit doesn't shift the content below.
    func testPlainParagraphRevealIsHeightNeutral() throws {
        let document = MarkdownConverter.parse(source)
        let renderer = AttributedRenderer()
        var cache: [BlockID: NSAttributedString] = [:]
        let para = try XCTUnwrap(document.blocks.first {
            if case .paragraph = $0.kind { return true }
            return false
        }?.id)

        let reading = renderer.render(document, activeBlockID: nil, activeCaret: nil, cache: &cache)
        let revealed = renderer.render(document, activeBlockID: para, activeCaret: 3, cache: &cache)
        XCTAssertEqual(measureHeight(reading.attributed),
                       measureHeight(revealed.attributed),
                       accuracy: 1.0,
                       "revealing a plain paragraph must not change the document height")
    }

    /// A heading's reveal changes fonts by design (source view), but its
    /// OUTER spacing must hold so the shift stays small — bounded well under
    /// the ~30pt lurch the missing spacing-above used to cause.
    func testHeadingRevealKeepsOuterSpacing() throws {
        let document = MarkdownConverter.parse(source)
        let renderer = AttributedRenderer()
        var cache: [BlockID: NSAttributedString] = [:]
        let heading = try XCTUnwrap(document.blocks.first {
            if case .heading(let level, _, _) = $0.kind { return level == 3 }
            return false
        }?.id)

        let reading = renderer.render(document, activeBlockID: nil, activeCaret: nil, cache: &cache)
        let revealed = renderer.render(document, activeBlockID: heading, activeCaret: 3, cache: &cache)
        let delta = abs(measureHeight(reading.attributed) - measureHeight(revealed.attributed))
        XCTAssertLessThan(delta, 8, "heading reveal shifted content by \(delta)pt")
    }

    private func measureHeight(_ attributed: NSAttributedString) -> CGFloat {
        let storage = NSTextStorage(attributedString: attributed)
        let contentStorage = NSTextContentStorage()
        contentStorage.textStorage = storage
        let layoutManager = NSTextLayoutManager()
        contentStorage.addTextLayoutManager(layoutManager)
        let container = NSTextContainer(size: NSSize(width: 600, height: CGFloat.greatestFiniteMagnitude))
        layoutManager.textContainer = container
        layoutManager.ensureLayout(for: contentStorage.documentRange)
        var maxY: CGFloat = 0
        layoutManager.enumerateTextLayoutFragments(from: contentStorage.documentRange.location) { fragment in
            maxY = max(maxY, fragment.layoutFragmentFrame.maxY)
            return true
        }
        return maxY
    }
}
#endif
