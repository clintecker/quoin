import XCTest
@testable import QuoinCore

final class SmartPairsTests: XCTestCase {

    func testAsteriskPairsAtWordStart() {
        let completion = SmartPairs.completion(typing: "*", inText: "hello ", caretUTF16: 6)
        XCTAssertEqual(completion, SmartPairs.Completion(insert: "**", caretOffset: 1))
    }

    func testBacktickPairs() {
        let completion = SmartPairs.completion(typing: "`", inText: "run ", caretUTF16: 4)
        XCTAssertEqual(completion, SmartPairs.Completion(insert: "``", caretOffset: 1))
    }

    func testTypeOverExistingCloser() {
        // Caret sits before the closer that pairing previously inserted.
        let completion = SmartPairs.completion(typing: "*", inText: "**bold**", caretUTF16: 6)
        XCTAssertEqual(completion, SmartPairs.Completion(insert: "", caretOffset: 1))
    }

    func testNoPairGluedOntoWord() {
        // Typing * directly before letters (e.g. fixing emphasis manually).
        XCTAssertNil(SmartPairs.completion(typing: "*", inText: "hello", caretUTF16: 0))
    }

    func testSingleEqualsIsPlainText() {
        XCTAssertNil(SmartPairs.completion(typing: "=", inText: "x ", caretUTF16: 2))
    }

    func testDoubleEqualsCompletes() {
        // First = typed as text; second = completes the pair.
        let completion = SmartPairs.completion(typing: "=", inText: "note =", caretUTF16: 6)
        XCTAssertEqual(completion, SmartPairs.Completion(insert: "===", caretOffset: 1))
    }

    func testSuspendedInsideInlineCode() {
        // Caret inside `code span`
        let text = "see `let x "
        XCTAssertNil(SmartPairs.completion(typing: "*", inText: text, caretUTF16: text.utf16.count))
    }

    func testSuspendedInsideFence() {
        let text = "```swift\nlet a "
        XCTAssertNil(SmartPairs.completion(typing: "$", inText: text, caretUTF16: text.utf16.count))
    }

    func testDollarPairs() {
        let completion = SmartPairs.completion(typing: "$", inText: "math ", caretUTF16: 5)
        XCTAssertEqual(completion, SmartPairs.Completion(insert: "$$", caretOffset: 1))
    }
}

final class FormattingTests: XCTestCase {

    func testWrapBold() {
        let change = Formatting.toggleWrap(selection: "word", delimiter: "**")
        XCTAssertEqual(change.replacement, "**word**")
        XCTAssertEqual(change.selectionOffset, 2)
        XCTAssertEqual(change.selectionLength, 4)
    }

    func testUnwrapBold() {
        let change = Formatting.toggleWrap(selection: "**word**", delimiter: "**")
        XCTAssertEqual(change.replacement, "word")
        XCTAssertEqual(change.selectionLength, 4)
    }

    func testWrapEmptySelection() {
        let change = Formatting.toggleWrap(selection: "", delimiter: "**")
        XCTAssertEqual(change.replacement, "****")
        XCTAssertEqual(change.selectionOffset, 2)
        XCTAssertEqual(change.selectionLength, 0)
    }

    func testHighlightWrap() {
        let change = Formatting.toggleWrap(selection: "key point", delimiter: "==")
        XCTAssertEqual(change.replacement, "==key point==")
    }

    func testMakeLinkSelectsURLPlaceholder() {
        let change = Formatting.makeLink(selection: "Apple")
        XCTAssertEqual(change.replacement, "[Apple](url)")
        // Selection covers "url" so typing replaces it immediately.
        let start = change.replacement.index(change.replacement.startIndex, offsetBy: change.selectionOffset)
        let end = change.replacement.index(start, offsetBy: change.selectionLength)
        XCTAssertEqual(String(change.replacement[start..<end]), "url")
    }

    func testMakeLinkEmptySelection() {
        let change = Formatting.makeLink(selection: "")
        XCTAssertEqual(change.replacement, "[link](url)")
    }
}

final class ConflictTests: XCTestCase {

    func testDirtySessionSurfacesConflictInsteadOfReplacing() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("quoin-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("doc.md")
        try Data("original".utf8).write(to: file)

        let session = try DocumentSession.open(fileURL: file)
        let conflictArrived = expectation(description: "conflict")
        await session.setConflictHandler { disk in
            XCTAssertEqual(disk, "external change")
            conflictArrived.fulfill()
        }

        // Local unsaved edit (autosave debounce still pending)…
        try await session.applyEdit(SourceEdit(range: ByteRange(offset: 0, length: 0), replacement: "local "))
        // …then an external write lands.
        try Data("external change".utf8).write(to: file)
        await session.reloadFromDisk()

        await fulfillment(of: [conflictArrived], timeout: 2)
        // Local content is preserved, not clobbered.
        let current = await session.document
        XCTAssertEqual(current.source, "local original")

        // Taking the disk version adopts it.
        await session.resolveConflictTakingDisk("external change")
        let adopted = await session.document
        XCTAssertEqual(adopted.source, "external change")
    }
}
