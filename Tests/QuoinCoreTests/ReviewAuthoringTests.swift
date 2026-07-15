import XCTest
@testable import QuoinCore

/// Creating a review without editing the prose (suggestions §3.6, S3a):
/// every gesture is ONE atomic edit, the prose survives byte-exactly
/// inside the mark, and impossible annotations REFUSE.
final class ReviewAuthoringTests: XCTestCase {

    private let stamp = "2026-07-14T18:00:00Z"

    private func applying(_ edit: SourceEdit, to source: String) -> String {
        var bytes = Array(source.utf8)
        bytes.replaceSubrange(
            edit.range.offset..<(edit.range.offset + edit.range.length),
            with: Array(edit.replacement.utf8))
        return String(decoding: bytes, as: UTF8.self)
    }

    private func range(of text: String, in source: String) -> ByteRange {
        let bytes = Array(source.utf8)
        let needle = Array(text.utf8)
        for start in 0...(bytes.count - needle.count)
        where Array(bytes[start..<(start + needle.count)]) == needle {
            return ByteRange(offset: start, length: needle.count)
        }
        XCTFail("\(text) not in source")
        return ByteRange(offset: 0, length: 0)
    }

    // MARK: - Shapes

    func testDeletionWrapsTheProseByteExactly() throws {
        let source = "The quick brown fox jumps.\n"
        let edit = try XCTUnwrap(ReviewAuthoring.annotationEdit(
            kind: .deletion, range: range(of: "quick ", in: source),
            in: source, reviewer: "clint", timestamp: stamp))
        let after = applying(edit, to: source)
        XCTAssertTrue(after.hasPrefix("The {--quick --}{#s1}brown fox jumps.\n"),
                      "prose unchanged inside the mark: \(after)")
        XCTAssertTrue(after.contains("suggestions:\n  s1:\n    by: clint\n    at: \"\(stamp)\""))

        // The document still SAYS the same thing: rejecting restores bytes.
        let doc = MarkdownConverter.parse(after)
        let mark = try XCTUnwrap(SuggestionResolver.marks(in: doc).first)
        let reject = try XCTUnwrap(SuggestionResolver.edit(
            resolving: mark.range, in: after, action: .reject))
        XCTAssertTrue(applying(reject, to: after).hasPrefix(source.dropLast()),
                      "reject = the original prose, byte-exact")
    }

    func testReplacementAndHighlightAndInsertionShapes() throws {
        let source = "Alpha beta gamma.\n"
        let replace = try XCTUnwrap(ReviewAuthoring.annotationEdit(
            kind: .replacement(new: "delta"), range: range(of: "beta", in: source),
            in: source, reviewer: "AI", timestamp: stamp))
        XCTAssertTrue(applying(replace, to: source).contains("{~~beta~>delta~~}{#s1}"))

        let highlight = try XCTUnwrap(ReviewAuthoring.annotationEdit(
            kind: .highlight, range: range(of: "gamma", in: source),
            in: source, reviewer: "clint", timestamp: stamp))
        XCTAssertTrue(applying(highlight, to: source).contains("{==gamma==}{#s1}"))

        let insert = try XCTUnwrap(ReviewAuthoring.annotationEdit(
            kind: .insertion(text: "really "),
            range: ByteRange(offset: range(of: "beta", in: source).offset, length: 0),
            in: source, reviewer: "clint", timestamp: stamp))
        XCTAssertTrue(applying(insert, to: source).contains("Alpha {++really ++}{#s1}beta"))
    }

    func testAnchoredCommentIsOnePanelCard() throws {
        let source = "Check the numbers here.\n"
        let edit = try XCTUnwrap(ReviewAuthoring.annotationEdit(
            kind: .comment(body: "Source for these?"), range: range(of: "the numbers", in: source),
            in: source, reviewer: "clint", timestamp: stamp))
        let after = applying(edit, to: source)
        XCTAssertTrue(after.contains("{==the numbers==}{>>Source for these?<<}{#c1}"))
        let items = SuggestionResolver.reviewItems(in: MarkdownConverter.parse(after))
        XCTAssertEqual(items.count, 1, "highlight + comment fuse into ONE card")
        guard case .comment(let text, let anchor) = items[0].body else {
            return XCTFail("expected comment card")
        }
        XCTAssertEqual(text, "Source for these?")
        XCTAssertEqual(anchor, "the numbers")
        XCTAssertEqual(items[0].by, "clint")
    }

