import XCTest
@testable import QuoinCore

final class SourceEditTests: XCTestCase {

    func testInsert() throws {
        let edit = SourceEdit(range: ByteRange(offset: 5, length: 0), replacement: "big ")
        let (result, inverse) = try edit.apply(to: "some text")
        XCTAssertEqual(result, "some big text")
        XCTAssertEqual(inverse, SourceEdit(range: ByteRange(offset: 5, length: 4), replacement: ""))
    }

    func testDelete() throws {
        let edit = SourceEdit(range: ByteRange(offset: 4, length: 4), replacement: "")
        let (result, inverse) = try edit.apply(to: "some big text")
        XCTAssertEqual(result, "some text")
        let (roundTrip, _) = try inverse.apply(to: result)
        XCTAssertEqual(roundTrip, "some big text")
    }

    func testReplaceWithUnicode() throws {
        let source = "café ☕️ time"
        let cafeLength = "café".utf8.count
        let edit = SourceEdit(range: ByteRange(offset: 0, length: cafeLength), replacement: "東京")
        let (result, inverse) = try edit.apply(to: source)
        XCTAssertEqual(result, "東京 ☕️ time")
        let (back, _) = try inverse.apply(to: result)
        XCTAssertEqual(back, source)
    }

    func testEditSplittingScalarRefused() {
        // Offset 1 lands inside the two-byte é in "é".
        XCTAssertThrowsError(
            try SourceEdit(range: ByteRange(offset: 1, length: 1), replacement: "x").apply(to: "é")
        )
    }

    func testOutOfBoundsRefused() {
        XCTAssertThrowsError(
            try SourceEdit(range: ByteRange(offset: 100, length: 1), replacement: "x").apply(to: "short")
        )
    }
}

final class EditMappingTests: XCTestCase {

    func testAsciiRoundTrip() {
        XCTAssertEqual(EditMapping.utf8Offset(inText: "hello", utf16Offset: 3), 3)
        XCTAssertEqual(EditMapping.utf16Offset(inText: "hello", utf8Offset: 3), 3)
    }

    func testMultibyteCharacters() {
        let text = "café x" // é = 2 UTF-8 bytes, 1 UTF-16 unit
        XCTAssertEqual(EditMapping.utf8Offset(inText: text, utf16Offset: 4), 5)
        XCTAssertEqual(EditMapping.utf16Offset(inText: text, utf8Offset: 5), 4)
    }

    func testEmoji() {
        let text = "a🎉b" // 🎉 = 4 UTF-8 bytes, 2 UTF-16 units
        XCTAssertEqual(EditMapping.utf8Offset(inText: text, utf16Offset: 3), 5)
        XCTAssertEqual(EditMapping.utf16Offset(inText: text, utf8Offset: 5), 3)
        // Offsets inside the emoji are not scalar boundaries.
        XCTAssertNil(EditMapping.utf8Offset(inText: text, utf16Offset: 2))
    }

    func testRangeConversion() {
        let text = "aé🎉z"
        // 1..<2 covers é exactly (2 UTF-8 bytes).
        XCTAssertEqual(
            EditMapping.utf8Range(inText: text, utf16Range: 1..<2),
            ByteRange(offset: 1, length: 2)
        )
        // 1..<3 would split the emoji's surrogate pair — refused.
        XCTAssertNil(EditMapping.utf8Range(inText: text, utf16Range: 1..<3))
        // 1..<4 covers é + the whole emoji (2 + 4 UTF-8 bytes).
        XCTAssertEqual(
            EditMapping.utf8Range(inText: text, utf16Range: 1..<4),
            ByteRange(offset: 1, length: 6)
        )
    }

    func testOutOfBounds() {
        XCTAssertNil(EditMapping.utf8Offset(inText: "ab", utf16Offset: 5))
        XCTAssertNil(EditMapping.utf16Offset(inText: "ab", utf8Offset: -1))
    }
}

final class SessionEditingTests: XCTestCase {

    func testApplyEditPublishesAndTracksUndo() async throws {
        let session = DocumentSession(source: "# Title\n\nHello world.")
        let canUndoBefore = await session.canUndo
        XCTAssertFalse(canUndoBefore)

        // Replace "world" (bytes 15..20).
        let edit = SourceEdit(range: ByteRange(offset: 15, length: 5), replacement: "there")
        let doc = try await session.applyEdit(edit)
        XCTAssertEqual(doc.source, "# Title\n\nHello there.")

        let canUndo = await session.canUndo
        XCTAssertTrue(canUndo)
        let undone = try await session.undo()
        XCTAssertEqual(undone?.source, "# Title\n\nHello world.")
        let redone = try await session.redo()
        XCTAssertEqual(redone?.source, "# Title\n\nHello there.")
    }

