import XCTest
@testable import QuoinCore

final class ZQVerifyNewlineSummaryTests: XCTestCase {

    func testMultilineDeletionMarkIsParsedAsOneSuggestion() {
        let source = "Hello {--old\ntext--} world.\n"
        let document = MarkdownConverter.parse(source)
        let marks = SuggestionResolver.marks(in: document)
        print("VERIFY marks.count = \(marks.count)")
        for m in marks { print("VERIFY mark kind=\(m.kind) range=\(m.range) id=\(String(describing: m.id))") }
        XCTAssertEqual(marks.count, 1)
    }

    func testResolvingMultilineMarkCorruptsEndmatter() {
        let source = "Hello {--old\ntext--} world.\n"
        let document = MarkdownConverter.parse(source)
        guard let mark = SuggestionResolver.marks(in: document).first else {
            XCTFail("no mark parsed"); return
        }
        let summary = SuggestionResolver.resolutionSummary(
            at: mark.range, in: source, action: .accept)
        print("VERIFY summary = \(String(describing: summary).debugDescription)")

        guard let edit = SuggestionResolver.combinedResolutionEdit(
            resolving: mark.range, in: source, action: .accept) else {
            XCTFail("no combined edit"); return
        }
        var bytes = Array(source.utf8)
        bytes.replaceSubrange(
            edit.range.offset..<(edit.range.offset + edit.range.length),
            with: Array(edit.replacement.utf8))
        let after = String(decoding: bytes, as: UTF8.self)
        print("VERIFY after-resolution source:\n\(after.debugDescription)")

        let detected = ReviewEndmatter.detect(in: after)
        print("VERIFY detect = \(String(describing: detected != nil ? "DETECTED" : "NIL"))")
        // The finding claims detection FAILS (nil). If nil, next resolution appends a second endmatter.
        if detected == nil {
            // Simulate the next resolution appending a second block.
            let second = ReviewEndmatter.appendedRecordEdit(
                summary: "second", asComment: false, in: after)
            print("VERIFY second appendedRecordEdit offset=\(String(describing: second?.range)) replacement=\(String(describing: second?.replacement.debugDescription))")
        }
        XCTAssertNil(detected, "finding claims detection fails after newline summary")
    }
}
