#if canImport(AppKit)
import AppKit
import SwiftUI
import QuoinCore

/// Format commands the window can send to the editor's selection.
public enum FormatCommand: Equatable, Sendable {
    case bold, italic, highlight, link
}

/// Block-granularity commands from the context menu (ideas #9/#10/#11);
/// the host applies them as byte-exact source edits (BlockEditing).
public enum BlockCommand: Sendable {
    case moveUp, moveDown, duplicate, delete, addTableRow, addTableColumn
}

/// Where the caret should land when a block activates, tagged with the
/// coordinate space the offset lives in. The two producers measure in
/// different spaces — prose clicks yield an offset into the block's
/// RENDERED text (which hides delimiters the projection dropped), while
/// embed bodies map 1:1 into the SOURCE slice via `embedSourceStart` — and
/// funneling both through a bare `Int` let a source offset get re-mapped
/// as if it were rendered, landing the caret a few characters early in
/// code bodies. The enum makes the space explicit at every call site.
public enum CaretHint: Equatable, Sendable {
    /// Offset into the block's rendered (projected) text; the model aligns
    /// it to the source through `EditMapping.sourceOffset`.
    case rendered(Int)
    /// Offset directly into the block's source slice; used verbatim.
    case source(Int)
}

/// The reading surface: a TextKit 2 `NSTextView` wrapped for SwiftUI.
///
/// TextKit 2 does viewport-based layout — only visible content is laid out —
/// which is what keeps very large documents scrolling at full frame rate.
/// The view is read-only and selectable; interaction happens through link
/// plumbing (web links, internal anchors, task checkboxes).
public struct MarkdownReaderView: NSViewRepresentable {

    public let rendered: RenderedDocument
    public let theme: Theme
    /// Live search query; matches are highlighted with rendering attributes
    /// (no layout impact, original backgrounds untouched).
    public let searchQuery: String
    /// Which match is "current" (⌘G cycling); scrolled into view.
    public let activeMatchOrdinal: Int
    /// TOC navigation target; `scrollGeneration` bumps to re-apply, so
    /// clicking the same heading twice still scrolls.
    public let scrollTarget: BlockID?
    public let scrollGeneration: Int
    public let onTaskToggle: (Int) -> Void
    public let onMatchCount: (Int) -> Void
    /// Resolves an internal `#anchor` link to a block.
    public let anchorResolver: (String) -> BlockID?
    /// Fires when the topmost visible block changes (status-bar section tracking).
    public let onTopBlockChange: (BlockID?) -> Void

    // MARK: Editing (nil callbacks = read-only reader)

    /// A keystroke inside the active block's revealed source. The range is
    /// relative to the active block's source slice (UTF-8 bytes); the app
    /// converts to an absolute `SourceEdit` and routes it through the
    /// session. `caretDelta` overrides where the caret lands (UTF-8 bytes
    /// from the range start; nil = end of replacement) — smart pairs use it
    /// to park the caret between the inserted delimiters.
    public let onEditIntent: ((_ relativeRange: ByteRange, _ replacement: String, _ caretDelta: Int?) -> Void)?
    /// Caret entered a block (nil id = deactivate, Esc). The `String?` is a
    /// pending insertion: the keystroke that triggered the activation by
    /// landing on a rendered block. The model applies it at the mapped caret
    /// position through the normal session edit path, so typing on a
    /// rendered block reveals the source AND inserts the character — the
    /// keystroke is never swallowed.
    public let onActivateBlock: ((BlockID?, CaretHint?, String?) -> Void)?
    /// Caret position (UTF-16, relative to the active block's source text)
    /// to restore after a re-render; `caretGeneration` bumps to re-apply.
    public let caretInActiveBlock: Int?
    public let caretGeneration: Int
    /// Format command to apply to the current selection (⌘B/⌘I/⌘K/⇧⌘H);
    /// `formatGeneration` bumps to fire.
    public let formatCommand: FormatCommand?
    public let formatGeneration: Int
    /// ⌘↩ / Format ▸ Edit Source: bumps to toggle the block under the
    /// caret between rendered and revealed source.
    public let editSourceToggleGeneration: Int
    /// A block's markdown source slice, for the context menu's Copy
    /// Markdown Source (the render layer holds only the projection).
    public let blockSourceProvider: ((BlockID) -> String?)?
    /// Focus mode: every block except the caret's recedes to a fraction
    /// of its ink. Rendering attributes only — no reflow, no re-render.
    public let focusModeEnabled: Bool
    /// Typewriter scrolling: while typing, the caret's line stays pinned
    /// at a fixed height (~40% of the viewport) instead of drifting to
    /// the fold.
    public let typewriterEnabled: Bool
    /// Fires before an in-document anchor jump with the block at the top
    /// of the viewport — the host records it as back/forward history.
    public let onAnchorJump: ((BlockID?) -> Void)?
    /// Block actions from the context menu (move/duplicate/delete/table).
    public let onBlockCommand: ((BlockID, BlockCommand) -> Void)?
    /// Typing into a document with NO blocks (freshly created, empty):
    /// the host appends the text and the first block materializes around
    /// the caret. Without this, ⌘N produced an untypeable blank pane.
    public let onEmptyDocumentInsert: ((String) -> Void)?
    /// Sentence-granularity focus (iA-Writer-style): dim to the caret's
    /// SENTENCE inside the current block. Only meaningful with focus mode.
    public let focusSentenceScope: Bool
    /// Scroll position as a 0…1 fraction of the document (reading
    /// progress hairline).
    public let onScrollProgress: ((Double) -> Void)?

