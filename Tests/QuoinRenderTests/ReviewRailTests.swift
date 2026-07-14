#if canImport(AppKit)
import XCTest
import AppKit
import QuoinCore
@testable import QuoinRender

/// The review rail (suggestions S2c): cards compose from marks + metadata,
/// anchor to their marks' lines, stack without overlap, resolve through the
/// same callback as the context menu, and link to the caret's mark.
@MainActor
final class ReviewRailTests: XCTestCase {

    private let source = """
    # Doc

    First paragraph with a tracked {++insertion++}{#s1} here.

    Filler line one.

    Filler line two.

    Please revisit {==this sentence==}{>>Needs a source.<<}{#c1} soon.

    ---
    comments:
      c1: { by: user, at: "2026-04-28T12:00:00Z" }
      c2:
        body: "I can add one."
        by: AI
        at: "2026-04-28T12:05:00Z"
        re: c1
    suggestions:
      s1: { by: AI, at: "2026-04-28T12:01:00Z" }

    """

    private func makeStack() throws -> (
        textView: QuoinTextView, coordinator: MarkdownReaderView.Coordinator,
        window: NSWindow, resolved: () -> [(ByteRange, SuggestionResolver.Action)]
    ) {
        let document = MarkdownConverter.parse(source)
        let renderer = AttributedRenderer()
        var cache: [BlockID: NSAttributedString] = [:]
        let rendered = renderer.render(document, activeBlockID: nil, activeCaret: nil, cache: &cache)

        let contentStorage = NSTextContentStorage()
        let layoutManager = NSTextLayoutManager()
        contentStorage.addTextLayoutManager(layoutManager)
        let container = NSTextContainer(size: NSSize(width: 1080, height: CGFloat.greatestFiniteMagnitude))
        container.widthTracksTextView = true
        layoutManager.textContainer = container
        let textView = QuoinTextView(frame: NSRect(x: 0, y: 0, width: 1080, height: 0), textContainer: container)
        textView.isVerticallyResizable = true
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 1080, height: 500))
        scroll.documentView = textView
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1080, height: 500),
            styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = scroll
        textView.textContentStorage?.textStorage?.setAttributedString(rendered.attributed)
        textView.textLayoutManager?.ensureLayout(
            for: try XCTUnwrap(textView.textContentStorage?.documentRange))
        textView.sizeToFit()

        var resolved: [(ByteRange, SuggestionResolver.Action)] = []
        let view = MarkdownReaderView(
            rendered: RenderedDocument(attributed: rendered.attributed, blockRanges: rendered.blockRanges),
            onSuggestionAction: { range, action in resolved.append((range, action)) },
            reviewItems: SuggestionResolver.reviewItems(in: document))
        let coordinator = MarkdownReaderView.Coordinator(parent: view)
        coordinator.textView = textView
        return (textView, coordinator, window, { resolved })
    }

    func testItemsComposeWithMetadataAnchorsAndThreads() throws {
        let document = MarkdownConverter.parse(source)
        let items = SuggestionResolver.reviewItems(in: document)
        XCTAssertEqual(items.count, 2, "insertion + anchored comment (highlight absorbed)")

        guard case .insertion(let text) = items[0].body else { return XCTFail("insertion first") }
        XCTAssertEqual(text, "insertion")
        XCTAssertEqual(items[0].by, "AI")
        XCTAssertTrue(items[0].isSuggestion)

        guard case .comment(let comment, let anchor) = items[1].body else { return XCTFail("comment") }
        XCTAssertEqual(comment, "Needs a source.")
        XCTAssertEqual(anchor, "this sentence", "anchored comment absorbs its highlight")
        XCTAssertEqual(items[1].by, "user")
        XCTAssertEqual(items[1].replies.count, 1, "endmatter reply threads in")
        XCTAssertEqual(items[1].replies[0].body, "I can add one.")
        XCTAssertFalse(items[1].isSuggestion)
    }

    func testRailBuildsAnchoredNonOverlappingCards() throws {
        let (textView, coordinator, window, _) = try makeStack()
        defer { window.orderOut(nil) }

        coordinator.updateReviewRail(in: textView)
        let rail = try XCTUnwrap(coordinator.reviewRail, "marks + wide window → rail")
        let cards = rail.subviews.compactMap { $0 as? ReviewCardView }
        XCTAssertEqual(cards.count, 2)

        // Cards are in document order, top-anchored, and never overlap.
        let sorted = cards.sorted { $0.frame.minY < $1.frame.minY }
        XCTAssertLessThan(sorted[0].frame.maxY, sorted[1].frame.minY,
                          "stacking pushes the second card below the first")
        // The second card anchors at (or below) its mark's line — which is
        // several paragraphs down.
        XCTAssertGreaterThan(sorted[1].frame.minY, 60)

        // The rail sits in the right margin.
        XCTAssertGreaterThan(rail.frame.minX, textView.bounds.width / 2)
    }

    func testCardButtonsRouteToTheResolveCallback() throws {
        let (textView, coordinator, window, resolved) = try makeStack()
        defer { window.orderOut(nil) }
        coordinator.updateReviewRail(in: textView)
        let rail = try XCTUnwrap(coordinator.reviewRail)
        let cards = rail.subviews.compactMap { $0 as? ReviewCardView }
        let suggestion = try XCTUnwrap(cards.first { $0.item.isSuggestion })

        // Press ✓ via the accessibility action (same path as a click).
        let capsules = suggestion.subviews.compactMap { $0 as? CapsuleButton }
        XCTAssertEqual(capsules.count, 2, "suggestion card: Accept + Reject")
        XCTAssertTrue(capsules[0].accessibilityPerformPress())
        XCTAssertEqual(resolved().count, 1)
        XCTAssertEqual(resolved()[0].0, suggestion.item.markRange)

        // Comment card carries a single Dismiss.
        let comment = try XCTUnwrap(cards.first { !$0.item.isSuggestion })
        let dismiss = comment.subviews.compactMap { $0 as? CapsuleButton }
        XCTAssertEqual(dismiss.count, 1)
    }

    func testCaretInMarkLinksItsCard() throws {
        let (textView, coordinator, window, _) = try makeStack()
        defer { window.orderOut(nil) }
        coordinator.updateReviewRail(in: textView)
        let rail = try XCTUnwrap(coordinator.reviewRail)
        let storage = try XCTUnwrap(textView.textContentStorage?.textStorage)

        // Put the caret inside the rendered insertion.
        let at = (storage.string as NSString).range(of: "insertion").location
        XCTAssertNotEqual(at, NSNotFound)
        textView.setSelectedRange(NSRange(location: at + 2, length: 0))
        coordinator.updateReviewLinkage(in: textView)
        XCTAssertNotNil(rail.linkedRange, "caret inside a mark links its card")

        // Caret in plain prose clears the link.
        let plain = (storage.string as NSString).range(of: "Filler line one").location
        textView.setSelectedRange(NSRange(location: plain, length: 0))
        coordinator.updateReviewLinkage(in: textView)
        XCTAssertNil(rail.linkedRange)
    }

    func testNarrowWindowCollapsesTheRail() throws {
        let (textView, coordinator, window, _) = try makeStack()
        defer { window.orderOut(nil) }
        coordinator.updateReviewRail(in: textView)
        XCTAssertNotNil(coordinator.reviewRail)
        // Shrink below the threshold: the rail collapses entirely.
        window.setContentSize(NSSize(width: 700, height: 500))
        textView.enclosingScrollView?.frame = NSRect(x: 0, y: 0, width: 700, height: 500)
        coordinator.updateReviewRail(in: textView)
        XCTAssertNil(coordinator.reviewRail, "narrow window → zero rail footprint")
    }
}
#endif
