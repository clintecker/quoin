import Foundation
import SwiftUI
import QuoinCore
import QuoinRender

private struct ActiveBlockRenderPatch {
    let storagePatch: RenderStoragePatch
    let blockRanges: [BlockID: NSRange]
    let activeEditableRange: NSRange
    let activeSourceText: String
    let oldActiveBlockID: BlockID
}

/// Owns the `DocumentSession` for one window and republishes its snapshots
/// as rendered output for SwiftUI — including the editor's syntax-reveal
/// state (active block + caret), which lives here because it must survive
/// each edit's re-parse round trip.
@MainActor
@Observable
final class ReaderModel {

    // Formerly @Published: with @Observable, plain stored properties are
    // observed automatically. Everything below the UI state is marked
    // @ObservationIgnored so exactly these properties drive view updates —
    // the same set that used to be @Published.
    private(set) var rendered: RenderedDocument = .empty
    private(set) var outline: [HeadingInfo] = []
    private(set) var stats = DocumentStats()
    private(set) var activeBlockID: BlockID?
    private(set) var caretInActiveBlock: Int?
    private(set) var caretGeneration = 0

    /// Non-nil while an external change conflicts with unsaved local edits;
    /// holds the on-disk source for "use disk version".
    private(set) var conflictDiskSource: String?

    /// A transient, non-blocking failure from a user-triggered file action
    /// (image insert, checkbox toggle). Surfaced as a banner and auto-cleared
    /// — never a modal (handoff interaction style). Recording it in model
    /// state means the app can explain what didn't happen instead of failing
    /// silently, which is dangerous in a file-backed editor.
    private(set) var actionFailure: ActionFailure?

    struct ActionFailure: Identifiable, Equatable {
        let id = UUID()
        let message: String
    }
    /// The document's current URL; changes when the first H1 renames an
    /// Untitled file (design rule).
    private(set) var fileURL: URL?

    /// The parsed document, read by the editor screen; it changes in lockstep
    /// with `rendered`, so it stays observed rather than ignored.
    private(set) var document: QuoinDocument = .empty

    @ObservationIgnored var onFileRenamed: ((URL) -> Void)?

    @ObservationIgnored private var session: DocumentSession?
    @ObservationIgnored private var snapshotTask: Task<Void, Never>?
    @ObservationIgnored private var renderer = AttributedRenderer()
    @ObservationIgnored private var renameTask: Task<Void, Never>?
    @ObservationIgnored private var actionFailureTask: Task<Void, Never>?
    @ObservationIgnored private var editPipelineTask: Task<Void, Never>?
    @ObservationIgnored private var latestEditGeneration = 0
    /// Monotonic revision stamped on every published RenderedDocument, so
    /// the view layer applies each projection (and its storage patches)
    /// exactly once.
    @ObservationIgnored private var renderedRevision = 0

    /// The authoritative projection, mirrored through every publish: full
    /// renders replace it; patch publishes apply their patches to it FIRST.
    /// SwiftUI coalesces rapid publishes, so the view can skip a patch
    /// revision entirely — when its `patchBaseLength` check misses, it
    /// resyncs by splicing to this string, which is correct precisely
    /// because it never skips a patch.
    @ObservationIgnored private var liveAttributed = NSMutableAttributedString()

    private func nextRevision() -> Int {
        renderedRevision += 1
        return renderedRevision
    }

    /// Applies a descending, disjoint patch batch to the authoritative
    /// string, returning its pre-patch length (the view's expected base).
    /// Nil on any bounds surprise — the caller must fall back to a full
    /// render.
    private func applyToLiveAttributed(_ patches: [RenderStoragePatch]) -> Int? {
        let base = liveAttributed.length
        for patch in patches {
            guard patch.oldRange.location >= 0,
                  NSMaxRange(patch.oldRange) <= liveAttributed.length else { return nil }
            liveAttributed.replaceCharacters(in: patch.oldRange, with: patch.replacement)
        }
        return base
    }