    public init(
        rendered: RenderedDocument,
        theme: Theme = Theme(),
        searchQuery: String = "",
        activeMatchOrdinal: Int = 0,
        scrollTarget: BlockID? = nil,
        scrollGeneration: Int = 0,
        onTaskToggle: @escaping (Int) -> Void = { _ in },
        onMatchCount: @escaping (Int) -> Void = { _ in },
        anchorResolver: @escaping (String) -> BlockID? = { _ in nil },
        onTopBlockChange: @escaping (BlockID?) -> Void = { _ in },
        onEditIntent: ((_ relativeRange: ByteRange, _ replacement: String, _ caretDelta: Int?) -> Void)? = nil,
        onActivateBlock: ((BlockID?, CaretHint?, String?) -> Void)? = nil,
        caretInActiveBlock: Int? = nil,
        caretGeneration: Int = 0,
        formatCommand: FormatCommand? = nil,
        formatGeneration: Int = 0,
        editSourceToggleGeneration: Int = 0,
        blockSourceProvider: ((BlockID) -> String?)? = nil,
        focusModeEnabled: Bool = false,
        typewriterEnabled: Bool = false,
        onAnchorJump: ((BlockID?) -> Void)? = nil,
        onScrollProgress: ((Double) -> Void)? = nil,
        onBlockCommand: ((BlockID, BlockCommand) -> Void)? = nil,
        focusSentenceScope: Bool = false,
        onEmptyDocumentInsert: ((String) -> Void)? = nil
    ) {
        self.rendered = rendered
        self.theme = theme
        self.searchQuery = searchQuery
        self.activeMatchOrdinal = activeMatchOrdinal
        self.scrollTarget = scrollTarget
        self.scrollGeneration = scrollGeneration
        self.onTaskToggle = onTaskToggle
        self.onMatchCount = onMatchCount
        self.anchorResolver = anchorResolver
        self.onTopBlockChange = onTopBlockChange
        self.onEditIntent = onEditIntent
        self.onActivateBlock = onActivateBlock
        self.caretInActiveBlock = caretInActiveBlock
        self.caretGeneration = caretGeneration
        self.formatCommand = formatCommand
        self.formatGeneration = formatGeneration
        self.editSourceToggleGeneration = editSourceToggleGeneration
        self.blockSourceProvider = blockSourceProvider
        self.focusModeEnabled = focusModeEnabled
        self.typewriterEnabled = typewriterEnabled
        self.onAnchorJump = onAnchorJump
        self.onScrollProgress = onScrollProgress
        self.onBlockCommand = onBlockCommand
        self.focusSentenceScope = focusSentenceScope
        self.onEmptyDocumentInsert = onEmptyDocumentInsert
    }

