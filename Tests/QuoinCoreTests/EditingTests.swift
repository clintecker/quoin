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

    func testExternalReloadClearsUndoRedoStacks() async throws {
        // Ledger (data integrity #3): ⌘Z after an external disk change used
        // to splice stale bytes at old offsets, then autosave the corruption.
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("quoin-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("doc.md")
        try Data("alpha bravo".utf8).write(to: file)

        let session = try DocumentSession.open(fileURL: file)
        try await session.applyEdit(
            SourceEdit(range: ByteRange(offset: 6, length: 5), replacement: "charlie"))
        _ = try await session.undo()
        let canUndoBefore = await session.canUndo
        let canRedoBefore = await session.canRedo
        XCTAssertFalse(canUndoBefore)
        XCTAssertTrue(canRedoBefore)
        // Let the autosave settle so the session is clean when disk moves.
        try await Task.sleep(for: .milliseconds(700))

        let external = "totally different content\nwith new offsets\n"
        try Data(external.utf8).write(to: file)
        await session.reloadFromDisk()

        let reloaded = await session.document.source
        XCTAssertEqual(reloaded, external)
        let canUndo = await session.canUndo
        let canRedo = await session.canRedo
        XCTAssertFalse(canUndo, "undo stack must not survive an external reload")
        XCTAssertFalse(canRedo, "redo stack must not survive an external reload")

        // Attempted undo is a no-op and cannot corrupt the adopted content.
        let undone = try await session.undo()
        XCTAssertNil(undone)
        let afterUndo = await session.document.source
        XCTAssertEqual(afterUndo, external)
    }

    func testConflictResolutionTakingDiskClearsUndoRedoStacks() async throws {
        let session = DocumentSession(source: "one two three")
        try await session.applyEdit(
            SourceEdit(range: ByteRange(offset: 4, length: 3), replacement: "2"))
        let canUndoBefore = await session.canUndo
        XCTAssertTrue(canUndoBefore)

        await session.resolveConflictTakingDisk("disk wins, different bytes")
        let canUndo = await session.canUndo
        XCTAssertFalse(canUndo, "adopting the disk side must clear undo history")
        let undone = try await session.undo()
        XCTAssertNil(undone)
        let source = await session.document.source
        XCTAssertEqual(source, "disk wins, different bytes")
    }

    func testWholesaleApplyClearsUndoRedoStacks() async throws {
        let session = DocumentSession(source: "hello")
        try await session.applyEdit(
            SourceEdit(range: ByteRange(offset: 5, length: 0), replacement: " world"))
        await session.apply(source: "replaced entirely")
        let canUndo = await session.canUndo
        XCTAssertFalse(canUndo)
        let undone = try await session.undo()
        XCTAssertNil(undone)
        let source = await session.document.source
        XCTAssertEqual(source, "replaced entirely")
    }

    func testConflictSuspendsAutosaveUntilResolved() async throws {
        // Ledger (data integrity #5): typing after the merge banner used to
        // re-arm the debounced autosave and clobber the disk version while
        // the user was still deciding.
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("quoin-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("doc.md")
        try Data("shared base".utf8).write(to: file)

        let session = try DocumentSession.open(fileURL: file)
        // Local edit → dirty (autosave still inside its debounce window).
        try await session.applyEdit(
            SourceEdit(range: ByteRange(offset: 11, length: 0), replacement: " plus local"))
        // External change lands while dirty → conflict.
        let external = "external version"
        try Data(external.utf8).write(to: file)
        await session.reloadFromDisk()
        let conflicted = await session.hasUnresolvedConflict
        XCTAssertTrue(conflicted)

        // Continued typing while the banner is up must not write anything.
        try await session.applyEdit(
            SourceEdit(range: ByteRange(offset: 0, length: 0), replacement: "more "))
        try await Task.sleep(for: .milliseconds(1300))
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), external,
                       "autosave must be suspended while a conflict is unresolved")

        // Even an explicit flush must refuse.
        do {
            try await session.saveNow()
            XCTFail("saveNow must refuse while the conflict is unresolved")
        } catch SessionError.conflictUnresolved(let url) {
            XCTAssertEqual(url, file)
        }
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), external)

        // Resolution (keep mine) writes the local side and re-arms saving.
        try await session.resolveConflictKeepingMine()
        let localAfterResolve = await session.document.source
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), localAfterResolve)
        let stillConflicted = await session.hasUnresolvedConflict
        XCTAssertFalse(stillConflicted)

        // Subsequent edits autosave normally again.
        try await session.applyEdit(
            SourceEdit(range: ByteRange(offset: 0, length: 0), replacement: "again "))
        try await Task.sleep(for: .milliseconds(700))
        let finalSource = await session.document.source
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), finalSource,
                       "autosave must resume after the conflict is resolved")
    }

    func testConflictResolvedByTakingDiskResumesAutosave() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("quoin-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("doc.md")
        try Data("shared base".utf8).write(to: file)

        let session = try DocumentSession.open(fileURL: file)
        try await session.applyEdit(
            SourceEdit(range: ByteRange(offset: 0, length: 0), replacement: "local "))
        let external = "external version"
        try Data(external.utf8).write(to: file)
        await session.reloadFromDisk()
        let conflicted = await session.hasUnresolvedConflict
        XCTAssertTrue(conflicted)

        await session.resolveConflictTakingDisk(external)
        let source = await session.document.source
        XCTAssertEqual(source, external)

        try await session.applyEdit(
            SourceEdit(range: ByteRange(offset: 0, length: 0), replacement: "typed "))
        try await Task.sleep(for: .milliseconds(700))
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "typed " + external,
                       "autosave must resume after taking the disk side")
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
