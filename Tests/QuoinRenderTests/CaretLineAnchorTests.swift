#if canImport(AppKit)
import XCTest
import AppKit
import QuoinCore
@testable import QuoinRender

/// THE viewport invariant, generalized: on any activate/deactivate flip,
/// the LINE THE CARET IS ON stays exactly where the user was looking —
/// whatever happens to the block's height around it (tables gain their
/// delimiter row on reveal; embeds swap attachments for source). "The user
/// should not be surprised."
final class CaretLineAnchorTests: XCTestCase {

    func testCaretLineStaysPutAcrossTableReveal() throws {
        var source = "# Anchor\n\n"
        for i in 0..<30 { source += "Paragraph \(i) of filler prose to make the document scroll.\n\n" }
        source += "| Name | Value |\n|------|------:|\n| alpha | 1 |\n| beta | 22 |\n| gamma | 333 |\n\n"
        for i in 30..<60 { source += "Paragraph \(i) of filler prose below the table.\n\n" }
        let document = MarkdownConverter.parse(source)
        let renderer = AttributedRenderer()
        var cache: [BlockID: NSAttributedString] = [:]
        let table = try XCTUnwrap(document.blocks.first {
            if case .table = $0.kind { return true }
            return false
        })

        let reading = renderer.render(document, activeBlockID: nil, activeCaret: nil, cache: &cache)

        // Real TextKit stack in a scrollable viewport.
        let contentStorage = NSTextContentStorage()
        let layoutManager = NSTextLayoutManager()
        contentStorage.addTextLayoutManager(layoutManager)
        let container = NSTextContainer(size: NSSize(width: 600, height: CGFloat.greatestFiniteMagnitude))
        container.widthTracksTextView = true
        layoutManager.textContainer = container
        let textView = QuoinTextView(frame: NSRect(x: 0, y: 0, width: 600, height: 0), textContainer: container)
        textView.isVerticallyResizable = true
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
        scroll.documentView = textView
        let storage = try XCTUnwrap(textView.textContentStorage?.textStorage)
        storage.setAttributedString(reading.attributed)
        textView.textLayoutManager?.ensureLayout(for: try XCTUnwrap(textView.textContentStorage?.documentRange))
        textView.sizeToFit()

        let view = MarkdownReaderView(rendered: RenderedDocument(
            attributed: reading.attributed, blockRanges: reading.blockRanges))
        let coordinator = MarkdownReaderView.Coordinator(parent: view)
        coordinator.textView = textView

        // "Click" a middle table row: caret on the beta row, scrolled into view.
        let tableRange = try XCTUnwrap(reading.blockRanges[table.id])
        let betaOffset = (reading.attributed.string as NSString)
            .range(of: "beta", options: [], range: tableRange).location
        XCTAssertNotEqual(betaOffset, NSNotFound)
        coordinator.scrollBlockTop(tableRange, toScreenY: 120, in: textView)
        let before = try XCTUnwrap(coordinator.lineScreenY(at: betaOffset, in: textView))

        // The flip (activation patches) lands, then the caret pin — exactly
        // what updateNSView does.
        let base = RenderedDocument(attributed: reading.attributed, blockRanges: reading.blockRanges)
        let update = try XCTUnwrap(renderer.activationFlipUpdate(
            document: document, current: base, from: nil, to: table.id, caret: nil))
        for patch in update.storagePatches {
            _ = MarkdownReaderView.Coordinator.applyStoragePatch(in: storage, patch: patch)
        }
        // The caret's storage position after the flip: same row, found in
        // the revealed source.
        let newTableRange = try XCTUnwrap(update.blockRanges[table.id])
        let newBeta = (storage.string as NSString)
            .range(of: "beta", options: [], range: newTableRange).location
        XCTAssertNotEqual(newBeta, NSNotFound)
        coordinator.pinCaretLine(at: newBeta, toScreenY: before, in: textView)

        let after = try XCTUnwrap(coordinator.lineScreenY(at: newBeta, in: textView))
        XCTAssertEqual(after, before, accuracy: 2,
                       "the clicked table row must stay where the user was looking (was \(before), now \(after))")
    }

    func testScrollCaretIntoViewIsNoOpWhenVisible() throws {
        var source = "# Visible\n\n"
        for i in 0..<50 { source += "Paragraph \(i) of filler prose to make the document scroll.\n\n" }
        let document = MarkdownConverter.parse(source)
        let renderer = AttributedRenderer()
        var cache: [BlockID: NSAttributedString] = [:]
        let reading = renderer.render(document, activeBlockID: nil, activeCaret: nil, cache: &cache)

        let contentStorage = NSTextContentStorage()
        let layoutManager = NSTextLayoutManager()
        contentStorage.addTextLayoutManager(layoutManager)
        let container = NSTextContainer(size: NSSize(width: 600, height: CGFloat.greatestFiniteMagnitude))
        container.widthTracksTextView = true
        layoutManager.textContainer = container
        let textView = QuoinTextView(frame: NSRect(x: 0, y: 0, width: 600, height: 0), textContainer: container)
        textView.isVerticallyResizable = true
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
        scroll.documentView = textView
        textView.textContentStorage?.textStorage?.setAttributedString(reading.attributed)
        textView.textLayoutManager?.ensureLayout(for: try XCTUnwrap(textView.textContentStorage?.documentRange))
        textView.sizeToFit()

        let view = MarkdownReaderView(rendered: RenderedDocument(
            attributed: reading.attributed, blockRanges: reading.blockRanges))
        let coordinator = MarkdownReaderView.Coordinator(parent: view)
        coordinator.textView = textView

        // Scroll somewhere; pick a caret location mid-viewport.
        scroll.contentView.scroll(to: NSPoint(x: 0, y: 300))
        scroll.reflectScrolledClipView(scroll.contentView)
        let originBefore = scroll.contentView.bounds.origin.y
        let mid = (reading.attributed.string as NSString).range(of: "Paragraph 20").location
        XCTAssertNotNil(coordinator.lineScreenY(at: mid, in: textView))
        // A caret already on screen must not move the viewport at all.
        if let y = coordinator.lineScreenY(at: mid, in: textView), y >= 8, y <= 392 {
            coordinator.scrollCaretIntoViewIfNeeded(mid, in: textView)
            XCTAssertEqual(scroll.contentView.bounds.origin.y, originBefore, accuracy: 0.5,
                           "visible caret must not scroll the viewport")
        }
        // A caret far below the fold scrolls minimally (bottom-aligned).
        let deep = (reading.attributed.string as NSString).range(of: "Paragraph 45").location
        coordinator.scrollCaretIntoViewIfNeeded(deep, in: textView)
        let after = try XCTUnwrap(coordinator.lineScreenY(at: deep, in: textView))
        XCTAssertGreaterThan(after, 0)
        XCTAssertLessThan(after, 400, "off-screen caret must come into view")
    }
}
#endif
