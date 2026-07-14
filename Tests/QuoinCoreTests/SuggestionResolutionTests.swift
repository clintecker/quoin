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

// MARK: - Endmatter maintenance (redlined 2026-07-14: the YAML-leak bug)

extension SuggestionResolutionTests {

    private var maintained: String {
        """
        Body {++alpha++}{#s1} and {>>note<<}{#c1} here.

        ---
        comments:
          c1: { by: user, at: "2026-04-28T12:00:00Z" }
          c2:
            body: "A reply."
            by: AI
            re: c1
        suggestions:
          s1: { by: AI, at: "2026-04-28T12:01:00Z" }

        """
    }

    private func applying(_ edit: SourceEdit, to source: String) -> String {
        var bytes = Array(source.utf8)
        bytes.replaceSubrange(
            edit.range.offset..<(edit.range.offset + edit.range.length),
            with: Array(edit.replacement.utf8))
        return String(decoding: bytes, as: UTF8.self)
    }

    func testResolvingRemovesTheEntryAndKeepsOthersByteExact() throws {
        let edit = try XCTUnwrap(ReviewEndmatter.maintenanceEdit(afterResolving: "s1", in: maintained))
        let after = applying(edit, to: maintained)
        XCTAssertFalse(after.contains("s1:"))
        XCTAssertFalse(after.contains("suggestions:"), "emptied section header goes too")
        XCTAssertTrue(after.contains("c1: { by: user, at: \"2026-04-28T12:00:00Z\" }"),
                      "surviving entries keep their original lines byte-exactly")
        XCTAssertTrue(after.contains("body: \"A reply.\""))
        // The endmatter still detects afterward (c1's ref remains in body).
        XCTAssertNotNil(MarkdownConverter.parse(after).reviewMetadata)
    }

    func testResolvingRemovesReplyThreadTransitively() throws {
        let edit = try XCTUnwrap(ReviewEndmatter.maintenanceEdit(afterResolving: "c1", in: maintained))
        let after = applying(edit, to: maintained)
        XCTAssertFalse(after.contains("c1:"))
        XCTAssertFalse(after.contains("A reply."), "re: c1 goes with its parent")
        XCTAssertTrue(after.contains("s1:"), "unrelated entries survive")
    }

    func testResolvingTheLastEntryRemovesTheWholeEndmatter() throws {
        // The live bug: after dismissing the only referenced comment, the
        // orphaned endmatter leaked into the prose as a YAML paragraph.
        let source = """
        Body {>>only note<<}{#c1} here.

        ---
        comments:
          c1: { by: user, at: "2026-04-28T12:00:00Z" }

        """
        let edit = try XCTUnwrap(ReviewEndmatter.maintenanceEdit(afterResolving: "c1", in: source))
        let after = applying(edit, to: source)
        XCTAssertFalse(after.contains("---"))
        XCTAssertFalse(after.contains("comments:"), "no YAML soup left behind")
        XCTAssertTrue(after.hasPrefix("Body"))
    }

    func testMarkWithoutIdLeavesEndmatterAlone() throws {
        let source = "Body {++plain++} here.\n\n---\ncomments:\n  c1: { by: user }\n"
        XCTAssertNil(ReviewEndmatter.maintenanceEdit(afterResolving: "nope", in: source))
    }
}

// MARK: - Resolution records (history — "acted-on things just disappear")

extension SuggestionResolutionTests {

    func testResolutionRecordKeepsTheEntryWithStatusAndSummary() throws {
        let edit = try XCTUnwrap(ReviewEndmatter.resolutionRecordEdit(
            resolving: "s1", summary: "accepted · alpha", in: maintained))
        let after = applying(edit, to: maintained)
        // The flow-form entry normalizes to block form and gains the record.
        XCTAssertTrue(after.contains("  s1:"))
        XCTAssertTrue(after.contains("    by: AI"))
        XCTAssertTrue(after.contains("    status: resolved"))
        XCTAssertTrue(after.contains("    resolved: \"accepted · alpha\""))
        // Other entries keep their original lines byte-exactly.
        XCTAssertTrue(after.contains("c1: { by: user, at: \"2026-04-28T12:00:00Z\" }"))
        XCTAssertTrue(after.contains("body: \"A reply.\""))
        // The entry reads back with the record fields. (It does NOT show
        // as history yet — the mark is still live in this test, and the
        // mark wins; combinedResolutionEdit's test covers the full flow.)
        let metadata = try XCTUnwrap(MarkdownConverter.parse(after).reviewMetadata)
        XCTAssertEqual(metadata.suggestions["s1"]?.status, "resolved")
        XCTAssertEqual(metadata.suggestions["s1"]?.resolved, "accepted · alpha")
        XCTAssertEqual(metadata.suggestions["s1"]?.by, "AI")
        XCTAssertTrue(ReviewEndmatter.resolvedRecords(in: MarkdownConverter.parse(after)).isEmpty)
    }