    func testDocumentLevelCommentIsEndmatterOnly() throws {
        let source = "Just prose.\n"
        let edit = try XCTUnwrap(ReviewAuthoring.annotationEdit(
            kind: .comment(body: "Overall: tighten."), range: ByteRange(offset: 0, length: 0),
            in: source, reviewer: "AI", timestamp: stamp))
        let after = applying(edit, to: source)
        XCTAssertTrue(after.hasPrefix("Just prose.\n"), "prose untouched")
        let metadata = try XCTUnwrap(MarkdownConverter.parse(after).reviewMetadata)
        XCTAssertEqual(metadata.comments["c1"]?.body, "Overall: tighten.")
        XCTAssertEqual(metadata.comments["c1"]?.by, "AI")
    }

    // MARK: - Atomicity + id allocation

    func testAnnotationIsOneUndoThroughTheRealSession() async throws {
        let source = "Alpha beta gamma.\n"
        let session = DocumentSession(source: source, fileURL: nil)
        let result = try await session.applyAnnotation(
            kind: .deletion, range: range(of: "beta ", in: source),
            expectedSlice: "beta ", reviewer: "clint")
        XCTAssertNotNil(result)
        XCTAssertTrue(result!.source.contains("{--beta --}{#s1}"))
        let restored = try await session.undo()
        XCTAssertEqual(restored?.source, source, "one ⌘Z removes mark AND entry")
        let empty = try await session.undo()
        XCTAssertNil(empty)
    }

    func testIdsAllocateAcrossExistingMarksAndEntries() throws {
        let source = "One {++x++}{#s1} two three.\n\n---\nsuggestions:\n  s1: { by: AI }\n  s2: { by: AI, status: resolved, resolved: \"accepted · y\" }\n"
        let edit = try XCTUnwrap(ReviewAuthoring.annotationEdit(
            kind: .deletion, range: range(of: "two ", in: source),
            in: source, reviewer: "clint", timestamp: stamp))
        let after = applying(edit, to: source)
        XCTAssertTrue(after.contains("{--two --}{#s3}"), "s1/s2 taken → s3: \(after)")
        XCTAssertEqual(MarkdownConverter.parse(after).reviewMetadata?.suggestions.count, 3)
    }

    // MARK: - Refusals (self-calibration)

    func testSelectionInsideACodeSpanRefuses() {
        let source = "Run `swift build now` first.\n"
        XCTAssertNil(ReviewAuthoring.annotationEdit(
            kind: .deletion, range: range(of: "build", in: source),
            in: source, reviewer: "clint", timestamp: stamp),
            "a mark inside a code span would be literal text — refuse")
    }

    func testBlockSpanningSelectionRefuses() {
        let source = "First paragraph.\n\nSecond paragraph.\n"
        let start = range(of: "paragraph.\n\nSecond", in: source)
        XCTAssertNil(ReviewAuthoring.annotationEdit(
            kind: .deletion, range: start,
            in: source, reviewer: "clint", timestamp: stamp),
            "marks are intra-block in v1 — refuse")
    }

    func testSelectionContainingAClosingSigilRefuses() {
        let source = "Odd text with a --} stray closer.\n"
        XCTAssertNil(ReviewAuthoring.annotationEdit(
            kind: .deletion, range: range(of: "a --} stray", in: source),
            in: source, reviewer: "clint", timestamp: stamp),
            "the early close would detach the id — refuse, never mangle")
    }

    func testSelectionOverAnExistingMarkRefuses() {
        let source = "Keep {++this++}{#s1} mark.\n"
        XCTAssertNil(ReviewAuthoring.annotationEdit(
            kind: .highlight, range: range(of: "{++this++}", in: source),
            in: source, reviewer: "clint", timestamp: stamp),
            "no nested marks in v1")
    }

