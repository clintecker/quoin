import XCTest
@testable import QuoinCore

/// Accept/reject byte semantics + RDFM endmatter metadata (suggestions
/// design, S2). Resolution is exact bytes — no whitespace normalization —
/// verified against the CriticMarkup toolkit consensus table.
final class SuggestionResolutionTests: XCTestCase {

    private func resolved(_ source: String, action: SuggestionResolver.Action) -> String {
        let document = MarkdownConverter.parse(source)
        let marks = SuggestionResolver.marks(in: document)
        var result = source
        // Right-to-left so earlier offsets stay valid.
        for mark in marks.reversed() {
            guard let edit = SuggestionResolver.edit(
                resolving: mark.range, in: result, action: action) else { continue }
            var bytes = Array(result.utf8)
            bytes.replaceSubrange(
                edit.range.offset..<(edit.range.offset + edit.range.length),
                with: Array(edit.replacement.utf8))
            result = String(decoding: bytes, as: UTF8.self)
        }
        return result
    }

    // MARK: - Byte semantics (the consensus table)

    func testAcceptSemantics() {
        XCTAssertEqual(resolved("A{++ new++} text.\n", action: .accept), "A new text.\n")
        XCTAssertEqual(resolved("A{-- old--} text.\n", action: .accept), "A text.\n")
        XCTAssertEqual(resolved("We {~~cannot~>can~~} go.\n", action: .accept), "We can go.\n")
        XCTAssertEqual(resolved("X {>>note<<} y.\n", action: .accept), "X  y.\n",
                       "comments are annotations: removed, bytes otherwise exact")
        XCTAssertEqual(resolved("X {==flag==} y.\n", action: .accept), "X flag y.\n",
                       "highlights unwrap — the text was never in question")
    }

    func testRejectSemantics() {
        XCTAssertEqual(resolved("A{++ new++} text.\n", action: .reject), "A text.\n")
        XCTAssertEqual(resolved("A{-- old--} text.\n", action: .reject), "A old text.\n")
        XCTAssertEqual(resolved("We {~~cannot~>can~~} go.\n", action: .reject), "We cannot go.\n")
        XCTAssertEqual(resolved("X {>>note<<} y.\n", action: .reject), "X  y.\n")
        XCTAssertEqual(resolved("X {==flag==} y.\n", action: .reject), "X flag y.\n")
    }

    func testResolutionRemovesTheIdReference() {
        XCTAssertEqual(resolved("A {++change++}{#s1} here.\n", action: .accept),
                       "A change here.\n",
                       "the {#id} is part of the mark's range and goes with it")
    }

    func testStaleRangeRefusesInsteadOfSplicingBlind() {
        let source = "A {++change++} here.\n"
        let document = MarkdownConverter.parse(source)
        let mark = SuggestionResolver.marks(in: document)[0]
        // The document changed since the projection: bytes at that range are
        // no longer exactly one whole mark.
        let drifted = "AB {++change++} here.\n"
        XCTAssertNil(SuggestionResolver.edit(resolving: mark.range, in: drifted, action: .accept))
    }

    func testMarksWalkFindsNestedContainers() {
        let source = "> Quoted {++insert++} text.\n\n- item with {--strike--}\n"
        let document = MarkdownConverter.parse(source)
        XCTAssertEqual(SuggestionResolver.marks(in: document).count, 2)
    }

    // MARK: - RDFM endmatter

    private let endmatterDoc = """
    # Doc

    Please revisit {==this==}{>>Needs a source.<<}{#c1} soon.

    A tracked {++change++}{#s1} too.

    ---
    comments:
      c1: { by: user, at: "2026-04-28T12:00:00Z" }
      c2:
        body: "I can add one from the intro."
        by: AI
        at: "2026-04-28T12:05:00Z"
        re: c1
    suggestions:
      s1: { by: AI, at: "2026-04-28T12:01:00Z" }

    """

    func testEndmatterParsesAndAttachesMetadata() throws {
        let document = MarkdownConverter.parse(endmatterDoc)
        let metadata = try XCTUnwrap(document.reviewMetadata)
        XCTAssertEqual(metadata.comments["c1"]?.by, "user")
        XCTAssertEqual(metadata.comments["c2"]?.re, "c1")
        XCTAssertEqual(metadata.comments["c2"]?.body, "I can add one from the intro.")
        XCTAssertEqual(metadata.suggestions["s1"]?.by, "AI")
        XCTAssertEqual(metadata.suggestions["s1"]?.at, "2026-04-28T12:01:00Z")

        // The endmatter renders as its own chip block, and the body's marks
        // still parse (the endmatter never reaches cmark).
        XCTAssertTrue(document.blocks.contains {
            if case .reviewEndmatter = $0.kind { return true }
            return false
        })
        XCTAssertEqual(document.stats.suggestionCount, 3)
        // Byte-lossless: the source is untouched.
        XCTAssertEqual(document.source, endmatterDoc)
    }

    func testEndmatterBlockRangeCoversTheTail() throws {
        let document = MarkdownConverter.parse(endmatterDoc)
        let block = try XCTUnwrap(document.blocks.first {
            if case .reviewEndmatter = $0.kind { return true }
            return false
        })
        let bytes = Array(endmatterDoc.utf8)
        let slice = String(decoding: bytes[block.range.offset...], as: UTF8.self)
        XCTAssertTrue(slice.hasPrefix("\n---\n"), "the range includes the delimiter")
        XCTAssertEqual(block.range.offset + block.range.length, bytes.count)
    }

    func testOrdinaryTrailingHRuleIsNotEndmatter() {
        // No {#id} in the body, no document-level comment → a plain hrule +
        // list stays ordinary content.
        let document = MarkdownConverter.parse("Body text.\n\n---\ncomments below are prose\n")
        XCTAssertNil(document.reviewMetadata)
        // And a document that merely ENDS with a thematic break.
        XCTAssertNil(MarkdownConverter.parse("Text.\n\n---\n").reviewMetadata)
    }

    func testDocumentLevelCommentNeedsNoBodyReference() throws {
        let source = "Just prose.\n\n---\ncomments:\n  c1:\n    body: \"Overall: tighten the intro.\"\n    by: AI\n"
        let metadata = try XCTUnwrap(MarkdownConverter.parse(source).reviewMetadata)
        XCTAssertEqual(metadata.comments["c1"]?.body, "Overall: tighten the intro.")
    }
}