    @ObservationIgnored private var slugToBlock: [String: BlockID] = [:]
    /// Per-block rendered fragments reused across re-renders so a keystroke
    /// only rebuilds the block that changed (see AttributedRenderer.render).
    @ObservationIgnored private var fragmentCache: [BlockID: NSAttributedString] = [:]

    func start(fileURL: URL?, initialText: String) {
        guard session == nil else { return }
        self.fileURL = fileURL
        renderer = makeRenderer()

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

    /// A renderer for the CURRENT appearance — `Theme()` captures light/dark
    /// at creation, so appearance switches must re-create it (see
    /// `refreshTheme`).
    private func makeRenderer() -> AttributedRenderer {
        AttributedRenderer(
            theme: Theme(),
            baseURL: fileURL?.deletingLastPathComponent(),
            onContentReady: { [weak self] in
                Task { @MainActor in self?.scheduleAsyncContentRerender() }
            }
        )
    }

    /// Rebuilds the rendered projection for a new appearance (the user
    /// flipped dark/light, in-app or system-wide). The fragment cache is
    /// per-theme by construction — every cached fragment has the old
    /// palette baked in — so it empties rather than carries stale colors.
    func refreshTheme() {
        guard session != nil else { return }
        renderer = makeRenderer()
        fragmentCache.removeAll()
        rerender()
    }

    // MARK: - Merge banner

    func resolveConflictKeepingMine() {
        guard let session else { return }
        Task {
            do {
                try await session.resolveConflictKeepingMine()
                self.conflictDiskSource = nil
            } catch {
                // Keep the merge banner visible; the local version is still dirty.
            }
        }
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
        let pendingEdits = editPipelineTask
        Task {
            await pendingEdits?.value
            try? await session?.saveNow()
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

    @ObservationIgnored private var asyncRerenderTask: Task<Void, Never>?

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

    private func rerender(spliceHint: RenderSpliceHint? = nil, activeBlockPatch: ActiveBlockRenderPatch? = nil) {
        QuoinPerformanceTrace.measure(
            "model.rerender",
            metadata: "bytes=\(document.source.utf8.count) blocks=\(document.blocks.count) active=\(activeBlockID != nil) patched=\(activeBlockPatch != nil)"
        ) {
            if let patch = activeBlockPatch, let activeBlockID,
               let baseLength = applyToLiveAttributed([patch.storagePatch]) {
                fragmentCache.removeValue(forKey: patch.oldActiveBlockID)
                fragmentCache.removeValue(forKey: activeBlockID)
                rendered = RenderedDocument(
                    attributed: liveAttributed,
                    blockRanges: patch.blockRanges,
                    activeBlockID: activeBlockID,
                    activeEditableRange: patch.activeEditableRange,
                    activeSourceText: patch.activeSourceText,
                    storagePatch: patch.storagePatch,
                    revision: nextRevision(),
                    patchBaseLength: baseLength
                )
            } else {
                let next = renderer.render(document, activeBlockID: activeBlockID, activeCaret: caretInActiveBlock, cache: &fragmentCache)
                liveAttributed = NSMutableAttributedString(attributedString: next.attributed)
                rendered = RenderedDocument(
                    attributed: liveAttributed,
                    blockRanges: next.blockRanges,
                    activeBlockID: next.activeBlockID,
                    activeEditableRange: next.activeEditableRange,
                    activeSourceText: next.activeSourceText,
                    spliceHint: spliceHint,
                    revision: nextRevision()
                )
            }
            outline = document.outline
            stats = document.stats
            slugToBlock = Dictionary(
                document.outline.map { ($0.slug, $0.id) },
                uniquingKeysWith: { first, _ in first }
            )
        }
    }

    // MARK: - Syntax reveal

    /// Activates a block for editing. `caretHint` is the caret's offset in the
    /// block's *rendered* text (UTF-16); we land the caret near there in the
    /// revealed source so a click doesn't teleport it to the block end and
    /// reveal the wrong span. For plain text the mapping is exact; markup makes
    /// it land a little early (hidden delimiters), which still feels right.
    func activateBlock(_ id: BlockID?, caretHint: Int? = nil) {
        guard id != activeBlockID else { return }
        let previousActiveID = activeBlockID
        activeBlockID = id
        if let id, let block = document.blocks.first(where: { $0.id == id }),
           let slice = document.source.substring(in: block.range) {
            let sourceLength = slice.utf16.count
            if let caretHint, let renderedRange = rendered.blockRanges[id],
               renderedRange.location + renderedRange.length <= rendered.attributed.length {
                // The hint is an offset into the block's RENDERED text; the
                // source hides characters the projection dropped (hard-break
                // spaces, `**`, `### `, entity source), so align the two
                // texts instead of reusing the raw offset.
                let renderedText = (rendered.attributed.string as NSString)
                    .substring(with: renderedRange)
                let mapped = EditMapping.sourceOffset(
                    forRenderedOffset: caretHint,
                    renderedText: renderedText,
                    sourceText: slice
                )
                caretInActiveBlock = min(max(0, mapped), sourceLength)
            } else {
                caretInActiveBlock = min(max(0, caretHint ?? sourceLength), sourceLength)
            }
        } else {
            caretInActiveBlock = nil
        }
        caretGeneration += 1
        // A flip changes only the flipped blocks' PROJECTION — the document
        // is untouched. Patch just those fragments into the live storage
        // instead of re-rendering the whole document (which costs ~half a
        // second at novel length even with a warm fragment cache).
        if applyActivationFlipPatch(from: previousActiveID, to: id) { return }
        rerender()
    }

    /// Publishes storage patches for an activate/deactivate flip (built by
    /// the renderer — see `AttributedRenderer.activationFlipUpdate`).
    /// Returns false when the projection state doesn't line up; the caller
    /// then takes the full re-render, which is always correct.
    private func applyActivationFlipPatch(from oldID: BlockID?, to newID: BlockID?) -> Bool {
        guard let update = renderer.activationFlipUpdate(
            document: document, current: rendered,
            from: oldID, to: newID, caret: caretInActiveBlock
        ) else { return false }

        guard let baseLength = applyToLiveAttributed(update.storagePatches) else { return false }
        if let cacheable = update.cacheableReadFragment {
            fragmentCache[cacheable.id] = cacheable.fragment
        }
        if let newID {
            fragmentCache.removeValue(forKey: newID)
        }
        rendered = RenderedDocument(
            attributed: liveAttributed,
            blockRanges: update.blockRanges,
            activeBlockID: newID,
            activeEditableRange: update.activeEditableRange,
            activeSourceText: update.activeSourceText,
            storagePatches: update.storagePatches,
            revision: nextRevision(),
            patchBaseLength: baseLength
        )
        return true
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
        let spliceHint = makeActiveEditSpliceHint(relativeRange: relativeRange, replacement: replacement)
        latestEditGeneration += 1
        let generation = latestEditGeneration
        let previousEditTask = editPipelineTask

        editPipelineTask = Task { [weak self] in
            await previousEditTask?.value
            guard let self else { return }
            let newDocument = try? await QuoinPerformanceTrace.measure(
                "model.session.applyEdit",
                metadata: "range_offset=\(absolute.offset) replacement_bytes=\(replacement.utf8.count)"
            ) {
                try await session.applyEdit(edit, publishSnapshot: false)
            }
            guard let newDocument else { return }
            guard generation == self.latestEditGeneration else { return }
            QuoinPerformanceTrace.measure("model.restoreCaret") {
                self.restoreCaret(in: newDocument, atUTF8Offset: caretUTF8, spliceHint: spliceHint)
            }
            self.scheduleH1Rename(for: newDocument)
            if generation == self.latestEditGeneration {
                self.editPipelineTask = nil
            }
        }
    }

    private func makeActiveEditSpliceHint(relativeRange: ByteRange, replacement: String) -> RenderSpliceHint? {
        guard !replacement.contains("\n"),
              let active = rendered.activeEditableRange,
              let source = rendered.activeSourceText,
              let start = EditMapping.utf16Offset(inText: source, utf8Offset: relativeRange.offset),
              let end = EditMapping.utf16Offset(inText: source, utf8Offset: relativeRange.upperBound)
        else { return nil }
        let location = active.location + start
        return RenderSpliceHint(
            oldRange: NSRange(location: location, length: end - start),
            replacementRange: NSRange(location: location, length: replacement.utf16.count)
        )
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
        do {
            try await session.saveNow()
        } catch {
            return
        }
        guard let renamed = try? Library.rename(url, to: title) else { return }
        await session.relocate(to: renamed)
        fileURL = renamed
        onFileRenamed?(renamed)
    }

    private func sanitizedFilename(_ title: String) -> String {
        FilenamePolicy.sanitize(title)
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
    private func restoreCaret(in newDocument: QuoinDocument, atUTF8Offset caretUTF8: Int?, spliceHint: RenderSpliceHint? = nil) {
        let oldDocument = document
        let oldRendered = rendered
        let oldActiveBlockID = activeBlockID
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
        let activeBlockPatch = makeActiveBlockRenderPatch(
            oldDocument: oldDocument,
            oldRendered: oldRendered,
            oldActiveBlockID: oldActiveBlockID,
            newDocument: newDocument,
            requiresSimpleEditHint: spliceHint != nil
        )
        rerender(spliceHint: spliceHint, activeBlockPatch: activeBlockPatch)
    }

    private func makeActiveBlockRenderPatch(
        oldDocument: QuoinDocument,
        oldRendered: RenderedDocument,
        oldActiveBlockID: BlockID?,
        newDocument: QuoinDocument,
        requiresSimpleEditHint: Bool
    ) -> ActiveBlockRenderPatch? {
        guard requiresSimpleEditHint,
              oldDocument.footnotes.isEmpty,
              newDocument.footnotes.isEmpty,
              oldDocument.blocks.count == newDocument.blocks.count,
              let oldActiveBlockID,
              let activeBlockID,
              let caretInActiveBlock,
              let oldIndex = oldDocument.blocks.firstIndex(where: { $0.id == oldActiveBlockID }),
              let newIndex = newDocument.blocks.firstIndex(where: { $0.id == activeBlockID }),
              oldIndex == newIndex,
              let oldEditableRange = oldRendered.activeEditableRange,
              let oldBlockRange = oldRendered.blockRanges[oldActiveBlockID],
              let newSlice = newDocument.source.substring(in: newDocument.blocks[newIndex].range),
              separatorSignature(oldDocument.blocks[oldIndex].kind) == separatorSignature(newDocument.blocks[newIndex].kind),
              isActiveBlockPatchable(oldDocument.blocks[oldIndex].kind),
              isActiveBlockPatchable(newDocument.blocks[newIndex].kind)
        else { return nil }

        var ranges: [BlockID: NSRange] = [:]
        let replacement = QuoinPerformanceTrace.measure(
            "render.activeBlockPatch.fragment",
            metadata: "block_utf8=\(newDocument.blocks[newIndex].range.length)"
        ) {
            renderer.renderEditableSourceFragment(
                newSlice, caretOffset: caretInActiveBlock, kind: newDocument.blocks[newIndex].kind)
        }
        let delta = replacement.length - oldEditableRange.length

        for index in newDocument.blocks.indices {
            let newBlock = newDocument.blocks[index]
            let oldBlock = oldDocument.blocks[index]
            if index == newIndex {
                ranges[newBlock.id] = NSRange(
                    location: oldBlockRange.location,
                    length: oldBlockRange.length + delta
                )
            } else {
                guard oldBlock.id == newBlock.id,
                      let oldRange = oldRendered.blockRanges[oldBlock.id]
                else { return nil }
                let shift = index > newIndex ? delta : 0
                ranges[newBlock.id] = NSRange(
                    location: oldRange.location + shift,
                    length: oldRange.length
                )
            }
        }

        return ActiveBlockRenderPatch(
            storagePatch: RenderStoragePatch(oldRange: oldEditableRange, replacement: replacement),
            blockRanges: ranges,
            activeEditableRange: NSRange(location: oldEditableRange.location, length: replacement.length),
            activeSourceText: newSlice,
            oldActiveBlockID: oldActiveBlockID
        )
    }

    private func isActiveBlockPatchable(_ kind: BlockKind) -> Bool {
        switch kind {
        case .tableOfContents, .list, .blockQuote, .callout:
            return false
        default:
            return true
        }
    }

    private func separatorSignature(_ kind: BlockKind) -> (isCard: Bool, isHeading: Bool) {
        let isHeading: Bool
        if case .heading = kind {
            isHeading = true
        } else {
            isHeading = false
        }

        let isCard: Bool
        switch kind {
        case .codeBlock, .mermaid, .table, .callout, .frontMatter, .htmlBlock:
            isCard = true
        default:
            isCard = false
        }
        return (isCard, isHeading)
    }

    // MARK: - Image drop

    static let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "gif", "heic", "webp", "tiff", "bmp"]

    /// Drag-dropped image: copy the asset next to the document (assets/),
    /// insert `![](assets/…)` at the caret (or document end). Every file step
    /// can fail; a failure is surfaced as a banner rather than swallowed, so
    /// the user never believes an image landed when it didn't.
    func insertImage(from sourceURL: URL) {
        guard let session,
              let docURL = fileURL,
              Self.imageExtensions.contains(sourceURL.pathExtension.lowercased())
        else { return }

        let assetsFolder = docURL.deletingLastPathComponent().appendingPathComponent("assets", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: assetsFolder, withIntermediateDirectories: true)
        } catch {
            reportFailure("Couldn't create the assets folder for the image.")
            return
        }

        // Silent-suffix collision handling, same rule as document names.
        let destination = Library.uniqueURL(
            baseName: sourceURL.deletingPathExtension().lastPathComponent,
            extension: sourceURL.pathExtension, in: assetsFolder
        )
        do {
            try FileManager.default.copyItem(at: sourceURL, to: destination)
        } catch {
            reportFailure("Couldn't copy “\(sourceURL.lastPathComponent)” into the library.")
            return
        }

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
            do {
                let newDocument = try await session.applyEdit(edit, publishSnapshot: false)
                QuoinPerformanceTrace.measure("model.restoreCaret.imageInsert") {
                    self.restoreCaret(in: newDocument, atUTF8Offset: offset + markdown.utf8.count)
                }
            } catch {
                // The copy succeeded but the reference didn't land — remove the
                // orphaned asset so a retry doesn't accumulate copies.
                try? FileManager.default.removeItem(at: destination)
                self.reportFailure("Couldn't insert the image into the document.")
            }
        }
    }

    // MARK: - Checkbox & anchors

    func toggleTask(markerOffset: Int) {
        guard let session else { return }
        Task {
            do {
                try await session.toggleTask(markerRange: ByteRange(offset: markerOffset, length: 3))
            } catch SessionError.taskNotTogglable {
                // The file shifted under the click; the session republished the
                // fresh state (see DocumentSession.toggleTask). Tell the user
                // their tap didn't apply so they can re-tap on current content.
                self.reportFailure("The document changed on disk, so the checkbox wasn't toggled — it's been refreshed.")
            } catch {
                self.reportFailure("Couldn't save the checkbox change.")
            }
        }
    }

    // MARK: - Non-blocking action failures

    func dismissActionFailure() {
        actionFailureTask?.cancel()
        actionFailure = nil
    }

    private func reportFailure(_ message: String) {
        actionFailure = ActionFailure(message: message)
        actionFailureTask?.cancel()
        actionFailureTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(6))
            guard !Task.isCancelled else { return }
            self?.actionFailure = nil
        }
    }

    func blockID(forSlug slug: String) -> BlockID? {
        slugToBlock[slug]
    }
}
