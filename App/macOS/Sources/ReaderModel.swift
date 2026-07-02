import Foundation
import SwiftUI
import QuoinCore
import QuoinRender

/// Owns the `DocumentSession` for one window and republishes its snapshots
/// as rendered output for SwiftUI — including the editor's syntax-reveal
/// state (active block + caret), which lives here because it must survive
/// each edit's re-parse round trip.
@MainActor
final class ReaderModel: ObservableObject {

    @Published private(set) var rendered: RenderedDocument = .empty
    @Published private(set) var outline: [HeadingInfo] = []
    @Published private(set) var stats = DocumentStats()
    @Published private(set) var activeBlockID: BlockID?
    @Published private(set) var caretInActiveBlock: Int?
    @Published private(set) var caretGeneration = 0

    private var document: QuoinDocument = .empty
    private var session: DocumentSession?
    private var snapshotTask: Task<Void, Never>?
    private var renderer = AttributedRenderer()

    private var slugToBlock: [String: BlockID] = [:]

    func start(fileURL: URL?, initialText: String) {
        guard session == nil else { return }
        let theme = Theme()
        renderer = AttributedRenderer(theme: theme, baseURL: fileURL?.deletingLastPathComponent())

        let session: DocumentSession
        if let fileURL, let opened = try? DocumentSession.open(fileURL: fileURL) {
            session = opened
        } else {
            session = DocumentSession(source: initialText, fileURL: fileURL)
        }
        self.session = session

        snapshotTask = Task { [weak self] in
            await session.startWatching()
            let snapshots = await session.snapshots()
            for await document in snapshots {
                await self?.ingest(document)
            }
        }
    }

    func stop() {
        snapshotTask?.cancel()
        snapshotTask = nil
        let session = session
        Task {
            await session?.saveNow()
            await session?.stopWatching()
        }
    }

    /// A new snapshot from the session (file change, checkbox, or our own
    /// edit). Skips re-rendering when both content and reveal state are
    /// unchanged.
    private func ingest(_ document: QuoinDocument) {
        // Our own edits already rendered via restoreCaret; skip the echo.
        guard document.sourceHash != self.document.sourceHash
                || rendered.activeBlockID != activeBlockID else { return }
        self.document = document
        // The active block's identity may have changed with its content;
        // keep activation only if the id still exists.
        if let active = activeBlockID, document.block(withID: active) == nil {
            activeBlockID = nil
            caretInActiveBlock = nil
        }
        rerender()
    }

    private func rerender() {
        rendered = renderer.render(document, activeBlockID: activeBlockID)
        outline = document.outline
        stats = document.stats
        slugToBlock = Dictionary(
            document.outline.map { ($0.slug, $0.id) },
            uniquingKeysWith: { first, _ in first }
        )
    }

    // MARK: - Syntax reveal

    func activateBlock(_ id: BlockID?) {
        guard id != activeBlockID else { return }
        activeBlockID = id
        // Place the caret at the end of the revealed source by default.
        if let id, let block = document.blocks.first(where: { $0.id == id }),
           let slice = document.source.substring(in: block.range) {
            caretInActiveBlock = slice.utf16.count
        } else {
            caretInActiveBlock = nil
        }
        caretGeneration += 1
        rerender()
    }

    // MARK: - Edits

    /// A keystroke from the revealed block: `relativeRange` is UTF-8 bytes
    /// within the active block's source slice.
    func applyEdit(relativeRange: ByteRange, replacement: String) {
        guard let session,
              let activeBlockID,
              let block = document.blocks.first(where: { $0.id == activeBlockID })
        else { return }

        let absolute = ByteRange(
            offset: block.range.offset + relativeRange.offset,
            length: relativeRange.length
        )
        let caretUTF8 = absolute.offset + replacement.utf8.count
        let edit = SourceEdit(range: absolute, replacement: replacement)

        Task {
            guard let newDocument = try? await session.applyEdit(edit) else { return }
            self.restoreCaret(in: newDocument, atUTF8Offset: caretUTF8)
        }
    }

    func undo() {
        guard let session else { return }
        Task {
            if let doc = try? await session.undo() {
                self.restoreCaret(in: doc, atUTF8Offset: nil)
            }
        }
    }

    func redo() {
        guard let session else { return }
        Task {
            if let doc = try? await session.redo() {
                self.restoreCaret(in: doc, atUTF8Offset: nil)
            }
        }
    }

    /// After an edit round-trip: adopt the new document, re-locate the
    /// block containing the caret (block identity changes with content, and
    /// an Enter can split one block into two), and restore the caret.
    private func restoreCaret(in newDocument: QuoinDocument, atUTF8Offset caretUTF8: Int?) {
        document = newDocument
        if let caretUTF8 {
            let block = newDocument.blocks.last(where: { $0.range.offset <= caretUTF8 })
                ?? newDocument.blocks.first
            if let block, let slice = newDocument.source.substring(in: block.range) {
                activeBlockID = block.id
                let relative = max(0, min(caretUTF8 - block.range.offset, slice.utf8.count))
                caretInActiveBlock = EditMapping.utf16Offset(inText: slice, utf8Offset: relative) ?? slice.utf16.count
            } else {
                activeBlockID = nil
                caretInActiveBlock = nil
            }
        } else if let active = activeBlockID, newDocument.block(withID: active) == nil {
            activeBlockID = nil
            caretInActiveBlock = nil
        }
        caretGeneration += 1
        rerender()
    }

    // MARK: - Checkbox & anchors

    func toggleTask(markerOffset: Int) {
        guard let session else { return }
        Task {
            try? await session.toggleTask(markerRange: ByteRange(offset: markerOffset, length: 3))
        }
    }

    func blockID(forSlug slug: String) -> BlockID? {
        slugToBlock[slug]
    }
}
