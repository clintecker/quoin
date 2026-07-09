#if canImport(AppKit)
import AppKit
import SwiftUI
import QuoinCore

// MARK: - Coordinator

/// The reader view's delegate and mutable state: text-storage splicing,
/// selection→activation routing, syntax-reveal restyling, format commands,
/// search highlighting, and scroll anchoring. Split from
/// MarkdownReaderView.swift for navigability; same type, same module.
extension MarkdownReaderView {

    public final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: MarkdownReaderView
        weak var textView: NSTextView?
        var renderedGeneration: NSAttributedString?
        /// Last `RenderedDocument.revision` applied to the live storage.
        /// updateNSView runs on every SwiftUI pass; this is what stops a
        /// patch-bearing projection from re-applying its patches.
        var appliedRevision = -1
        var blockRanges: [BlockID: NSRange] = [:]
        /// The active block id as of the last applied update — what lets a
        /// re-render recognize an activate/deactivate FLIP (chart ↔ source)
        /// and pin the flipped block on screen across the height change.
        var lastActiveBlockID: BlockID?
        var appliedScrollGeneration = 0
        var appliedQuery: String?
        var appliedOrdinal: Int = -1
        var appliedCaretGeneration: Int = -1
        var appliedFormatGeneration: Int = 0
        var suppressSelectionCallback = false
        var scrollObserver: NSObjectProtocol?
        private var matchRanges: [NSRange] = []
        private var hasAppliedSearchHighlights = false
        private var lastReportedTopBlock: BlockID?

        /// Replaces only the changed span of `storage`, so a re-render doesn't
        /// re-lay-out the whole document. Compares the common prefix and suffix
        /// of the old and new strings and splices the differing middle. Returns
        /// the new range that was spliced, or nil when it fell back to a full
        /// replacement (empty storage, or nearly everything changed) — the
        /// caller re-anchors scroll only in that case.
        static func spliceChanges(in storage: NSTextStorage, to newAttr: NSAttributedString) -> NSRange? {
            let old = storage.string as NSString
            let new = newAttr.string as NSString
            let oldLen = old.length
            let newLen = new.length
            guard oldLen > 0 else {
                storage.setAttributedString(newAttr)
                return nil
            }

            // Chunked comparison via memcmp: per-character `character(at:)`
            // costs an ObjC message each (~24 ms across a novel), and a
            // Swift element loop pays per-index bounds checks in debug
            // builds. memcmp on getCharacters buffers is C-speed in any
            // build mode; only a differing chunk is scanned element-wise.
            let chunk = 8192
            var oldBuf = [unichar](repeating: 0, count: chunk)
            var newBuf = [unichar](repeating: 0, count: chunk)
            func chunksEqual(_ n: Int) -> Bool {
                oldBuf.withUnsafeBufferPointer { a in
                    newBuf.withUnsafeBufferPointer { b in
                        memcmp(a.baseAddress!, b.baseAddress!, n * MemoryLayout<unichar>.size) == 0
                    }
                }
            }
            let bound = min(oldLen, newLen)
            var prefix = 0
            outer: while prefix < bound {
                let n = min(chunk, bound - prefix)
                old.getCharacters(&oldBuf, range: NSRange(location: prefix, length: n))
                new.getCharacters(&newBuf, range: NSRange(location: prefix, length: n))
                if chunksEqual(n) { prefix += n; continue }
                for i in 0..<n where oldBuf[i] != newBuf[i] { prefix += i; break outer }
                prefix += n
            }
            var suffix = 0
            let suffixBound = bound - prefix
            outer2: while suffix < suffixBound {
                let n = min(chunk, suffixBound - suffix)
                old.getCharacters(&oldBuf, range: NSRange(location: oldLen - suffix - n, length: n))
                new.getCharacters(&newBuf, range: NSRange(location: newLen - suffix - n, length: n))
                if chunksEqual(n) { suffix += n; continue }
                for i in 0..<n where oldBuf[n - 1 - i] != newBuf[n - 1 - i] { suffix += i; break outer2 }
                suffix += n
            }

            let oldChanged = NSRange(location: prefix, length: oldLen - prefix - suffix)
            let newChangedLen = newLen - prefix - suffix
            // If most of the document changed, a single set is simpler and a
            // scroll re-anchor is warranted.
            if oldChanged.length + newChangedLen > (oldLen + newLen) * 3 / 4 {
                storage.setAttributedString(newAttr)
                return nil
            }

            let replacement = newAttr.attributedSubstring(
                from: NSRange(location: prefix, length: newChangedLen)
            )
            storage.beginEditing()
            storage.replaceCharacters(in: oldChanged, with: replacement)
            storage.endEditing()
            return NSRange(location: prefix, length: newChangedLen)
        }

