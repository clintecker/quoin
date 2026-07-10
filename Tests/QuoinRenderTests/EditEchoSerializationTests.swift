#if canImport(AppKit)
import XCTest
import AppKit
import QuoinCore
@testable import QuoinRender

/// Ledger #11 — fast typing raced the edit round-trip: a keystroke
/// arriving before the previous edit's projection echo computed its range
/// against STALE coordinates and scrambled into neighboring text (field
/// report: "edits swallowed in the source, persisted forever in the
/// chart" — a relationship label reading 'containsininnao'). Keystrokes
/// arriving mid-flight must QUEUE, in order, and flush one per echo at
/// the freshly restored caret — never against stale offsets.
final class EditEchoSerializationTests: XCTestCase {

    private struct SentEdit {
        let range: ByteRange
        let text: String
    }

    private func makeHarness() throws -> (
        coordinator: MarkdownReaderView.Coordinator,
        textView: QuoinTextView,
        sent: () -> [SentEdit]
    ) {
        let source = "# T\n\n```mermaid\nflowchart TD\n    A --> B\n```\n\nTail.\n"
        let document = MarkdownConverter.parse(source)
        let block = try XCTUnwrap(document.blocks.first {
            if case .mermaid = $0.kind { return true }
            return false
        })
        let renderer = AttributedRenderer()
        var cache: [BlockID: NSAttributedString] = [:]
        let editing = renderer.render(document, activeBlockID: block.id, activeCaret: 0, cache: &cache)

        let contentStorage = NSTextContentStorage()
        let layoutManager = NSTextLayoutManager()
        contentStorage.addTextLayoutManager(layoutManager)
        let container = NSTextContainer(size: NSSize(width: 700, height: CGFloat.greatestFiniteMagnitude))
        layoutManager.textContainer = container
        let textView = QuoinTextView(frame: NSRect(x: 0, y: 0, width: 700, height: 400), textContainer: container)
        textView.textContentStorage?.textStorage?.setAttributedString(editing.attributed)

        final class Box { var edits: [SentEdit] = [] }
        let box = Box()
        let view = MarkdownReaderView(
            rendered: RenderedDocument(
                attributed: editing.attributed, blockRanges: editing.blockRanges,
                activeBlockID: block.id, activeEditableRange: editing.activeEditableRange,
                activeSourceText: editing.activeSourceText),
            onEditIntent: { range, text, _ in box.edits.append(SentEdit(range: range, text: text)) },
            onActivateBlock: { _, _, _ in }
        )
        let coordinator = MarkdownReaderView.Coordinator(parent: view)
        coordinator.textView = textView
        coordinator.blockRanges = editing.blockRanges
        return (coordinator, textView, { box.edits })
    }

    func testMidFlightKeystrokesQueueAndFlushInOrder() throws {
        let (coordinator, textView, sent) = try makeHarness()
        let active = try XCTUnwrap(coordinator.parent.rendered.activeEditableRange)
        let caret = active.location + 12
        textView.setSelectedRange(NSRange(location: caret, length: 0))

        // Keystroke 1 goes straight through and opens the flight window.
        _ = coordinator.textView(
            textView, shouldChangeTextIn: NSRange(location: caret, length: 0),
            replacementString: "a")
        XCTAssertEqual(sent().count, 1)

        // Keystrokes 2 and 3 arrive BEFORE the echo: they must queue —
        // computing their ranges now would use stale coordinates (the
        // scrambled-label field report).
        _ = coordinator.textView(
            textView, shouldChangeTextIn: NSRange(location: caret, length: 0),
            replacementString: "b")
        _ = coordinator.textView(
            textView, shouldChangeTextIn: NSRange(location: caret, length: 0),
            replacementString: "c")
        XCTAssertEqual(sent().count, 1, "mid-flight keystrokes never apply against stale ranges")

        // Echo 1 lands (caret restored one to the right): keystroke 2
        // flushes at the FRESH caret.
        textView.setSelectedRange(NSRange(location: caret + 1, length: 0))
        coordinator.noteEditEchoApplied(in: textView)
        XCTAssertEqual(sent().count, 2)
        XCTAssertEqual(sent()[1].text, "b")
        XCTAssertEqual(sent()[1].range.offset, sent()[0].range.offset + 1,
                       "queued keystroke applies at the restored caret, not the stale one")

        // Echo 2 → keystroke 3, one per ack, in order.
        textView.setSelectedRange(NSRange(location: caret + 2, length: 0))
        coordinator.noteEditEchoApplied(in: textView)
        XCTAssertEqual(sent().count, 3)
        XCTAssertEqual(sent()[2].text, "c")
        XCTAssertEqual(sent()[2].range.offset, sent()[0].range.offset + 2)

        // Queue drained; the next echo flushes nothing.
        coordinator.noteEditEchoApplied(in: textView)
        XCTAssertEqual(sent().count, 3)
    }

    func testBackspaceQueuesMidFlight() throws {
        let (coordinator, textView, sent) = try makeHarness()
        let active = try XCTUnwrap(coordinator.parent.rendered.activeEditableRange)
        let caret = active.location + 12
        textView.setSelectedRange(NSRange(location: caret, length: 0))

        _ = coordinator.textView(
            textView, shouldChangeTextIn: NSRange(location: caret, length: 0),
            replacementString: "x")
        _ = coordinator.textView(
            textView, shouldChangeTextIn: NSRange(location: caret - 1, length: 1),
            replacementString: "")
        XCTAssertEqual(sent().count, 1, "backspace queues like any keystroke")

        textView.setSelectedRange(NSRange(location: caret + 1, length: 0))
        coordinator.noteEditEchoApplied(in: textView)
        XCTAssertEqual(sent().count, 2)
        XCTAssertEqual(sent()[1].text, "", "the queued backspace deletes at the fresh caret")
    }

    func testActivationChangeDropsTheQueue() throws {
        let (coordinator, textView, sent) = try makeHarness()
        let active = try XCTUnwrap(coordinator.parent.rendered.activeEditableRange)
        textView.setSelectedRange(NSRange(location: active.location + 3, length: 0))
        _ = coordinator.textView(
            textView, shouldChangeTextIn: NSRange(location: active.location + 3, length: 0),
            replacementString: "a")
        _ = coordinator.textView(
            textView, shouldChangeTextIn: NSRange(location: active.location + 3, length: 0),
            replacementString: "b")
        coordinator.clearPendingKeystrokes()
        coordinator.noteEditEchoApplied(in: textView)
        XCTAssertEqual(sent().count, 1, "a flip invalidates queued positions entirely")
    }
}
#endif
