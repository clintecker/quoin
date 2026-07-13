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
    /// The tab's last scroll + selection, stashed when its editor is torn down
    /// on a tab switch and handed back when the tab is shown again (#22). Lives
    /// here because the model outlives the transient editor in the store.
    @ObservationIgnored var savedViewport: ViewportSnapshot?

    @ObservationIgnored private var session: DocumentSession?
    @ObservationIgnored private var snapshotTask: Task<Void, Never>?
    @ObservationIgnored private var renderer = AttributedRenderer()
    @ObservationIgnored private var renameTask: Task<Void, Never>?
    @ObservationIgnored private var actionFailureTask: Task<Void, Never>?
    @ObservationIgnored private var editPipelineTask: Task<Void, Never>?
    @ObservationIgnored private var latestEditGeneration = 0
    /// Mirror of the session's non-edit adoption counter, taken from the
    /// snapshot each rendered document was built from. Every edit this
    /// model computes is stamped with it, so an external reload that lands
    /// between computing an edit and the session applying it makes the
    /// session REJECT the edit instead of splicing stale offsets (launch
    /// ledger, data integrity #14).
    @ObservationIgnored private var sessionContentRevision = 0
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
        } else if let fileURL, FileManager.default.fileExists(atPath: fileURL.path) {
            // The file EXISTS but couldn't be read (encoding, permissions,
            // un-downloaded cloud placeholder). Binding a blank session to
            // the real URL meant the first keystroke autosaved ~1 byte
            // over the user's document — silent total data loss (launch
            // audit, senior review BLOCKER #1). Detach from the file:
            // nothing this window does can touch it.
            session = DocumentSession(source: "", fileURL: nil)
            reportFailure(
                "Couldn't read “\(fileURL.lastPathComponent)” (encoding or permissions). "
                + "Editing is detached from the file to protect it.",
                sticky: true)
        } else {
            session = DocumentSession(source: initialText, fileURL: fileURL)
        }
        self.session = session

        // Termination flush registry: ⌘Q must drain every live session's
        // autosave before the process dies (launch audit BLOCKER #4).
        Self.registerLiveSession(session)

        snapshotTask = Task { [weak self] in
            await session.setConflictHandler { diskSource in
                Task { @MainActor [weak self] in
                    self?.conflictDiskSource = diskSource
                }
            }
            await session.setSaveFailureHandler { message in
                Task { @MainActor [weak self] in
                    self?.reportFailure(message, sticky: true)
                }
            }
            await session.startWatching()
            let snapshots = await session.revisionedSnapshots()
            for await snapshot in snapshots {
                await self?.ingest(snapshot.document, contentRevision: snapshot.contentRevision)
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
    private func ingest(_ document: QuoinDocument, contentRevision: Int) {
        // Track the adoption revision even for echoes, so edit stamping
        // always reflects the newest snapshot this model has seen.
        sessionContentRevision = contentRevision
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
                    patchBaseLength: baseLength,
                    previewPanel: renderer.activePreviewPanel(),
                    revealVerbatimCode: renderer.activeRevealVerbatimCode()
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
                    revision: nextRevision(),
                    previewPanel: next.previewPanel,
                    revealVerbatimCode: next.revealVerbatimCode
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

    /// Activates a block for editing. `caretHint` carries the caret's target
    /// offset tagged with its coordinate space (`CaretHint`): `.rendered`
    /// offsets are aligned to the source through the projection mapper
    /// (the source hides characters the projection dropped — hard-break
    /// spaces, `**`, `### `, entity source); `.source` offsets (embed
    /// bodies, 1:1 by construction) are used verbatim — running them
    /// through the mapper again landed the caret early by the header run's
    /// width. `pendingInsertion` is a keystroke that triggered this
    /// activation by landing on the rendered block: it is applied at the
    /// mapped caret through the normal session edit path, so the character
    /// is inserted, not swallowed.
    func activateBlock(_ id: BlockID?, caretHint: CaretHint? = nil, pendingInsertion: String? = nil) {
        guard id != activeBlockID else { return }
        let previousActiveID = activeBlockID
        // Fence healing on commit-while-broken (ledger senior #10): a
        // fenced block committed without its closing fence would swallow
        // every following block. Close it with an ORDINARY session edit —
        // undoable, byte-honest — before the projection flips back.
        if let closing = previousActiveID,
           let block = document.blocks.first(where: { $0.id == closing }),
           let slice = document.source.substring(in: block.range),
           let suffix = FenceHealing.healingSuffix(for: slice, kind: block.kind) {
            applyAbsolute(
                SourceEdit(
                    range: ByteRange(offset: block.range.offset + block.range.length, length: 0),
                    replacement: suffix),
                caretUTF8: nil)
        }
        activeBlockID = id
        // Each editing session holds its own last-good preview; a stale
        // artifact from the previous session must never appear over a
        // different block's source.
        renderer.resetActivePreview()
        if let id, let block = document.blocks.first(where: { $0.id == id }),
           let slice = document.source.substring(in: block.range) {
            let sourceLength = slice.utf16.count
            switch caretHint {
            case .source(let offset):
                caretInActiveBlock = min(max(0, offset), sourceLength)
            case .rendered(let offset):
                if let renderedRange = rendered.blockRanges[id],
                   renderedRange.location + renderedRange.length <= rendered.attributed.length {
                    let renderedText = (rendered.attributed.string as NSString)
                        .substring(with: renderedRange)
                    let mapped = EditMapping.sourceOffset(
                        forRenderedOffset: offset,
                        renderedText: renderedText,
                        sourceText: slice
                    )
                    caretInActiveBlock = min(max(0, mapped), sourceLength)
                } else {
                    caretInActiveBlock = min(max(0, offset), sourceLength)
                }
            case nil:
                caretInActiveBlock = sourceLength
            }
        } else {
            caretInActiveBlock = nil
        }
        caretGeneration += 1
        if QuoinPerformanceTrace.isEnabled, let id,
           let block = document.blocks.first(where: { $0.id == id }),
           let slice = document.source.substring(in: block.range) {
            let head = slice.prefix(500).replacingOccurrences(of: "\n", with: "⏎")
            QuoinPerformanceTrace.log(
                "model.activate", startedAt: DispatchTime.now().uptimeNanoseconds,
                metadata: "kind=\(String(describing: block.kind).prefix(24)) sliceLen=\(slice.count) head=<<\(head)>>")
        }
        // A flip changes only the flipped blocks' PROJECTION — the document
        // is untouched. Patch just those fragments into the live storage
        // instead of re-rendering the whole document (which costs ~half a
        // second at novel length even with a warm fragment cache).
        if !applyActivationFlipPatch(from: previousActiveID, to: id) {
            rerender()
        }
        replayPendingInsertion(pendingInsertion)
    }

    /// The keystroke that opened the block, applied at the freshly mapped
    /// caret through the ordinary edit path — one async round-trip later
    /// the revealed source carries the character with the caret after it,
    /// exactly as if the block had been open when the key went down. Runs
    /// AFTER the flip publish so the edit's splice hint and block-local
    /// fast path see the revealed projection they patch against.
    private func replayPendingInsertion(_ insertion: String?) {
        guard let insertion, !insertion.isEmpty,
              let id = activeBlockID,
              let caret = caretInActiveBlock,
              let block = document.blocks.first(where: { $0.id == id }),
              let slice = document.source.substring(in: block.range),
              let caretBytes = EditMapping.utf8Offset(inText: slice, utf16Offset: caret)
        else { return }
        applyEdit(relativeRange: ByteRange(offset: caretBytes, length: 0), replacement: insertion)
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
            patchBaseLength: baseLength,
            previewPanel: newID != nil ? renderer.activePreviewPanel() : nil,
            revealVerbatimCode: newID != nil && renderer.activeRevealVerbatimCode()
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
        applyAbsolute(edit, caretUTF8: caretUTF8, spliceHint: spliceHint)
    }

    /// Block-granularity commands from the context menu (ideas #9/10/11):
    /// byte-exact splices built in QuoinCore, routed through the normal
    /// session pipeline (undo, losslessness, re-projection all apply).
    func perform(_ command: BlockCommand, on id: BlockID) {
        guard let index = document.blocks.firstIndex(where: { $0.id == id }) else { return }
        let edit: SourceEdit?
        switch command {
        case .moveUp:
            edit = BlockEditing.moveEdit(
                source: document.source, blocks: document.blocks, blockIndex: index, direction: .up)
        case .moveDown:
            edit = BlockEditing.moveEdit(
                source: document.source, blocks: document.blocks, blockIndex: index, direction: .down)
        case .duplicate:
            edit = BlockEditing.duplicateEdit(
                source: document.source, blocks: document.blocks, blockIndex: index)
        case .delete:
            edit = BlockEditing.deleteEdit(
                source: document.source, blocks: document.blocks, blockIndex: index)
        case .addTableRow, .addTableColumn:
            let block = document.blocks[index]
            guard let slice = document.source.substring(in: block.range),
                  let grown = command == .addTableRow
                    ? TableEditing.addingRow(to: slice)
                    : TableEditing.addingColumn(to: slice)
            else { return }
            edit = SourceEdit(range: block.range, replacement: grown)
        }
        guard let edit else { return }
        // nil caret: keep the current reveal state — a block command must
        // not fling the caret or open the block it touched.
        applyAbsolute(edit, caretUTF8: nil)
    }

    /// Typing into a document with no blocks (freshly created, empty):
    /// append the text; the first block materializes around the caret.
    /// Without this, ⌘N produced an untypeable blank pane (launch audit
    /// BLOCKER #1).
    func insertIntoEmptyDocument(_ text: String) {
        guard document.blocks.isEmpty else { return }
        let end = document.source.utf8.count
        applyAbsolute(
            SourceEdit(range: ByteRange(offset: end, length: 0), replacement: text),
            caretUTF8: end + text.utf8.count)
    }

    /// The shared edit pipeline: serialize through the session, then adopt
    /// the new document with caret/projection bookkeeping.
    private func applyAbsolute(_ edit: SourceEdit, caretUTF8: Int?, spliceHint: RenderSpliceHint? = nil) {
        guard let session else { return }
        let absolute = edit.range
        let replacement = edit.replacement
        // Stamp NOW, synchronously: this is the revision of the content the
        // edit's offsets were computed against. The session rejects the
        // edit if an external reload replaces the content before the
        // pipeline task applies it (ledger #14).
        let baseRevision = sessionContentRevision
        latestEditGeneration += 1
        let generation = latestEditGeneration
        let previousEditTask = editPipelineTask

        editPipelineTask = Task { [weak self] in
            await previousEditTask?.value
            guard let self else { return }
            do {
                let newDocument = try await QuoinPerformanceTrace.measure(
                    "model.session.applyEdit",
                    metadata: "range_offset=\(absolute.offset) replacement_bytes=\(replacement.utf8.count)"
                ) {
                    try await session.applyEdit(edit, baseRevision: baseRevision, publishSnapshot: false)
                }
                guard generation == self.latestEditGeneration else { return }
                QuoinPerformanceTrace.measure("model.restoreCaret") {
                    self.restoreCaret(in: newDocument, atUTF8Offset: caretUTF8, spliceHint: spliceHint)
                }
                self.scheduleH1Rename(for: newDocument)
            } catch {
                await self.recoverFromFailedEdit(error, generation: generation)
            }
            if generation == self.latestEditGeneration {
                self.editPipelineTask = nil
            }
        }
    }

    /// A session edit was rejected or failed (ledger, data integrity #8).
    /// The old behavior wedged typing until the coordinator's 2s watchdog
    /// fired and then silently DISCARDED the queued keystrokes. Instead:
    /// adopt the session's current truth and republish the projection with
    /// a caret echo NOW — the echo unwedges the coordinator immediately,
    /// and its queued keystrokes replay against the fresh state through
    /// the ordinary pipeline (they are content + order; each applies at
    /// the freshly restored caret). Only the rejected edit itself cannot
    /// be replayed (its range is stale by definition); its loss — and the
    /// loss of the queue when the active block itself is gone — is
    /// surfaced as a banner, never swallowed.
    private func recoverFromFailedEdit(_ error: Error, generation: Int) async {
        guard let session else { return }
        let truth = await session.document
        sessionContentRevision = await session.contentRevision
        // Superseded submissions stay quiet: the newest one (or its own
        // recovery) owns the projection and the banner.
        guard generation == latestEditGeneration else { return }
        let hadActiveBlock = activeBlockID != nil
        restoreCaret(in: truth, atUTF8Offset: nil)
        let replayImpossible = hadActiveBlock && activeBlockID == nil
        if case SessionError.staleEditBase = error {
            reportFailure(replayImpossible
                ? "The document changed underneath your typing — recent keystrokes weren't applied."
                : "The document changed underneath your typing — the last keystroke wasn't applied.")
        } else {
            reportFailure("Couldn't apply the last edit — the view has been refreshed.")
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
        performHistoryOperation { try await $0.undo() }
    }

    func redo() {
        performHistoryOperation { try await $0.redo() }
    }

    /// Undo/redo serialized with the edit pipeline (launch ledger, data
    /// integrity #7). A ⌘Z issued while a keystroke's round-trip was still
    /// in flight used to hop onto the session actor in NONDETERMINISTIC
    /// order — when the undo won, it spliced first and the in-flight
    /// keystroke then applied at pre-undo offsets, corrupting the source.
    /// History operations now JOIN the same FIFO pipeline the keystrokes
    /// flow through, so they run strictly after every edit submitted
    /// before them. (The session's `contentRevision` bump on undo/redo is
    /// the backstop: an edit stamped against pre-undo content is rejected
    /// as `staleEditBase` rather than spliced.)
    private func performHistoryOperation(
        _ operation: @escaping @Sendable (DocumentSession) async throws -> QuoinDocument?
    ) {
        guard let session else { return }
        latestEditGeneration += 1
        let generation = latestEditGeneration
        let previousEditTask = editPipelineTask
        editPipelineTask = Task { [weak self] in
            await previousEditTask?.value
            guard let self else { return }
            let newDocument = (try? await operation(session)) ?? nil
            // Adopt the bumped revision stamp immediately — the ingest of
            // the published snapshot is asynchronous, and a keystroke typed
            // in that window must not be stamped (and rejected) as stale.
            self.sessionContentRevision = await session.contentRevision
            guard generation == self.latestEditGeneration else { return }
            if let newDocument {
                QuoinPerformanceTrace.measure("model.restoreCaret.history") {
                    self.restoreCaret(in: newDocument, atUTF8Offset: nil)
                }
            }
            if generation == self.latestEditGeneration {
                self.editPipelineTask = nil
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
        let revealed = QuoinPerformanceTrace.measure(
            "render.activeBlockPatch.fragment",
            metadata: "block_utf8=\(newDocument.blocks[newIndex].range.length)"
        ) {
            renderer.renderEditableSourceFragment(
                newSlice, caretOffset: caretInActiveBlock,
                block: newDocument.blocks[newIndex], document: newDocument)
        }
        // The patch replaces the whole OLD fragment (block range minus its
        // trailing separator) — not just the editable region: the
        // preview-anchored reveal (mermaid/math) leads the fragment with a
        // live preview that every keystroke must refresh.
        let separatorLength = oldIndex < oldDocument.blocks.count - 1
            ? renderer.separatorLength(
                after: oldDocument.blocks[oldIndex].kind,
                before: oldDocument.blocks[oldIndex + 1].kind)
            : 0
        let oldFragmentLength = oldBlockRange.length - separatorLength
        guard oldFragmentLength >= 0 else { return nil }
        let oldFragmentRange = NSRange(location: oldBlockRange.location, length: oldFragmentLength)
        let replacement = revealed.attributed
        let delta = replacement.length - oldFragmentLength

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
            storagePatch: RenderStoragePatch(oldRange: oldFragmentRange, replacement: replacement),
            blockRanges: ranges,
            activeEditableRange: NSRange(
                location: oldBlockRange.location + revealed.editableRange.location,
                length: revealed.editableRange.length),
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
        let baseRevision = sessionContentRevision
        Task {
            do {
                let newDocument = try await session.applyEdit(
                    edit, baseRevision: baseRevision, publishSnapshot: false)
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

    private func reportFailure(_ message: String, sticky: Bool = false) {
        actionFailure = ActionFailure(message: message)
        actionFailureTask?.cancel()
        guard !sticky else { return } // data-integrity failures never auto-dismiss
        actionFailureTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(6))
            guard !Task.isCancelled else { return }
            self?.actionFailure = nil
        }
    }

    func blockID(forSlug slug: String) -> BlockID? {
        slugToBlock[slug]
    }

    // MARK: - Termination flush (launch audit BLOCKER #4)

    /// Weak registry of live sessions so app termination can drain every
    /// pending autosave before the process exits — SwiftUI's onDisappear
    /// is not reliably delivered at ⌘Q, and a detached flush task races
    /// process death.
    private static var liveSessions: [() -> DocumentSession?] = []

    static func registerLiveSession(_ session: DocumentSession) {
        liveSessions.removeAll { $0() == nil }
        liveSessions.append { [weak session] in session }
    }

    /// Synchronously-awaitable flush of every live session.
    static func flushAllSessions() async {
        for accessor in liveSessions {
            guard let session = accessor() else { continue }
            try? await session.saveNow()
        }
        liveSessions.removeAll { $0() == nil }
    }

    /// Main-actor-synchronous snapshot for the termination path: the
    /// delegate grabs the sessions HERE (on main, where the registry
    /// lives) and flushes them on a detached executor — a plain
    /// MainActor Task may never run in the terminateLater runloop mode,
    /// which is exactly how the first flush implementation lost data.
    static func liveSessionSnapshot() -> [DocumentSession] {
        liveSessions.compactMap { $0() }
    }
}