    func testDriftRefusesThroughTheSession() async throws {
        let source = "Alpha beta gamma.\n"
        let session = DocumentSession(source: source, fileURL: nil)
        // The gesture was made against "beta" but the document changed.
        try await session.applyEdit(SourceEdit(
            range: ByteRange(offset: 0, length: 0), replacement: "X"))
        let result = try await session.applyAnnotation(
            kind: .deletion, range: range(of: "beta", in: source),
            expectedSlice: "beta", reviewer: "clint")
        XCTAssertNil(result, "bytes drifted under the gesture — refuse")
        let current = await session.document.source
        XCTAssertEqual(current, "XAlpha beta gamma.\n", "nothing spliced")
    }

    func testEmptyCommentBodyRefuses() {
        let source = "Some prose.\n"
        XCTAssertNil(ReviewAuthoring.annotationEdit(
            kind: .comment(body: "   \n  "), range: range(of: "prose", in: source),
            in: source, reviewer: "clint", timestamp: stamp))
    }

    func testMultiLineBodyFlattensToOneLine() throws {
        let source = "Some prose here.\n"
        let edit = try XCTUnwrap(ReviewAuthoring.annotationEdit(
            kind: .comment(body: "line one\nline two"), range: range(of: "prose", in: source),
            in: source, reviewer: "clint", timestamp: stamp))
        let after = applying(edit, to: source)
        XCTAssertTrue(after.contains("{>>line one line two<<}"))
        XCTAssertNotNil(ReviewEndmatter.detect(in: after))
    }

    // MARK: - Structure preservation (live report: list renumbered)

    func testCommentWrappingAListMarkerRefuses() throws {
        let source = """
        Intro.

        1. Name the player problem.
        2. Identify the rule IDs.
        3. Update Gameplay.

        Tail.
        """
        // The whole-item selection INCLUDING the "2. " marker: wrapping it
        // erased the marker and restructured the list (renumbering every
        // item) — an annotation must never change document structure.
        XCTAssertNil(ReviewAuthoring.annotationEdit(
            kind: .comment(body: "nice"), range: range(of: "2. Identify the rule IDs.", in: source),
            in: source, reviewer: "clint", timestamp: stamp))
    }

    func testCommentOnItemContentSucceedsAndKeepsTheList() throws {
        let source = """
        Intro.

        1. Name the player problem.
        2. Identify the rule IDs.
        3. Update Gameplay.

        Tail.
        """
        let edit = try XCTUnwrap(ReviewAuthoring.annotationEdit(
            kind: .comment(body: "nice"), range: range(of: "Identify the rule IDs.", in: source),
            in: source, reviewer: "clint", timestamp: stamp))
        let after = applying(edit, to: source)
        let document = MarkdownConverter.parse(after)
        let list = document.blocks.compactMap { block -> Int? in
            if case .list(let items, _, _) = block.kind { return items.count }
            return nil
        }
        XCTAssertEqual(list, [3], "the list survives intact: \(after)")
        XCTAssertEqual(SuggestionResolver.reviewItems(in: document).count, 1)
    }

    func testClampPastLinePrefix() {
        XCTAssertEqual(ReviewAuthoring.clampPastLinePrefix(0, in: "2. Item text"), 3)
        XCTAssertEqual(ReviewAuthoring.clampPastLinePrefix(0, in: "- item"), 2)
        XCTAssertEqual(ReviewAuthoring.clampPastLinePrefix(2, in: "  - [x] task item"), 8)
        XCTAssertEqual(ReviewAuthoring.clampPastLinePrefix(0, in: "> quoted text"), 2)
        XCTAssertEqual(ReviewAuthoring.clampPastLinePrefix(5, in: "plain prose"), 5,
                       "content positions pass through untouched")
        // Second line of a list slice: clamp is line-local.
        let slice = "- one\n- two"
        XCTAssertEqual(ReviewAuthoring.clampPastLinePrefix(6, in: slice), 8)
    }

}
