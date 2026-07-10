#if canImport(AppKit)
import AppKit
import SwiftUI
import QuoinCore

/// Format commands the window can send to the editor's selection.
public enum FormatCommand: Equatable, Sendable {
    case bold, italic, highlight, link
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
    /// Caret entered a block (nil = deactivate, Esc).
    public let onActivateBlock: ((BlockID?, Int?) -> Void)?
    /// Caret position (UTF-16, relative to the active block's source text)
    /// to restore after a re-render; `caretGeneration` bumps to re-apply.
    public let caretInActiveBlock: Int?
    public let caretGeneration: Int
    /// Format command to apply to the current selection (⌘B/⌘I/⌘K/⇧⌘H);
    /// `formatGeneration` bumps to fire.
    public let formatCommand: FormatCommand?
    public let formatGeneration: Int

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
        onActivateBlock: ((BlockID?, Int?) -> Void)? = nil,
        caretInActiveBlock: Int? = nil,
        caretGeneration: Int = 0,
        formatCommand: FormatCommand? = nil,
        formatGeneration: Int = 0
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
        textView.onDoubleClick = { [weak coordinator = context.coordinator] index in
            coordinator?.activateEmbedBlock(atCharIndex: index)
        }
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
            coordinator.suppressSelectionCallback = true
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
            coordinator.renderedGeneration = rendered.attributed
            coordinator.appliedRevision = rendered.revision
            coordinator.blockRanges = rendered.blockRanges
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
        }

        QuoinPerformanceTrace.measure("render.search.apply", metadata: "query_empty=\(searchQuery.isEmpty)") {
            coordinator.applySearch(query: searchQuery, activeOrdinal: activeMatchOrdinal)
        }

        if let formatCommand, formatGeneration != coordinator.appliedFormatGeneration {
            coordinator.appliedFormatGeneration = formatGeneration
            coordinator.applyFormat(formatCommand, in: textView)
        }

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
