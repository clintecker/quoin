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

        if coordinator.renderedGeneration !== rendered.attributed,
           let storage = textView.textContentStorage?.textStorage {
            let anchorID = coordinator.topVisibleBlockID(in: textView)
            coordinator.suppressSelectionCallback = true
            // Splice only the changed span into the live storage rather than
            // replacing the whole document. TextKit 2 then re-lays-out just
            // that region, so unchanged content keeps its exact layout and the
            // scroll offset never jumps.
            let splicedRange = QuoinPerformanceTrace.measure(
                "render.textkit.splice",
                metadata: "old_utf16=\(storage.length) new_utf16=\(rendered.attributed.length)"
            ) {
                Coordinator.spliceChanges(in: storage, to: rendered.attributed)
            }
            QuoinPerformanceTrace.measure("render.decorations.invalidate") {
                (textView as? QuoinTextView)?.invalidateDecorations()
            }
            coordinator.renderedGeneration = rendered.attributed
            coordinator.blockRanges = rendered.blockRanges
            // Re-anchor only on a full/large replacement (splice returned nil);
            // an in-place splice preserves the viewport by construction.
            if splicedRange == nil, caretInActiveBlock == nil,
               let anchorID, let range = rendered.blockRanges[anchorID] {
                textView.scrollRangeToVisible(range)
            }
            coordinator.suppressSelectionCallback = false
            coordinator.appliedQuery = nil // force re-highlight on new content
        }

        // Restore the caret into the active block after an edit round-trip.
        if let caret = caretInActiveBlock,
           caretGeneration != coordinator.appliedCaretGeneration,
           let active = rendered.activeEditableRange {
            coordinator.appliedCaretGeneration = caretGeneration
            let location = min(active.location + caret, active.location + active.length)
            coordinator.suppressSelectionCallback = true
            textView.setSelectedRange(NSRange(location: location, length: 0))
            textView.scrollRangeToVisible(NSRange(location: location, length: 0))
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
