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

    /// Non-nil while an external change conflicts with unsaved local edits;
    /// holds the on-disk source for "use disk version".
    @Published private(set) var conflictDiskSource: String?
    /// The document's current URL; changes when the first H1 renames an
    /// Untitled file (design rule).
    @Published private(set) var fileURL: URL?

    var onFileRenamed: ((URL) -> Void)?

    private(set) var document: QuoinDocument = .empty
    private var session: DocumentSession?
    private var snapshotTask: Task<Void, Never>?
    private var renderer = AttributedRenderer()
    private var renameTask: Task<Void, Never>?

    private var slugToBlock: [String: BlockID] = [:]
    /// Per-block rendered fragments reused across re-renders so a keystroke
    /// only rebuilds the block that changed (see AttributedRenderer.render).
    private var fragmentCache: [BlockID: NSAttributedString] = [:]

    func start(fileURL: URL?, initialText: String) {
        guard session == nil else { return }
        self.fileURL = fileURL
        let theme = Theme()
        renderer = AttributedRenderer(
            theme: theme,
            baseURL: fileURL?.deletingLastPathComponent(),
            onContentReady: { [weak self] in
                Task { @MainActor in self?.scheduleAsyncContentRerender() }
            }
        )

        let session: DocumentSession
        if let fileURL, let opened = try? DocumentSession.open(fileURL: fileURL) {
            session = opened
        } else {
            session = DocumentSession(source: initialText, fileURL: fileURL)
        }
        self.session = session

        snapshotTask = Task { [weak self] in
            await session.setConflictHandler { diskSource in
                Task { @MainActor [weak self] in
                    self?.conflictDiskSource = diskSource
                }
            }
            await session.startWatching()
            let snapshots = await session.snapshots()
            for await document in snapshots {
                await self?.ingest(document)
            }
        }
    }

    // MARK: - Merge banner

    func resolveConflictKeepingMine() {
        conflictDiskSource = nil
        guard let session else { return }
        Task { await session.resolveConflictKeepingMine() }
    }

    func resolveConflictTakingDisk() {
        guard let session, let diskSource = conflictDiskSource else { return }
        conflictDiskSource = nil
        activeBlockID = nil
        caretInActiveBlock = nil
        Task { await session.resolveConflictTakingDisk(diskSource) }
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

    private var asyncRerenderTask: Task<Void, Never>?

    /// Coalesces re-renders when async images finish decoding — a document
    /// with 30 photos triggers one re-render, not 30.
    private func scheduleAsyncContentRerender() {
        asyncRerenderTask?.cancel()
        asyncRerenderTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(120))
            guard !Task.isCancelled else { return }
            self?.rerender()
        }
    }

    private func rerender() {
        rendered = renderer.render(document, activeBlockID: activeBlockID, activeCaret: caretInActiveBlock, cache: &fragmentCache)
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
    /// within the active block's source slice. `caretDelta` (UTF-8 from the
    /// edit start) overrides the landing spot for smart pairs and format
    /// commands.
    func applyEdit(relativeRange: ByteRange, replacement: String, caretDelta: Int? = nil) {
        guard let session,
              let activeBlockID,
              let block = document.blocks.first(where: { $0.id == activeBlockID })
        else { return }

        let absolute = ByteRange(
            offset: block.range.offset + relativeRange.offset,
            length: relativeRange.length
        )
        let caretUTF8 = absolute.offset + (caretDelta ?? replacement.utf8.count)
        let edit = SourceEdit(range: absolute, replacement: replacement)

        Task {
            guard let newDocument = try? await session.applyEdit(edit) else { return }
            self.restoreCaret(in: newDocument, atUTF8Offset: caretUTF8)
            self.scheduleH1Rename(for: newDocument)
        }
    }

    // MARK: - First H1 renames Untitled files (debounced, silent suffix)

    private func scheduleH1Rename(for doc: QuoinDocument) {
        guard let url = fileURL,
              url.deletingPathExtension().lastPathComponent.hasPrefix("Untitled"),
              let first = doc.outline.first, first.level == 1
        else { return }
        let title = sanitizedFilename(first.title)
        guard !title.isEmpty, title != url.deletingPathExtension().lastPathComponent else { return }

        renameTask?.cancel()
        renameTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(800))
            guard !Task.isCancelled else { return }
            await self?.performH1Rename(to: title)
        }
    }

    private func performH1Rename(to title: String) async {
        guard let session, let url = fileURL else { return }
        await session.saveNow()
        guard let renamed = try? Library.rename(url, to: title) else { return }
        await session.relocate(to: renamed)
        fileURL = renamed
        onFileRenamed?(renamed)
    }

    private func sanitizedFilename(_ title: String) -> String {
        let cleaned = title
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return String(cleaned.prefix(80))
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

    // MARK: - Image drop

    static let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "gif", "heic", "webp", "tiff", "bmp"]

    /// Drag-dropped image: copy the asset next to the document (assets/),
    /// insert `![](assets/…)` at the caret (or document end).
    func insertImage(from sourceURL: URL) {
        guard let session,
              let docURL = fileURL,
              Self.imageExtensions.contains(sourceURL.pathExtension.lowercased())
        else { return }

        let assetsFolder = docURL.deletingLastPathComponent().appendingPathComponent("assets", isDirectory: true)
        try? FileManager.default.createDirectory(at: assetsFolder, withIntermediateDirectories: true)

        // Silent-suffix collision handling, same rule as document names.
        let base = sourceURL.deletingPathExtension().lastPathComponent
        let ext = sourceURL.pathExtension
        var destination = assetsFolder.appendingPathComponent(sourceURL.lastPathComponent)
        var counter = 2
        while FileManager.default.fileExists(atPath: destination.path) {
            destination = assetsFolder.appendingPathComponent("\(base) \(counter)").appendingPathExtension(ext)
            counter += 1
        }
        guard (try? FileManager.default.copyItem(at: sourceURL, to: destination)) != nil else { return }

        let markdown = "\n\n![](assets/\(destination.lastPathComponent))\n"
        let offset: Int
        if let activeBlockID,
           let block = document.blocks.first(where: { $0.id == activeBlockID }),
           let caret = caretInActiveBlock,
           let slice = document.source.substring(in: block.range),
           let caretUTF8 = EditMapping.utf8Offset(inText: slice, utf16Offset: caret) {
            offset = block.range.offset + caretUTF8
        } else {
            offset = document.source.utf8.count
        }

        let edit = SourceEdit(range: ByteRange(offset: offset, length: 0), replacement: markdown)
        Task {
            guard let newDocument = try? await session.applyEdit(edit) else { return }
            self.restoreCaret(in: newDocument, atUTF8Offset: offset + markdown.utf8.count)
        }
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
