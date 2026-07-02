#if canImport(AppKit)
import AppKit
import SwiftUI
import QuoinCore

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
    /// TOC navigation target; changing it scrolls to that block.
    public let scrollTarget: BlockID?
    public let onTaskToggle: (Int) -> Void
    public let onMatchCount: (Int) -> Void
    /// Resolves an internal `#anchor` link to a block.
    public let anchorResolver: (String) -> BlockID?

    public init(
        rendered: RenderedDocument,
        theme: Theme = Theme(),
        searchQuery: String = "",
        activeMatchOrdinal: Int = 0,
        scrollTarget: BlockID? = nil,
        onTaskToggle: @escaping (Int) -> Void = { _ in },
        onMatchCount: @escaping (Int) -> Void = { _ in },
        anchorResolver: @escaping (String) -> BlockID? = { _ in nil }
    ) {
        self.rendered = rendered
        self.theme = theme
        self.searchQuery = searchQuery
        self.activeMatchOrdinal = activeMatchOrdinal
        self.scrollTarget = scrollTarget
        self.onTaskToggle = onTaskToggle
        self.onMatchCount = onMatchCount
        self.anchorResolver = anchorResolver
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

        let textView = NSTextView(frame: .zero, textContainer: container)
        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = true
        textView.drawsBackground = true
        textView.backgroundColor = .textBackgroundColor
        textView.textContainerInset = NSSize(width: theme.contentInset, height: theme.contentInset)
        textView.autoresizingMask = [.width]
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.delegate = context.coordinator
        textView.linkTextAttributes = [
            .foregroundColor: theme.linkColor,
            .cursor: NSCursor.pointingHand,
        ]

        let scrollView = NSScrollView()
        scrollView.documentView = textView
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = true
        scrollView.backgroundColor = .textBackgroundColor

        context.coordinator.textView = textView
        return scrollView
    }

    public func updateNSView(_ scrollView: NSScrollView, context: Context) {
        let coordinator = context.coordinator
        coordinator.parent = self
        guard let textView = coordinator.textView else { return }

        if coordinator.renderedGeneration !== rendered.attributed {
            let anchorID = coordinator.topVisibleBlockID(in: textView)
            textView.textContentStorage?.textStorage?.setAttributedString(rendered.attributed)
            coordinator.renderedGeneration = rendered.attributed
            coordinator.blockRanges = rendered.blockRanges
            if let anchorID, let range = rendered.blockRanges[anchorID] {
                textView.scrollRangeToVisible(range)
            }
            coordinator.appliedQuery = nil // force re-highlight on new content
        }

        coordinator.applySearch(query: searchQuery, activeOrdinal: activeMatchOrdinal)

        if let scrollTarget, scrollTarget != coordinator.lastScrollTarget {
            coordinator.lastScrollTarget = scrollTarget
            if let range = rendered.blockRanges[scrollTarget] {
                textView.scrollRangeToVisible(range)
            }
        }
    }

    // MARK: - Coordinator

    public final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: MarkdownReaderView
        weak var textView: NSTextView?
        var renderedGeneration: NSAttributedString?
        var blockRanges: [BlockID: NSRange] = [:]
        var lastScrollTarget: BlockID?
        var appliedQuery: String?
        var appliedOrdinal: Int = -1
        private var matchRanges: [NSRange] = []

        init(parent: MarkdownReaderView) {
            self.parent = parent
        }

        // MARK: Links & checkboxes

        public func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
            guard let url = linkURL(from: link) else { return false }
            if let offset = QuoinLink.markerOffset(from: url) {
                parent.onTaskToggle(offset)
                return true
            }
            if let slug = QuoinLink.anchorSlug(from: url) {
                if let blockID = parent.anchorResolver(slug), let range = blockRanges[blockID] {
                    textView.scrollRangeToVisible(range)
                }
                return true
            }
            return false // system handles web links
        }

        private func linkURL(from link: Any) -> URL? {
            if let url = link as? URL { return url }
            if let string = link as? String { return URL(string: string) }
            return nil
        }

        // MARK: Scroll anchoring

        /// The block ID at the top of the current viewport, used to keep the
        /// reading position stable across live reloads.
        func topVisibleBlockID(in textView: NSTextView) -> BlockID? {
            guard let storage = textView.textContentStorage?.textStorage, storage.length > 0 else { return nil }
            let topPoint = NSPoint(x: textView.visibleRect.minX + 1, y: textView.visibleRect.minY + 1)
            let index = textView.characterIndexForInsertion(at: topPoint)
            guard index >= 0, index < storage.length else { return nil }
            guard let idString = storage.attribute(QuoinAttribute.blockID, at: index, effectiveRange: nil) as? String else { return nil }
            return blockRanges.first(where: { $0.key.description == idString })?.key
        }

        // MARK: Search highlighting

        func applySearch(query: String, activeOrdinal: Int) {
            guard query != appliedQuery || activeOrdinal != appliedOrdinal else { return }
            guard let textView,
                  let layoutManager = textView.textLayoutManager,
                  let contentStorage = textView.textContentStorage,
                  let storage = contentStorage.textStorage
            else { return }

            // Clear previous highlights.
            for range in matchRanges {
                if let textRange = textRange(range, in: contentStorage) {
                    layoutManager.removeRenderingAttribute(.backgroundColor, for: textRange)
                }
            }
            matchRanges = []

            let trimmed = query.trimmingCharacters(in: .whitespaces)
            defer {
                appliedQuery = query
                appliedOrdinal = activeOrdinal
                parent.onMatchCount(matchRanges.count)
            }
            guard !trimmed.isEmpty else { return }

            let haystack = storage.string as NSString
            var searchRange = NSRange(location: 0, length: haystack.length)
            while searchRange.length > 0 {
                let found = haystack.range(
                    of: trimmed,
                    options: [.caseInsensitive, .diacriticInsensitive],
                    range: searchRange
                )
                guard found.location != NSNotFound else { break }
                matchRanges.append(found)
                let next = found.location + max(found.length, 1)
                searchRange = NSRange(location: next, length: haystack.length - next)
            }

            let theme = parent.theme
            for (index, range) in matchRanges.enumerated() {
                guard let textRange = textRange(range, in: contentStorage) else { continue }
                let color = index == activeOrdinal
                    ? theme.searchHighlight
                    : theme.searchHighlight.withAlphaComponent(0.35)
                layoutManager.addRenderingAttribute(.backgroundColor, value: color, for: textRange)
            }

            if activeOrdinal >= 0, activeOrdinal < matchRanges.count {
                textView.scrollRangeToVisible(matchRanges[activeOrdinal])
            }
        }

        private func textRange(_ range: NSRange, in contentStorage: NSTextContentStorage) -> NSTextRange? {
            let documentStart = contentStorage.documentRange.location
            guard let start = contentStorage.location(documentStart, offsetBy: range.location),
                  let end = contentStorage.location(start, offsetBy: range.length)
            else { return nil }
            return NSTextRange(location: start, end: end)
        }
    }
}
#endif