    func testEndmatterSurvivesResolvingTheLastReferencedMark() throws {
        // The history version of the YAML-leak scenario: record the only
        // comment's resolution, remove its mark — the endmatter must STAY
        // recognized (records keep it alive) instead of leaking into prose.
        let source = """
        Body {>>only note<<}{#c1} here.

        ---
        comments:
          c1: { by: user, at: "2026-04-28T12:00:00Z" }

        """
        let record = try XCTUnwrap(ReviewEndmatter.resolutionRecordEdit(
            resolving: "c1", summary: "dismissed · only note", in: source))
        var after = applying(record, to: source)
        // Now remove the mark itself (what resolveSuggestion does second).
        let document = MarkdownConverter.parse(after)
        let mark = SuggestionResolver.marks(in: document)[0]
        let markEdit = try XCTUnwrap(SuggestionResolver.edit(
            resolving: mark.range, in: after, action: .accept))
        after = applying(markEdit, to: after)

        let final = MarkdownConverter.parse(after)
        XCTAssertNotNil(final.reviewMetadata, "records keep the endmatter recognized")
        XCTAssertEqual(ReviewEndmatter.resolvedRecords(in: final).count, 1)
        XCTAssertFalse(after.contains("{>>"), "the mark itself is gone")
        XCTAssertEqual(SuggestionResolver.marks(in: final).count, 0)
    }

    func testReResolutionReplacesAStaleRecord() throws {
        let source = """
        Body {++x++}{#s1}.

        ---
        suggestions:
          s1:
            by: AI
            status: resolved
            resolved: "stale"

        """
        let edit = try XCTUnwrap(ReviewEndmatter.resolutionRecordEdit(
            resolving: "s1", summary: "accepted · x", in: source))
        let after = applying(edit, to: source)
        XCTAssertFalse(after.contains("stale"))
        XCTAssertTrue(after.contains("resolved: \"accepted · x\""))
        XCTAssertEqual(after.components(separatedBy: "status: resolved").count - 1, 1,
                       "exactly one status line")
    }

    func testResolutionSummaries() throws {
        let source = "A {~~old~>new~~} b {>>note<<} c.\n"
        let document = MarkdownConverter.parse(source)
        let marks = SuggestionResolver.marks(in: document)
        XCTAssertEqual(SuggestionResolver.resolutionSummary(
            at: marks[0].range, in: source, action: .accept), "accepted · old → new")
        XCTAssertEqual(SuggestionResolver.resolutionSummary(
            at: marks[0].range, in: source, action: .reject), "rejected · kept old over new")
        XCTAssertEqual(SuggestionResolver.resolutionSummary(
            at: marks[1].range, in: source, action: .accept), "dismissed · note")
    }
}

// MARK: - Atomic resolution (the one-undo chimera, live screenshot 2026-07-14)

extension SuggestionResolutionTests {

    func testCombinedResolutionIsOneEditAndOneUndoRestoresEverything() throws {
        let source = maintained
        let document = MarkdownConverter.parse(source)
        let mark = SuggestionResolver.marks(in: document).first {
            if case .insertion = $0.kind { return true }
            return false
        }!
        let edit = try XCTUnwrap(SuggestionResolver.combinedResolutionEdit(
            resolving: mark.range, in: source, action: .accept))

        // Applying the ONE edit does both things…
        let after = applying(edit, to: source)
        XCTAssertFalse(after.contains("{++alpha++}"), "mark resolved")
        XCTAssertTrue(after.contains("alpha"), "accepted text stays")
        XCTAssertTrue(after.contains("status: resolved"), "…and the record landed")
        XCTAssertEqual(ReviewEndmatter.resolvedRecords(in: MarkdownConverter.parse(after)).count, 1)

        // …and the inverse single splice restores the original byte-exactly
        // (what the session's undo stack stores).
        let bytes = Array(source.utf8)
        let original = String(decoding: bytes[
            edit.range.offset..<(edit.range.offset + edit.range.length)], as: UTF8.self)
        let inverse = SourceEdit(
            range: ByteRange(offset: edit.range.offset, length: edit.replacement.utf8.count),
            replacement: original)
        XCTAssertEqual(applying(inverse, to: after), source, "one ⌘Z = full restore")
    }

    func testMarkWinsOverStaleResolvedMetadata() throws {
        // The chimera state (mark present + record says resolved): the mark
        // must stay actionable and its record must NOT show as history.
        let chimera = """
        Body {++alpha++}{#s1} here.

        ---
        suggestions:
          s1:
            by: AI
            status: resolved
            resolved: "accepted · alpha"

        """
        let document = MarkdownConverter.parse(chimera)
        let items = SuggestionResolver.reviewItems(in: document)
        XCTAssertEqual(items.count, 1)
        XCTAssertFalse(items[0].isResolved, "live mark is actionable — mark wins")
        XCTAssertTrue(ReviewEndmatter.resolvedRecords(in: document).isEmpty,
                      "a record whose mark still lives isn't history yet")
    }
}