        static func spliceChanges(
            in storage: NSTextStorage,
            to newAttr: NSAttributedString,
            hint: RenderSpliceHint?
        ) -> NSRange? {
            if let hint,
               hint.oldRange.location >= 0,
               hint.replacementRange.location >= 0,
               NSMaxRange(hint.oldRange) <= storage.length,
               NSMaxRange(hint.replacementRange) <= newAttr.length {
                let replacement = newAttr.attributedSubstring(from: hint.replacementRange)
                storage.beginEditing()
                storage.replaceCharacters(in: hint.oldRange, with: replacement)
                storage.endEditing()
                return hint.replacementRange
            }
            return spliceChanges(in: storage, to: newAttr)
        }

        static func applyStoragePatch(
            in storage: NSTextStorage,
            patch: RenderStoragePatch
        ) -> NSRange? {
            guard patch.oldRange.location >= 0,
                  NSMaxRange(patch.oldRange) <= storage.length
            else { return nil }
            storage.beginEditing()
            storage.replaceCharacters(in: patch.oldRange, with: patch.replacement)
            storage.endEditing()
            return NSRange(location: patch.oldRange.location, length: patch.replacement.length)
        }

        /// How a projection landed in the live storage: bounded patches, or
        /// a computed splice (which includes the resync fallback).
        enum ProjectionApplication {
            case patched([RenderStoragePatch])
            case spliced(NSRange?)
        }

        /// Applies a published projection to the live storage. Patches are
        /// trusted ONLY when the storage is exactly the state they were
        /// computed against (`patchBaseLength`): SwiftUI coalesces rapid
        /// publishes, so a view can skip an intermediate patch revision —
        /// applying the next batch to that stale storage would silently
        /// corrupt the projection (the caret mapping drifts and keystrokes
        /// near the block end fall outside the editable range and get
        /// swallowed). Any mismatch falls back to a full splice against
        /// `attributed`, which the model keeps authoritative — one O(scan)
        /// resync instead of compounding corruption.
        static func applyProjection(
            _ rendered: RenderedDocument, to storage: NSTextStorage
        ) -> ProjectionApplication {
            if !rendered.storagePatches.isEmpty,
               rendered.patchBaseLength == storage.length,
               rendered.storagePatches.allSatisfy({
                   $0.oldRange.location >= 0 && NSMaxRange($0.oldRange) <= storage.length
               }) {
                for patch in rendered.storagePatches {
                    _ = applyStoragePatch(in: storage, patch: patch)
                }
                return .patched(rendered.storagePatches)
            }
            return .spliced(spliceChanges(in: storage, to: rendered.attributed, hint: rendered.spliceHint))
        }

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
                    scrollBlockToTop(range, in: textView)
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