    func testApplyEditCanSkipSnapshotPublishForLocalRenderCoalescing() async throws {
        let session = DocumentSession(source: "hello")
        let stream = await session.snapshots()
        var iterator = stream.makeAsyncIterator()
        let initial = await iterator.next()
        XCTAssertEqual(initial?.source, "hello")

        let edit = SourceEdit(range: ByteRange(offset: 5, length: 0), replacement: " world")
        let edited = try await session.applyEdit(edit, publishSnapshot: false)
        XCTAssertEqual(edited.source, "hello world")
        let authoritative = await session.document
        XCTAssertEqual(authoritative.source, "hello world")

        let unexpectedSnapshot = expectation(description: "suppressed local edit snapshot")
        unexpectedSnapshot.isInverted = true
        let nextSnapshotTask = Task {
            if await iterator.next() != nil {
                unexpectedSnapshot.fulfill()
            }
        }
        await fulfillment(of: [unexpectedSnapshot], timeout: 0.2)
        nextSnapshotTask.cancel()

        let undone = try await session.undo()
        XCTAssertEqual(undone?.source, "hello")
    }

    func testEditAutosavesToDisk() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("quoin-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("doc.md")
        try Data("hello".utf8).write(to: file)

        let session = try DocumentSession.open(fileURL: file)
        try await session.applyEdit(SourceEdit(range: ByteRange(offset: 5, length: 0), replacement: " world"))
        // Debounced write; wait past the debounce.
        try await Task.sleep(for: .milliseconds(700))
        let onDisk = try String(contentsOf: file, encoding: .utf8)
        XCTAssertEqual(onDisk, "hello world")
    }

    func testFailedSaveKeepsDirtyStateAndCanRetry() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("quoin-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("doc.md")
        try Data("hello".utf8).write(to: file)

        let session = try DocumentSession.open(fileURL: file)
        try await session.applyEdit(SourceEdit(range: ByteRange(offset: 5, length: 0), replacement: " world"))

        try FileManager.default.removeItem(at: file)
        try FileManager.default.createDirectory(at: file, withIntermediateDirectories: false)

        do {
            try await session.saveNow()
            XCTFail("save should fail when the document URL is a directory")
        } catch SessionError.fileWriteFailed(let url, _) {
            XCTAssertEqual(url, file)
        } catch {
            XCTFail("unexpected error: \(error)")
        }

        let isDirtyAfterFailure = await session.hasUnsavedChanges
        let saveErrorAfterFailure = await session.lastSaveError
        let sourceAfterFailure = await session.document.source
        XCTAssertTrue(isDirtyAfterFailure)
        XCTAssertNotNil(saveErrorAfterFailure)
        XCTAssertEqual(sourceAfterFailure, "hello world")

        try FileManager.default.removeItem(at: file)
        try await session.saveNow()

        let isDirtyAfterRetry = await session.hasUnsavedChanges
        let saveErrorAfterRetry = await session.lastSaveError
        XCTAssertFalse(isDirtyAfterRetry)
        XCTAssertNil(saveErrorAfterRetry)
        let onDisk = try String(contentsOf: file, encoding: .utf8)
        XCTAssertEqual(onDisk, "hello world")
    }

    func testUntouchedRegionsAreByteLossless() throws {
        // The acceptance-checklist guarantee: editing one block leaves every
        // other byte of the file identical.
        let source = "# Title\n\nPara one   with  odd spacing\t\n\n- [x] task ☕️\n\nlast"
        let doc = MarkdownConverter.parse(source)
        let target = doc.blocks[1] // "Para one..."
        let edit = SourceEdit(
            range: ByteRange(offset: target.range.offset, length: 4),
            replacement: "Line"
        )
        let (result, _) = try edit.apply(to: source)
        let originalBytes = Array(source.utf8)
        let resultBytes = Array(result.utf8)
        // Prefix before the edit and suffix after it are untouched.
        XCTAssertEqual(Array(resultBytes[0..<target.range.offset]), Array(originalBytes[0..<target.range.offset]))
        XCTAssertEqual(
            Array(resultBytes[(target.range.offset + 4)...]),
            Array(originalBytes[(target.range.offset + 4)...])
        )
    }
}