    public func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    public func makeNSView(context: Context) -> NSScrollView {
        // Explicit TextKit 2 stack.
        let contentStorage = NSTextContentStorage()
        let layoutManager = NSTextLayoutManager()
        contentStorage.addTextLayoutManager(layoutManager)
        let container = NSTextContainer(size: NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude))
        container.widthTracksTextView = true
        layoutManager.textContainer = container

        let textView = QuoinTextView(frame: .zero, textContainer: container)
        // Editable when editing callbacks are wired; every keystroke is
        // gated through shouldChangeTextIn and routed to the session — the
        // text storage itself is never the source of truth.
        textView.isEditable = onEditIntent != nil
        textView.allowsUndo = false // undo lives in DocumentSession
        textView.isSelectable = true
        textView.isRichText = true
        textView.textContainerInset = NSSize(width: theme.contentInset, height: theme.contentInset)
        textView.autoresizingMask = [.width]
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        // Default maxSize is the initial frame (zero) — without lifting it the
        // view can never grow taller than the viewport, so nothing scrolls.
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude,
                                  height: CGFloat.greatestFiniteMagnitude)
        textView.delegate = context.coordinator
        textView.drawsBackground = true
        textView.backgroundColor = theme.canvas
        textView.linkTextAttributes = [
            .foregroundColor: theme.linkColor,
            .cursor: NSCursor.pointingHand,
        ]

        let scrollView = NSScrollView()
        scrollView.documentView = textView
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = true
        scrollView.backgroundColor = theme.canvas

        // Track scrolling so the status bar can show the current section.
        scrollView.contentView.postsBoundsChangedNotifications = true
        context.coordinator.scrollObserver = NotificationCenter.default.addObserver(
            forName: NSView.boundsDidChangeNotification,
            object: scrollView.contentView,
            queue: .main
        ) { [weak coordinator = context.coordinator] _ in
            coordinator?.reportTopBlock()
        }

        context.coordinator.textView = textView
        context.coordinator.flipTransition = FlipTransitionController(
            scrollView: scrollView, textView: textView)
        textView.onDoubleClick = { [weak coordinator = context.coordinator] index in
            coordinator?.activateEmbedBlock(atCharIndex: index) ?? false
        }
        textView.onDoneChipClick = { [weak coordinator = context.coordinator] in
            guard let coordinator, let textView = coordinator.textView,
                  coordinator.parent.rendered.activeBlockID != nil else { return }
            // ✓ done: commit and close, caret back at its rendered image —
            // the same contract as Escape.
            coordinator.captureDeactivationCaret(in: textView)
            coordinator.parent.onActivateBlock?(nil, nil, nil)
        }
        textView.onContextMenu = { [weak coordinator = context.coordinator] index, menu in
            coordinator?.populateContextMenu(menu, atCharIndex: index)
        }
        textView.onEditingFrameGeometry = { [weak coordinator = context.coordinator] frameBox in
            coordinator?.updatePreviewPanel(editingFrame: frameBox)
        }
        textView.onSmartPaste = { [weak coordinator = context.coordinator] in
            coordinator?.handleSmartPaste() ?? false
        }
        textView.onLinkHover = { [weak coordinator = context.coordinator] url, rect in
            coordinator?.handleLinkHover(url: url, at: rect)
        }
        textView.updateTrackingAreas()
        return scrollView
    }

    public func updateNSView(_ scrollView: NSScrollView, context: Context) {
        let coordinator = context.coordinator
        coordinator.parent = self
        guard let textView = coordinator.textView else { return }

        // View-level chrome follows the theme on every update, so an
        // appearance flip (dark/light) recolors the canvas along with the
        // re-rendered content — makeNSView's values would otherwise stick
        // for the window's lifetime.
        if textView.backgroundColor != theme.canvas {
            textView.backgroundColor = theme.canvas
            scrollView.backgroundColor = theme.canvas
            textView.linkTextAttributes = [
                .foregroundColor: theme.linkColor,
                .cursor: NSCursor.pointingHand,
            ]
        }

        // THE viewport invariant: the thing the user touched must not move.
        // On a flip (activate/deactivate), the anchor is the LINE THE CARET
        // IS ON — the clicked row of a table, the list item the arrow key
        // just entered — captured before the projection changes and pinned
        // back after, no matter how the block's height changes around it.
        // Only when no caret applies (closing a block to nothing) does the
        // anchor fall back to the flipped block's top edge.
        let flipPending = rendered.activeBlockID != coordinator.lastActiveBlockID
        let caretRestorePending = caretInActiveBlock != nil
            && caretGeneration != coordinator.appliedCaretGeneration
            && rendered.activeEditableRange != nil
        var caretLineAnchorY: CGFloat?
        var flipMotionID: BlockID?

        if coordinator.appliedRevision != rendered.revision,
           let storage = textView.textContentStorage?.textStorage {
            let anchorID = coordinator.topVisibleBlockID(in: textView)
            let viewport = scrollView.contentView.bounds.height
            if flipPending, caretRestorePending {
                let selection = min(textView.selectedRange().location, max(0, storage.length - 1))
                if let screenY = coordinator.lineScreenY(at: selection, in: textView),
                   screenY > -viewport, screenY < viewport * 2 {
                    caretLineAnchorY = screenY
                }
                QuoinPerformanceTrace.log(
                    "anchor.capture", startedAt: DispatchTime.now().uptimeNanoseconds,
                    metadata: "sel=\(selection) anchorY=\(caretLineAnchorY.map { Int($0) } ?? -999) clipY=\(Int(scrollView.contentView.bounds.origin.y))")
            } else if flipPending {
                QuoinPerformanceTrace.log(
                    "anchor.capture.skipped", startedAt: DispatchTime.now().uptimeNanoseconds,
                    metadata: "caretRestorePending=\(caretRestorePending) caretInActive=\(caretInActiveBlock ?? -1) gen=\(caretGeneration)")
            }
            // Fallback anchor for caret-less flips (Esc closing a block).
            var flipAnchor: (id: BlockID, screenY: CGFloat)?
            if flipPending, caretLineAnchorY == nil,
               let flipID = rendered.activeBlockID ?? coordinator.lastActiveBlockID,
               let oldRange = coordinator.blockRanges[flipID],
               let screenY = coordinator.blockTopScreenY(oldRange, in: textView) {
                // Only pin when the flip is near the viewport — a far-away
                // programmatic flip shouldn't drag the scroll position to it.
                if screenY > -viewport * 2, screenY < viewport * 2 {
                    flipAnchor = (flipID, screenY)
                }
            }
            // Motion (embed-editing brief, Phase 3): freeze the current
            // pixels before the splice so the flip can animate. A non-flip
            // projection (typing) instead truncates any transition still
            // running — a storage mutation invalidates frozen pixels.
            if flipPending,
               let flipID = rendered.activeBlockID ?? coordinator.lastActiveBlockID,
               let oldRange = coordinator.blockRanges[flipID],
               let oldRect = coordinator.blockScreenRect(oldRange, in: textView),
               oldRect.minY < viewport, oldRect.maxY > 0 {
                flipMotionID = flipID
                coordinator.flipTransition?.capture(oldBlockRect: oldRect)
            } else {
                coordinator.flipTransition?.cancel()
            }
            coordinator.suppressSelectionCallback = true
            let preSelection = textView.selectedRange()
            let preLength = storage.length
            // Splice only the changed span into the live storage rather than
            // replacing the whole document. TextKit 2 then re-lays-out just
            // that region, so unchanged content keeps its exact layout and the
            // scroll offset never jumps.
            let application = QuoinPerformanceTrace.measure(
                "render.textkit.splice",
                metadata: "old_utf16=\(storage.length) new_utf16=\(rendered.attributed.length) hinted=\(rendered.spliceHint != nil) patched=\(rendered.storagePatches.count)"
            ) {
                Coordinator.applyProjection(rendered, to: storage)
            }
            let splicedRange: NSRange?
            switch application {
            case .patched(let patches):
                splicedRange = patches.first.map {
                    NSRange(location: $0.oldRange.location, length: $0.replacement.length)
                }
                // Bounded edits: adjust the decoration runs in place instead
                // of rescanning the whole document's attributes on the next
                // draw.
                for patch in patches {
                    (textView as? QuoinTextView)?.noteStorageEdit(
                        oldRange: patch.oldRange, newLength: patch.replacement.length)
                }
            case .spliced(let range):
                splicedRange = range
                // Unbounded change (full replace, computed splice, or the
                // stale-patch resync): runs rebuild from scratch on the
                // next draw.
                QuoinPerformanceTrace.measure("render.decorations.invalidate") {
                    (textView as? QuoinTextView)?.invalidateDecorations()
                }
            }
            // Kill estimated geometry while the document is small enough to
            // lay out eagerly (a few ms at tens of KB): TextKit 2's lazy
            // estimates RESOLVE on click (hit-testing forces layout), and
            // the resolved heights shift the content under the pointer — a
            // viewport jump no delegate ever sees, on any block type. Large
            // documents keep lazy layout (the anchor + settle passes handle
            // them); typical documents simply never lie.
            if storage.length < 200_000,
               let layoutManager = textView.textLayoutManager,
               let contentStorage = textView.textContentStorage {
                QuoinPerformanceTrace.measure(
                    "render.textkit.eagerLayout", metadata: "utf16=\(storage.length)"
                ) {
                    layoutManager.ensureLayout(for: contentStorage.documentRange)
                }
            }
            // A range selection straddling the changed region has no meaning
            // in the new text — AppKit clamps the stale indexes into whatever
            // the splice put there, which reads as a random selection.
            // Collapse it to its start; selections clear of the change (and
            // all carets) survive untouched. The caret-restore paths below
            // override this when they apply.
            if let collapsed = Coordinator.collapsedSelection(
                preSelection,
                changedOldRange: Coordinator.changedOldRange(
                    for: application, oldLength: preLength, newLength: storage.length),
                newLength: storage.length
            ) {
                textView.setSelectedRange(collapsed)
            }
            coordinator.renderedGeneration = rendered.attributed
            coordinator.appliedRevision = rendered.revision
            coordinator.blockRanges = rendered.blockRanges
            // Flip-back caret: the closing block's caret returns to the
            // rendered image of its source position (Escape/⌘↩/Done). The
            // selection is otherwise left wherever the splice pushed it —
            // an unspecified spot the next keystroke would act on.
            if let pending = coordinator.pendingDeactivationCaret {
                coordinator.pendingDeactivationCaret = nil
                if rendered.activeBlockID == nil,
                   let range = rendered.blockRanges[pending.id],
                   NSMaxRange(range) <= storage.length {
                    let location = coordinator.flipBackCaretLocation(
                        blockRange: range,
                        storage: storage,
                        sourceOffset: pending.sourceOffset,
                        sourceText: pending.sourceText
                    )
                    textView.setSelectedRange(NSRange(location: location, length: 0))
                }
            }
            if let flipAnchor, let newRange = rendered.blockRanges[flipAnchor.id] {
                // Caret-less flip: pin the flipped block's top edge; this
                // also forces real layout for the spliced region, so the
                // first paint uses settled geometry instead of estimates.
                coordinator.scrollBlockTop(newRange, toScreenY: flipAnchor.screenY, in: textView)
            } else if splicedRange == nil, caretInActiveBlock == nil,
                      let anchorID, let range = rendered.blockRanges[anchorID] {
                // Re-anchor only on a full/large replacement (splice returned
                // nil); an in-place splice preserves the viewport by
                // construction.
                textView.scrollRangeToVisible(range)
            }
            coordinator.suppressSelectionCallback = false
            coordinator.appliedQuery = nil // force re-highlight on new content
            // VoiceOver hears the mode change (never announced by tint
            // alone): entering/leaving source editing.
            if flipPending {
                NSAccessibility.post(
                    element: textView,
                    notification: .announcementRequested,
                    userInfo: [
                        .announcement: rendered.activeBlockID != nil
                            ? "Editing source" : "Done editing",
                        .priority: NSAccessibilityPriorityLevel.medium.rawValue,
                    ]
                )
            }
        }
        // Activation changes invalidate queued keystroke positions.
        if rendered.activeBlockID != coordinator.lastActiveBlockID {
            coordinator.clearPendingKeystrokes()
        }
        coordinator.lastActiveBlockID = rendered.activeBlockID

        // Restore the caret into the active block after an edit round-trip.
        if let caret = caretInActiveBlock,
           caretGeneration != coordinator.appliedCaretGeneration,
           let active = rendered.activeEditableRange {
            coordinator.appliedCaretGeneration = caretGeneration
            let location = min(active.location + caret, active.location + active.length)
            coordinator.suppressSelectionCallback = true
            textView.setSelectedRange(NSRange(location: location, length: 0))
            if let caretLineAnchorY {
                // Flip: the caret's line goes back exactly where the user
                // was looking (the clicked table row, the list item the
                // arrow key entered) regardless of the height change. The
                // revealed block's full range is laid out first so the pin
                // measures real geometry, not estimates.
                coordinator.pinCaretLine(
                    at: location, toScreenY: caretLineAnchorY, in: textView,
                    ensuringLayoutOf: rendered.activeBlockID.flatMap { rendered.blockRanges[$0] })
            } else if typewriterEnabled, rendered.activeBlockID != nil {
                // Typewriter scrolling (idea #1): while typing, the
                // caret's line holds a fixed height — the page moves, the
                // eye doesn't. Reuses the viewport-invariant pin.
                let anchorY = scrollView.contentView.bounds.height * 0.4
                coordinator.pinCaretLine(
                    at: location, toScreenY: anchorY, in: textView, settle: false)
            } else {
                // Edit round-trip: scroll ONLY if the caret left the
                // viewport, and then by the minimal amount — arrowing and
                // typing must never lurch.
                coordinator.scrollCaretIntoViewIfNeeded(location, in: textView)
            }
            coordinator.suppressSelectionCallback = false
            if textView.window?.firstResponder !== textView {
                textView.window?.makeFirstResponder(textView)
            }
            // The edit's echo has fully landed (projection + caret):
            // release the next queued keystroke (ledger #11).
            coordinator.noteEditEchoApplied(in: textView)
        }

        // Motion, second half: with the splice applied and the pin's settle
        // pass already queued, measure the flipped block's REAL new
        // geometry and start the choreography — its animations enqueue
        // behind the settle, so they converge on truth, never estimates.
        if let flipMotionID,
           let newRange = rendered.blockRanges[flipMotionID],
           let storage = textView.textContentStorage?.textStorage,
           let newRect = coordinator.blockScreenRect(newRange, in: textView) {
            coordinator.flipTransition?.run(newBlockRect: newRect, documentLength: storage.length)
        } else if flipMotionID != nil {
            coordinator.flipTransition?.cancel()
        }

        QuoinPerformanceTrace.measure("render.search.apply", metadata: "query_empty=\(searchQuery.isEmpty)") {
            coordinator.applySearch(query: searchQuery, activeOrdinal: activeMatchOrdinal)
        }

        if let formatCommand, formatGeneration != coordinator.appliedFormatGeneration {
            coordinator.appliedFormatGeneration = formatGeneration
            coordinator.applyFormat(formatCommand, in: textView)
        }

        if editSourceToggleGeneration != coordinator.appliedEditSourceToggleGeneration {
            coordinator.appliedEditSourceToggleGeneration = editSourceToggleGeneration
            coordinator.toggleEditSource(in: textView)
        }

        // Focus mode: re-derive the dimming whenever the projection, the
        // caret, or the toggle changed (rendering attributes — no layout).
        coordinator.applyFocusDimming(in: textView, theme: theme)

        if let scrollTarget, scrollGeneration != coordinator.appliedScrollGeneration {
            coordinator.appliedScrollGeneration = scrollGeneration
            if let range = rendered.blockRanges[scrollTarget] {
                QuoinPerformanceTrace.measure("render.scroll.target") {
                    coordinator.scrollBlockToTop(range, in: textView)
                }
            }
        }
    }

}
#endif