                // Classify the keystroke (smart-pair wrap / complete /
                // type-over, or a plain replacement) as one pure intent, then
                // apply its single uniform edit: UTF-16 range → bytes, caret
                // offset within the replacement → bytes.
                let intent = EditIntent.classify(
                    sourceText: sourceText, range: relRange, replacement: replacementString ?? ""
                )
                let (utf16Range, text, caret) = intent.edit
                guard let byteRange = EditMapping.utf8Range(inText: sourceText, utf16Range: utf16Range) else {
                    return false
                }
                let caretDelta = caret.flatMap { EditMapping.utf8Offset(inText: text, utf16Offset: $0) }
                onEdit(byteRange, text, caretDelta)
                return false
            }

            // Keystroke outside the revealed region: open that block at the
            // keystroke's position. Embed blocks (code/table/…) map through the
            // 1:1 body tag; plain prose uses the rendered offset directly.
            if let id = blockID(atCharIndex: affectedCharRange.location) {
                let hint: Int?
                if isEmbedBlock(atCharIndex: affectedCharRange.location) {
                    hint = embedCaretHint(atCharIndex: affectedCharRange.location)
                } else {
                    hint = blockRanges[id].map { affectedCharRange.location - $0.location }
                }
                parent.onActivateBlock?(id, hint)
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
            // Images: clicking the attachment (length-1 selection) opens
            // its source. Embed blocks (code/math/mermaid/table) are handled
            // by double-click in QuoinTextView, not here — a single click on
            // one just places the caret so it can be admired or selected.
            if selection.length == 1,
               let storage = textView.textContentStorage?.textStorage,
               selection.location < storage.length,
               storage.attribute(.attachment, at: selection.location, effectiveRange: nil) != nil,
               !isEmbedBlock(atCharIndex: selection.location) {
                if let id = blockID(atCharIndex: selection.location),
                   id != parent.rendered.activeBlockID {
                    parent.onActivateBlock?(id, nil)
                }
                return
            }
            guard selection.length == 0 else { return }
            // Single click on an embed block places the caret only.
            guard !isEmbedBlock(atCharIndex: selection.location) else { return }
            guard let id = blockID(atCharIndex: selection.location) else { return }
            if id != parent.rendered.activeBlockID {
                // Land the caret where the click fell, not at the block end.
                let hint = blockRanges[id].map { selection.location - $0.location }
                parent.onActivateBlock?(id, hint)
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
            // so block chrome below the caret must redraw in place. The run
            // RANGES are untouched (attribute-only restyle), so this is a
            // redraw, not a rescan.
            (textView as? QuoinTextView)?.redrawDecorations()
        }

        /// Applies a format command to the selection inside the active
        /// block's revealed source.
        func applyFormat(_ command: FormatCommand, in textView: NSTextView) {
            guard let onEdit = parent.onEditIntent,
                  let active = parent.rendered.activeEditableRange,
                  let sourceText = parent.rendered.activeSourceText
            else { return }
            var selection = textView.selectedRange()
            guard selection.location >= active.location,
                  selection.location + selection.length <= active.location + active.length
            else { return }

            // No selection: format the word under the caret (⌘B on a word
            // with no drag-select). Links still need an explicit selection.
            if selection.length == 0, command != .link,
               let word = Formatting.wordRange(in: sourceText, around: selection.location - active.location) {
                selection = NSRange(location: active.location + word.offset, length: word.length)
            }

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
                parent.onActivateBlock?(nil, nil)
                return true
            }
            return false
        }

        func blockID(atCharIndex index: Int) -> BlockID? {
            // Ranges include their trailing separator, so boundaries can
            // match two blocks; prefer the strictly-containing (earlier) one
            // deterministically by picking the largest containing start.
            blockRanges
                .filter { index >= $0.value.location && index < $0.value.location + $0.value.length }
                .max { $0.value.location < $1.value.location }?
                .key
        }

        /// True when the character sits in an embed block (code/math/mermaid
        /// /table) that flips to source on double-click, not single click.
        func isEmbedBlock(atCharIndex index: Int) -> Bool {
            guard let storage = textView?.textContentStorage?.textStorage,
                  index >= 0, index < storage.length else { return false }
            return storage.attribute(QuoinAttribute.embedBlock, at: index, effectiveRange: nil) != nil
        }

        /// Double-click on an embed block flips it to editable source
        /// (QuoinTextView routes the gesture here). The caret lands at the
        /// source position matching the click, not at the block end.
        func activateEmbedBlock(atCharIndex index: Int) {
            guard isEmbedBlock(atCharIndex: index),
                  let id = blockID(atCharIndex: index),
                  id != parent.rendered.activeBlockID else { return }
            parent.onActivateBlock?(id, embedCaretHint(atCharIndex: index))
        }

        /// Where the caret should land when an embed block flips to source:
        /// the start of the code content (just inside the opening fence), so a
        /// double-click doesn't dump the caret after the closing fence. Precise
        /// click-to-source mapping isn't attempted — TextKit 2 point hit-testing
        /// is unreliable in the decorated canvas — but once in source mode the
        /// text is plain, so the next click lands exactly where the user aims.
        func embedCaretHint(atCharIndex index: Int) -> Int? {
            guard let storage = textView?.textContentStorage?.textStorage,
                  let id = blockID(atCharIndex: index),
                  let blockRange = blockRanges[id] else { return nil }
            var contentStart: Int?
            let clamped = NSRange(
                location: blockRange.location,
                length: min(blockRange.length, storage.length - blockRange.location)
            )
            storage.enumerateAttribute(QuoinAttribute.embedSourceStart, in: clamped) { value, _, stop in
                if let start = value as? NSNumber { contentStart = start.intValue; stop.pointee = true }
            }
            return contentStart
        }

        // MARK: Scroll anchoring

        /// The on-screen y (distance from the viewport's top) of a block's
        /// first laid-out fragment, or nil when geometry is unavailable.
        /// Captured BEFORE an activate/deactivate splice so the flipped
        /// block can be pinned at the same place afterward.
        func blockTopScreenY(_ range: NSRange, in textView: NSTextView) -> CGFloat? {
            guard let layoutManager = textView.textLayoutManager,
                  let contentStorage = textView.textContentStorage,
                  let textRange = nsTextRange(range, in: contentStorage),
                  let clip = textView.enclosingScrollView?.contentView
            else { return nil }
            layoutManager.ensureLayout(for: textRange)
            guard let fragment = layoutManager.textLayoutFragment(for: textRange.location) else { return nil }
            let documentY = fragment.layoutFragmentFrame.minY + textView.textContainerOrigin.y
            return documentY - clip.bounds.origin.y
        }

        /// Scrolls so the block's top sits at `screenY` from the viewport's
        /// top. Forcing layout for the block's new range FIRST matters twice
        /// over: the scroll math needs real (not estimated) geometry, and an
        /// un-laid-out splice region is what briefly draws overlapping
        /// lines. Content above the splice is untouched by the flip, so the
        /// fragment frame is exact once the range itself is laid out.
        func scrollBlockTop(_ range: NSRange, toScreenY screenY: CGFloat, in textView: NSTextView) {
            guard let layoutManager = textView.textLayoutManager,
                  let contentStorage = textView.textContentStorage,
                  let textRange = nsTextRange(range, in: contentStorage),
                  let clip = textView.enclosingScrollView?.contentView
            else { return }
            layoutManager.ensureLayout(for: textRange)
            guard let fragment = layoutManager.textLayoutFragment(for: textRange.location) else { return }
            let documentY = fragment.layoutFragmentFrame.minY + textView.textContainerOrigin.y
            let y = max(0, documentY - screenY)
            clip.scroll(to: NSPoint(x: clip.bounds.origin.x, y: y))
            textView.enclosingScrollView?.reflectScrolledClipView(clip)
        }

        /// The block ID at the top of the current viewport, used to keep the
        /// reading position stable across live reloads.
        /// Jump-to-section scroll that works with TextKit 2's lazy layout:
        /// force layout up to the target range first (otherwise its rect is an
        /// estimate and the scroll lands in the wrong place, or nowhere), then
        /// align the block near the top of the viewport.
        func scrollBlockToTop(_ range: NSRange, in textView: NSTextView) {
            guard let layoutManager = textView.textLayoutManager,
                  let contentStorage = textView.textContentStorage,
                  let textRange = nsTextRange(range, in: contentStorage) else {
                textView.scrollRangeToVisible(range)
                return
            }
            layoutManager.ensureLayout(for: textRange)
            guard let fragment = layoutManager.textLayoutFragment(for: textRange.location) else {
                textView.scrollRangeToVisible(range)
                return
            }
            let origin = textView.textContainerOrigin
            let top = fragment.layoutFragmentFrame.minY + origin.y
            if let clip = textView.enclosingScrollView?.contentView {
                let maxY = max(0, (textView.bounds.height) - clip.bounds.height)
                // Pin the target fragment's top exactly at the viewport top so
                // the section sampler (which probes just below the top) reads
                // this block, not the previous one. A heading's own spacing-
                // before still supplies the visual breathing room; an 8pt gap
                // here put the previous block at the very top and made the
                // outline highlight the section above on a jump.
                let y = min(max(0, top), maxY)
                clip.scroll(to: NSPoint(x: clip.bounds.origin.x, y: y))
                textView.enclosingScrollView?.reflectScrolledClipView(clip)
            } else {
                textView.scrollRangeToVisible(range)
            }
        }

        func topVisibleBlockID(in textView: NSTextView) -> BlockID? {
            guard let layoutManager = textView.textLayoutManager,
                  let contentManager = layoutManager.textContentManager,
                  let storage = textView.textContentStorage?.textStorage, storage.length > 0
            else { return nil }
            // Ask TextKit 2 which layout fragment owns the top of the viewport.
            // Unlike characterIndexForInsertion, a fragment's frame includes its
            // 28–32pt heading spacing-before, so a heading pinned (or scrolled)
            // to the top resolves to the heading itself — not the tail of the
            // previous block, which was highlighting the section above (−1).
            let origin = textView.textContainerOrigin
            let y = textView.visibleRect.minY - origin.y + 1
            let point = CGPoint(x: 1, y: max(0, y))
            guard let fragment = layoutManager.textLayoutFragment(for: point) else { return nil }
            let offset = layoutManager.offset(
                from: contentManager.documentRange.location, to: fragment.rangeInElement.location
            )
            guard offset >= 0, offset < storage.length,
                  let idString = storage.attribute(QuoinAttribute.blockID, at: offset, effectiveRange: nil) as? String
            else { return nil }
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

            let trimmed = query.trimmingCharacters(in: .whitespaces)
            defer {
                appliedQuery = query
                appliedOrdinal = activeOrdinal
                parent.onMatchCount(matchRanges.count)
            }
            guard !trimmed.isEmpty else {
                if hasAppliedSearchHighlights {
                    layoutManager.removeRenderingAttribute(.backgroundColor, for: contentStorage.documentRange)
                    hasAppliedSearchHighlights = false
                }
                matchRanges = []
                return
            }

            // Clear previous highlights across the whole document, not just
            // the remembered match ranges: after an incremental splice those
            // NSRanges are pre-edit coordinates, so clearing at the shifted
            // locations would leave stale highlights behind. Skip this entirely
            // when search has not painted highlights; large-document edits with
            // inactive search should not touch the whole TextKit document.
            if hasAppliedSearchHighlights {
                layoutManager.removeRenderingAttribute(.backgroundColor, for: contentStorage.documentRange)
                hasAppliedSearchHighlights = false
            }
            matchRanges = []

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
                guard let textRange = nsTextRange(range, in: contentStorage) else { continue }
                let color = index == activeOrdinal
                    ? theme.searchHighlight
                    : theme.searchHighlight.withAlphaComponent(0.35)
                layoutManager.addRenderingAttribute(.backgroundColor, value: color, for: textRange)
            }
            hasAppliedSearchHighlights = !matchRanges.isEmpty

            if activeOrdinal >= 0, activeOrdinal < matchRanges.count {
                textView.scrollRangeToVisible(matchRanges[activeOrdinal])
            }
        }

    }
}
#endif
