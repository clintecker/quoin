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
    public let onActivateBlock: ((BlockID?) -> Void)?
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
        onActivateBlock: ((BlockID?) -> Void)? = nil,
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
        return scrollView
    }

    public func updateNSView(_ scrollView: NSScrollView, context: Context) {
        let coordinator = context.coordinator
        coordinator.parent = self
        guard let textView = coordinator.textView else { return }

        if coordinator.renderedGeneration !== rendered.attributed {
            let anchorID = coordinator.topVisibleBlockID(in: textView)
            coordinator.suppressSelectionCallback = true
            textView.textContentStorage?.textStorage?.setAttributedString(rendered.attributed)
            (textView as? QuoinTextView)?.invalidateDecorations()
            coordinator.renderedGeneration = rendered.attributed
            coordinator.blockRanges = rendered.blockRanges
            // Only re-anchor scroll when the caret isn't being restored —
            // caret restoration scrolls itself.
            if caretInActiveBlock == nil, let anchorID, let range = rendered.blockRanges[anchorID] {
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

        coordinator.applySearch(query: searchQuery, activeOrdinal: activeMatchOrdinal)

        if let formatCommand, formatGeneration != coordinator.appliedFormatGeneration {
            coordinator.appliedFormatGeneration = formatGeneration
            coordinator.applyFormat(formatCommand, in: textView)
        }

        if let scrollTarget, scrollGeneration != coordinator.appliedScrollGeneration {
            coordinator.appliedScrollGeneration = scrollGeneration
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
        var appliedScrollGeneration = 0
        var appliedQuery: String?
        var appliedOrdinal: Int = -1
        var appliedCaretGeneration: Int = -1
        var appliedFormatGeneration: Int = 0
        var suppressSelectionCallback = false
        var scrollObserver: NSObjectProtocol?
        private var matchRanges: [NSRange] = []
        private var lastReportedTopBlock: BlockID?

        init(parent: MarkdownReaderView) {
            self.parent = parent
        }

        deinit {
            if let scrollObserver {
                NotificationCenter.default.removeObserver(scrollObserver)
            }
        }

        func reportTopBlock() {
            guard let textView else { return }
            let top = topVisibleBlockID(in: textView)
            guard top != lastReportedTopBlock else { return }
            lastReportedTopBlock = top
            parent.onTopBlockChange(top)
        }

        // MARK: Links & checkboxes

        public func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
            guard let url = linkURL(from: link) else { return false }
            if let offset = QuoinLink.markerOffset(from: url) {
                parent.onTaskToggle(offset)
                return true
            }
            if QuoinLink.isCopyURL(url) {
                if let storage = textView.textContentStorage?.textStorage,
                   charIndex < storage.length,
                   let code = storage.attribute(QuoinAttribute.copySource, at: charIndex, effectiveRange: nil) as? String {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(code, forType: .string)
                }
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

        // MARK: Editing

        /// Every keystroke lands here. Inside the active block's revealed
        /// source it becomes a relative byte-range edit for the session;
        /// anywhere else it activates the block under the caret instead.
        /// Always returns false — the text storage is a projection and is
        /// only ever replaced wholesale by a re-render.
        public func textView(_ textView: NSTextView, shouldChangeTextIn affectedCharRange: NSRange, replacementString: String?) -> Bool {
            guard let onEdit = parent.onEditIntent else { return false }

            if let active = parent.rendered.activeEditableRange,
               let sourceText = parent.rendered.activeSourceText,
               affectedCharRange.location >= active.location,
               affectedCharRange.location + affectedCharRange.length <= active.location + active.length {
                let relStart = affectedCharRange.location - active.location
                let relRange = relStart..<(relStart + affectedCharRange.length)
                guard let byteRange = EditMapping.utf8Range(inText: sourceText, utf16Range: relRange) else {
                    return false
                }

                // Smart pairs: a lone delimiter keystroke may complete to a
                // pair (caret inside) or type over an existing closer.
                if affectedCharRange.length == 0,
                   let replacement = replacementString,
                   replacement.count == 1,
                   let character = replacement.first,
                   let completion = SmartPairs.completion(typing: character, inText: sourceText, caretUTF16: relStart) {
                    if completion.insert.isEmpty {
                        // Type-over: rewrite the existing closer with itself,
                        // which just advances the caret past it.
                        let overRange = relStart..<(relStart + 1)
                        guard let overBytes = EditMapping.utf8Range(inText: sourceText, utf16Range: overRange) else { return false }
                        let existing = (sourceText as NSString).substring(with: NSRange(location: relStart, length: 1))
                        onEdit(overBytes, existing, existing.utf8.count)
                    } else {
                        let caretDelta = EditMapping.utf8Offset(inText: completion.insert, utf16Offset: completion.caretOffset)
                        onEdit(byteRange, completion.insert, caretDelta)
                    }
                    return false
                }

                onEdit(byteRange, replacementString ?? "", nil)
                return false
            }

            // Keystroke outside the revealed region: open that block.
            if let id = blockID(atCharIndex: affectedCharRange.location) {
                parent.onActivateBlock?(id)
            }
            return false
        }

        /// A zero-length click inside a non-active block activates it
        /// (the syntax-reveal trigger). Range selections stay read-only so
        /// copying across blocks keeps working.
        public func textViewDidChangeSelection(_ notification: Notification) {
            guard !suppressSelectionCallback,
                  parent.onActivateBlock != nil,
                  let textView else { return }
            let selection = textView.selectedRange()

            // Span-level syntax reveal: as the caret moves inside the
            // active block, re-style it so only the caret's span shows its
            // delimiters. Attribute-only pass; the text never changes.
            if selection.length == 0,
               let active = parent.rendered.activeEditableRange,
               selection.location >= active.location,
               selection.location <= active.location + active.length {
                let relativeCaret = selection.location - active.location
                if relativeCaret != lastStyledCaret {
                    lastStyledCaret = relativeCaret
                    restyleActiveBlock(caretAt: relativeCaret, in: textView)
                }
            }
            // Zero-length caret placement activates a block. Clicking an
            // attachment (math, diagram, image) selects the attachment
            // character itself — a length-1 selection on an attachment run
            // counts as a click too, so diagrams open to their source.
            if selection.length == 1,
               let storage = textView.textContentStorage?.textStorage,
               selection.location < storage.length,
               storage.attribute(.attachment, at: selection.location, effectiveRange: nil) != nil {
                if let id = blockID(atCharIndex: selection.location),
                   id != parent.rendered.activeBlockID {
                    parent.onActivateBlock?(id)
                }
                return
            }
            guard selection.length == 0 else { return }
            guard let id = blockID(atCharIndex: selection.location) else { return }
            if id != parent.rendered.activeBlockID {
                parent.onActivateBlock?(id)
            }
        }

        private var lastStyledCaret = -1

        /// Re-applies the active block's source styling for a new caret
        /// position. Same characters, new attributes — selection, undo
        /// state, and the 1:1 edit mapping are untouched.
        private func restyleActiveBlock(caretAt relativeCaret: Int, in textView: NSTextView) {
            guard let active = parent.rendered.activeEditableRange,
                  let source = parent.rendered.activeSourceText,
                  let storage = textView.textContentStorage?.textStorage,
                  active.location + active.length <= storage.length
            else { return }
            let styled = MarkdownSourceStyler(theme: parent.theme)
                .style(source, caretOffset: relativeCaret)
            guard styled.length == active.length else { return }

            let blockID = storage.attribute(QuoinAttribute.blockID, at: active.location, effectiveRange: nil)
            storage.beginEditing()
            styled.enumerateAttributes(in: NSRange(location: 0, length: styled.length)) { attrs, range, _ in
                var merged = attrs
                if let blockID { merged[QuoinAttribute.blockID] = blockID }
                storage.setAttributes(
                    merged,
                    range: NSRange(location: active.location + range.location, length: range.length)
                )
            }
            storage.endEditing()
            // Delimiter fonts flip between 1pt and full size — a reflow —
            // so block chrome below the caret must redraw in place.
            (textView as? QuoinTextView)?.invalidateDecorations()
        }

        /// Applies a format command to the selection inside the active
        /// block's revealed source.
        func applyFormat(_ command: FormatCommand, in textView: NSTextView) {
            guard let onEdit = parent.onEditIntent,
                  let active = parent.rendered.activeEditableRange,
                  let sourceText = parent.rendered.activeSourceText
            else { return }
            let selection = textView.selectedRange()
            guard selection.location >= active.location,
                  selection.location + selection.length <= active.location + active.length
            else { return }

            let relStart = selection.location - active.location
            let relRange = relStart..<(relStart + selection.length)
            guard let byteRange = EditMapping.utf8Range(inText: sourceText, utf16Range: relRange) else { return }
            let selected = (sourceText as NSString).substring(
                with: NSRange(location: relStart, length: selection.length)
            )

            let change: Formatting.Change
            switch command {
            case .bold: change = Formatting.toggleWrap(selection: selected, delimiter: "**")
            case .italic: change = Formatting.toggleWrap(selection: selected, delimiter: "*")
            case .highlight: change = Formatting.cycleHighlight(selection: selected)
            case .link: change = Formatting.makeLink(selection: selected)
            }
            let caretDelta = EditMapping.utf8Offset(
                inText: change.replacement,
                utf16Offset: change.selectionOffset + change.selectionLength
            )
            onEdit(byteRange, change.replacement, caretDelta)
        }

        /// Esc closes the revealed block.
        public func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            if commandSelector == #selector(NSResponder.cancelOperation(_:)),
               parent.rendered.activeBlockID != nil {
                parent.onActivateBlock?(nil)
                return true
            }
            return false
        }

        func blockID(atCharIndex index: Int) -> BlockID? {
            // Ranges include their trailing separator, so boundaries can
            // match two blocks; prefer the strictly-containing (earlier) one
            // deterministically by picking the largest containing start.
            var best: (id: BlockID, location: Int)?
            for (id, range) in blockRanges where index >= range.location && index < range.location + range.length {
                if best == nil || range.location > best!.location {
                    best = (id, range.location)
                }
            }
            return best?.id
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

// MARK: - Decorated text view

/// `NSTextView` subclass that draws block decorations — code canvases,
/// callout boxes, quote rules, diagram frames, chips, table rules — behind
/// the text. The renderer tags block ranges with `QuoinAttribute
/// .blockDecoration`; geometry comes from the laid-out fragment frames, so
/// the shapes track reflow exactly.
final class QuoinTextView: NSTextView {

    private var decorationRuns: [(range: NSRange, decoration: BlockDecoration)] = []
    private var runsAreStale = true

    func invalidateDecorations() {
        runsAreStale = true
        needsDisplay = true
        // Second pass once TextKit settles: fragment frames queried during
        // the first draw can predate a reflow (estimated geometry), which
        // leaves decorations offset from their text until the next redraw.
        DispatchQueue.main.async { [weak self] in
            self?.needsDisplay = true
        }
    }

    // Any live layout change (viewport re-layout after estimates resolve)
    // must redraw decorations, or boxes lag behind their text.
    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        needsDisplay = true
    }

    private func refreshRunsIfNeeded() {
        guard runsAreStale, let storage = textContentStorage?.textStorage else { return }
        runsAreStale = false
        decorationRuns.removeAll()
        storage.enumerateAttribute(
            QuoinAttribute.blockDecoration,
            in: NSRange(location: 0, length: storage.length)
        ) { value, range, _ in
            if let decoration = value as? BlockDecoration {
                decorationRuns.append((range, decoration))
            }
        }
    }

    override func drawBackground(in rect: NSRect) {
        super.drawBackground(in: rect)
        refreshRunsIfNeeded()
        guard !decorationRuns.isEmpty,
              let layoutManager = textLayoutManager,
              let contentManager = layoutManager.textContentManager
        else { return }

        let origin = textContainerOrigin
        for run in decorationRuns {
            guard let textRange = textRange(for: run.range, in: contentManager) else { continue }

            var frames: [CGRect] = []
            var textWidth: CGFloat = 0
            layoutManager.enumerateTextLayoutFragments(
                from: textRange.location,
                options: [.ensuresLayout]
            ) { fragment in
                if fragment.rangeInElement.location.compare(textRange.endLocation) != .orderedAscending {
                    return false
                }
                frames.append(fragment.layoutFragmentFrame)
                for line in fragment.textLineFragments {
                    textWidth = max(textWidth, line.typographicBounds.width)
                }
                return true
            }
            guard var union = frames.first else { continue }
            for frame in frames.dropFirst() { union = union.union(frame) }

            // Full-width chrome spans the text column regardless of how
            // wide the laid-out lines happen to be.
            if let container = textContainer {
                switch run.decoration.kind {
                case .codeCanvas, .callout, .diagramFrame:
                    union.origin.x = 0
                    union.size.width = container.size.width
                default:
                    break
                }
            }

            let box = union.offsetBy(dx: origin.x, dy: origin.y)
            guard box.insetBy(dx: -8, dy: -8).intersects(rect) else { continue }
            draw(
                run.decoration,
                box: box,
                frames: frames.map { $0.offsetBy(dx: origin.x, dy: origin.y) },
                textWidth: textWidth
            )
        }
    }

    private func draw(_ decoration: BlockDecoration, box: CGRect, frames: [CGRect], textWidth: CGFloat) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        context.saveGState()
        defer { context.restoreGState() }

        switch decoration.kind {
        case .codeCanvas(let fill):
            let rect = box.insetBy(dx: 0, dy: -2)
            context.addPath(CGPath(roundedRect: rect, cornerWidth: 8, cornerHeight: 8, transform: nil))
            context.setFillColor(fill.cgColor)
            context.fillPath()

        case .callout(let color):
            var rect = box.insetBy(dx: 0, dy: -2)
            rect.size.height += 4 // clear the last line's descenders
            context.addPath(CGPath(roundedRect: rect, cornerWidth: 8, cornerHeight: 8, transform: nil))
            context.setFillColor(color.withAlphaComponent(0.05).cgColor)
            context.fillPath()
            context.addPath(CGPath(
                roundedRect: rect.insetBy(dx: 0.5, dy: 0.5),
                cornerWidth: 7.5, cornerHeight: 7.5, transform: nil
            ))
            context.setStrokeColor(color.withAlphaComponent(0.15).cgColor)
            context.setLineWidth(1)
            context.strokePath()

        case .quoteRule(let color):
            let bar = CGRect(x: box.minX + 2, y: box.minY + 3, width: 3, height: box.height - 6)
            context.addPath(CGPath(roundedRect: bar, cornerWidth: 1.5, cornerHeight: 1.5, transform: nil))
            context.setFillColor(color.cgColor)
            context.fillPath()

        case .diagramFrame(let color):
            let rect = box.insetBy(dx: 0, dy: -4)
            context.addPath(CGPath(
                roundedRect: rect.insetBy(dx: 0.5, dy: 0.5),
                cornerWidth: 8, cornerHeight: 8, transform: nil
            ))
            context.setStrokeColor(color.cgColor)
            context.setLineWidth(1)
            context.strokePath()

        case .chip(let fill):
            let rect = CGRect(
                x: box.minX,
                y: box.minY + 1,
                width: min(textWidth + 16, box.width),
                height: box.height - 2
            )
            context.addPath(CGPath(roundedRect: rect, cornerWidth: 6, cornerHeight: 6, transform: nil))
            context.setFillColor(fill.cgColor)
            context.fillPath()

        case .tableRules(let width, let header, let body):
            let lineWidth = min(width + 24, box.width)
            for (index, frame) in frames.enumerated() {
                let y = frame.maxY - (index == 0 ? 0.75 : 0.5)
                context.setStrokeColor((index == 0 ? header : body).cgColor)
                context.setLineWidth(index == 0 ? 1.5 : 1)
                context.move(to: CGPoint(x: frame.minX, y: y))
                context.addLine(to: CGPoint(x: frame.minX + lineWidth, y: y))
                context.strokePath()
            }
        }
    }

    private func textRange(for range: NSRange, in contentManager: NSTextContentManager) -> NSTextRange? {
        let documentStart = contentManager.documentRange.location
        guard let start = contentManager.location(documentStart, offsetBy: range.location),
              let end = contentManager.location(start, offsetBy: range.length)
        else { return nil }
        return NSTextRange(location: start, end: end)
    }
}
#endif
