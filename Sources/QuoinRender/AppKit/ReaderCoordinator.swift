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

            // Identical STRINGS can still carry different ATTRIBUTES — a
            // plain paragraph's revealed source is the same characters as
            // its rendered text, differing only in the reveal tint and
            // fonts. A string-only splice would "change nothing" and leave
            // the old attributes behind (the shipped symptom: the reveal
            // highlight lingering on a block after clicking away). Sync
            // attribute runs in place — no text edit, so no layout jump.
            if oldChanged.length == 0, newChangedLen == 0 {
                return syncAttributesWhereDifferent(in: storage, to: newAttr)
            }

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

        /// Replaces attribute runs wherever they differ between the storage
        /// and `newAttr` (same string in both, by precondition). Returns the
        /// union range of the synced runs, or a zero range when nothing
        /// differed — non-nil either way, so callers don't re-anchor scroll
        /// for what is at most an attribute repaint.
        private static func syncAttributesWhereDifferent(
            in storage: NSTextStorage, to newAttr: NSAttributedString
        ) -> NSRange {
            var synced: NSRange?
            var location = 0
            storage.beginEditing()
            while location < newAttr.length {
                var newRunRange = NSRange()
                let newAttrs = newAttr.attributes(at: location, effectiveRange: &newRunRange)
                var oldRunRange = NSRange()
                let oldAttrs = storage.attributes(at: location, effectiveRange: &oldRunRange)
                // Compare over the shared extent of the two runs.
                let step = min(NSMaxRange(newRunRange), NSMaxRange(oldRunRange)) - location
                if !(newAttrs as NSDictionary).isEqual(to: oldAttrs) {
                    let range = NSRange(location: location, length: step)
                    storage.setAttributes(newAttrs, range: range)
                    synced = synced.map { NSUnionRange($0, range) } ?? range
                }
                location += max(step, 1)
            }
            storage.endEditing()
            return synced ?? NSRange(location: 0, length: 0)
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

        /// The pre-edit extent a projection application replaced, in OLD
        /// (pre-application) coordinates — what a pre-existing selection
        /// must be checked against. Patches carry their old ranges
        /// directly; a splice reports its new range, so the old extent is
        /// recovered from the length delta; a full replacement (nil splice)
        /// is everything.
        static func changedOldRange(
            for application: ProjectionApplication, oldLength: Int, newLength: Int
        ) -> NSRange? {
            switch application {
            case .patched(let patches):
                return patches.reduce(nil as NSRange?) { union, patch in
                    union.map { NSUnionRange($0, patch.oldRange) } ?? patch.oldRange
                }
            case .spliced(let newRange):
                guard let newRange else {
                    return NSRange(location: 0, length: oldLength)
                }
                let oldEnd = oldLength - (newLength - NSMaxRange(newRange))
                return NSRange(location: newRange.location,
                               length: max(0, oldEnd - newRange.location))
            }
        }

        /// Where a RANGE selection goes when a projection changes the text
        /// under it: nil when the selection is clear of the change and
        /// survives as-is; otherwise a zero-length caret at its start —
        /// AppKit would clamp the stale indexes into whatever content the
        /// splice put there, which read as a random selection. Zero-length
        /// changes (pure insertions) invalidate only when they land
        /// strictly inside the selection.
        static func collapsedSelection(
            _ selection: NSRange, changedOldRange: NSRange?, newLength: Int
        ) -> NSRange? {
            guard selection.length > 0, let changed = changedOldRange else { return nil }
            let intersects: Bool
            if changed.length > 0 {
                intersects = NSIntersectionRange(selection, changed).length > 0
            } else {
                intersects = changed.location > selection.location
                    && changed.location < NSMaxRange(selection)
            }
            guard intersects else { return nil }
            return NSRange(location: min(selection.location, newLength), length: 0)
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
            if QuoinLink.isEditURL(url) {
                // ‹/› edit opens the enclosing block's source (caret at the
                // body start); ✓ done on the open block commits and closes,
                // caret restored at its rendered image.
                if let id = blockID(atCharIndex: charIndex) {
                    if id == parent.rendered.activeBlockID {
                        captureDeactivationCaret(in: textView)
                        parent.onActivateBlock?(nil, nil, nil)
                    } else {
                        let hint: CaretHint? = embedCaretHint(atCharIndex: charIndex).map { .source($0) }
                        parent.onActivateBlock?(id, hint, nil)
                    }
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
            // keystroke's position — and REPLAY the keystroke there. Typing
            // on a rendered block must reveal the source AND insert the
            // character (dropping it was the editor's worst mode error: the
            // flip looked like feedback, but the input was gone). Embed
            // blocks (code/table/…) map through the 1:1 body tag; plain
            // prose uses the rendered offset. Deletes and range replacements
            // just activate — their extent has no defined image in the
            // still-hidden source.
            if let id = blockID(atCharIndex: affectedCharRange.location) {
                var hint: CaretHint?
                if isEmbedBlock(atCharIndex: affectedCharRange.location) {
                    hint = embedCaretHint(atCharIndex: affectedCharRange.location).map { .source($0) }
                }
                if hint == nil {
                    hint = blockRanges[id].map { .rendered(affectedCharRange.location - $0.location) }
                }
                let insertion = (affectedCharRange.length == 0 && replacementString?.isEmpty == false)
                    ? replacementString : nil
                parent.onActivateBlock?(id, hint, insertion)
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
                    parent.onActivateBlock?(id, nil, nil)
                }
                return
            }
            guard selection.length == 0 else { return }
            // Single click on an embed block places the caret only.
            guard !isEmbedBlock(atCharIndex: selection.location) else { return }
            guard let id = blockID(atCharIndex: selection.location) else { return }
            if id != parent.rendered.activeBlockID {
                // Land the caret where the click fell, not at the block end.
                let hint = blockRanges[id].map { CaretHint.rendered(selection.location - $0.location) }
                parent.onActivateBlock?(id, hint, nil)
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
                let target = NSRange(location: active.location + range.location, length: range.length)
                // Keep the storage's paragraph styles: the revealed fragment
                // carries the block's outer spacing (heading spacing-above,
                // trailing paragraph gap), which the bare styler pass lacks —
                // overwriting it here made the block's height collapse on the
                // first caret move after activation.
                if let existingStyle = storage.attribute(.paragraphStyle, at: target.location, effectiveRange: nil) {
                    merged[.paragraphStyle] = existingStyle
                }
                // Keep the editing-frame decoration too: the bare styler
                // pass knows nothing of block chrome, and dropping it on
                // the first caret move made the ✓ done chip flicker away.
                if let decoration = storage.attribute(QuoinAttribute.blockDecoration, at: target.location, effectiveRange: nil) {
                    merged[QuoinAttribute.blockDecoration] = decoration
                }
                storage.setAttributes(merged, range: target)
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

        /// Set when a deactivation should land the caret at the rendered
        /// image of its source position (Escape today; ⌘↩/Done later).
        /// Captured BEFORE the flip-back is requested — the projection that
        /// replaces the revealed source arrives asynchronously in
        /// updateNSView, which consumes this. Without it the flip-back left
        /// whatever stale selection the storage splice produced.
        var pendingDeactivationCaret: (id: BlockID, sourceOffset: Int, sourceText: String)?

        /// Records the current caret (relative to the active block's source)
        /// so the imminent flip-back can restore it in rendered coordinates.
        func captureDeactivationCaret(in textView: NSTextView) {
            guard let closingID = parent.rendered.activeBlockID,
                  let active = parent.rendered.activeEditableRange,
                  let source = parent.rendered.activeSourceText
            else { return }
            let relative = min(max(0, textView.selectedRange().location - active.location), active.length)
            pendingDeactivationCaret = (closingID, relative, source)
        }

        /// Absolute storage location for the caret after a flip-back.
        /// Embed read fragments tag their body 1:1 with the source content
        /// (`embedSourceStart`) — the exact inverse of `embedCaretHint` —
        /// so those map arithmetically; everything else goes through the
        /// generic source→rendered alignment walk.
        func flipBackCaretLocation(
            blockRange: NSRange, storage: NSTextStorage, sourceOffset: Int, sourceText: String
        ) -> Int {
            var contentStart: Int?
            var bodyRange: NSRange?
            let clamped = NSRange(
                location: blockRange.location,
                length: min(blockRange.length, storage.length - blockRange.location)
            )
            storage.enumerateAttribute(QuoinAttribute.embedSourceStart, in: clamped) { value, range, stop in
                if let start = value as? NSNumber, start.intValue >= 0 {
                    contentStart = start.intValue
                    bodyRange = range
                    stop.pointee = true
                }
            }
            if let contentStart, let bodyRange {
                let delta = sourceOffset - contentStart
                if delta >= 0, delta <= bodyRange.length {
                    return bodyRange.location + delta
                }
                // Before the body (the opening fence / info line) rounds to
                // the body start; past it (closing fence) to the body end.
                return delta < 0 ? bodyRange.location : NSMaxRange(bodyRange)
            }
            let renderedText = (storage.string as NSString).substring(with: blockRange)
            return Self.deactivationCaretLocation(
                blockRange: blockRange, renderedText: renderedText,
                sourceOffset: sourceOffset, sourceText: sourceText
            )
        }

        /// The generic (non-embed) flip-back mapping: the rendered image of
        /// `sourceOffset`, rounded BACKWARD to visible content — a caret at
        /// the source's end must sit after the last rendered character,
        /// never forward across the trailing block separator into the next
        /// block.
        static func deactivationCaretLocation(
            blockRange: NSRange, renderedText: String, sourceOffset: Int, sourceText: String
        ) -> Int {
            let mapped = EditMapping.renderedOffsets(
                forSourceOffsets: [sourceOffset],
                renderedText: renderedText,
                sourceText: sourceText
            ).first ?? 0
            let ns = renderedText as NSString
            var contentEnd = ns.length
            while contentEnd > 0, ns.character(at: contentEnd - 1) == 0x0A { contentEnd -= 1 }
            return blockRange.location + min(max(0, mapped), contentEnd)
        }

        /// Esc closes the revealed block, committing as always (Escape
        /// never reverts — every keystroke is already in the file; backing
        /// out is ⌘Z's job) and restoring the caret at the rendered image
        /// of where it was.
        public func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            if commandSelector == #selector(NSResponder.cancelOperation(_:)),
               parent.rendered.activeBlockID != nil {
                captureDeactivationCaret(in: textView)
                parent.onActivateBlock?(nil, nil, nil)
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
        /// source position matching the click: code bodies map exactly
        /// (1:1 with source content); embeds without a body marker (tables,
        /// math, diagrams) fall back to the raw rendered offset, which the
        /// model's rendered↔source alignment maps — the same machinery that
        /// keeps prose and list clicks exact. The old nil fallback dumped
        /// the caret at the BLOCK END, and the caret-line pin then dragged
        /// the last line up to the click.
        @discardableResult
        func activateEmbedBlock(atCharIndex index: Int) -> Bool {
            guard isEmbedBlock(atCharIndex: index),
                  let id = blockID(atCharIndex: index),
                  id != parent.rendered.activeBlockID else { return false }
            let hint: CaretHint? = embedCaretHint(atCharIndex: index).map { .source($0) }
                ?? blockRanges[id].map { .rendered(index - $0.location) }
            parent.onActivateBlock?(id, hint, nil)
            return true
        }

        /// Where the caret should land when an embed block flips to source.
        /// The rendered code body is character-for-character 1:1 with the
        /// source content (the copy button and edit mapping depend on it),
        /// so a double-click INSIDE the body maps exactly: source content
        /// start + the click's offset into the rendered body. The old
        /// content-start-only shortcut teleported the caret to the block's
        /// first line — and the caret-line viewport pin then dragged line 1
        /// down to the clicked position, lurching the whole block. Clicks
        /// outside the body (header chip, attachment) keep the
        /// content-start fallback.
        func embedCaretHint(atCharIndex index: Int) -> Int? {
            guard let storage = textView?.textContentStorage?.textStorage,
                  let id = blockID(atCharIndex: index),
                  let blockRange = blockRanges[id] else { return nil }
            var contentStart: Int?
            var bodyRange: NSRange?
            let clamped = NSRange(
                location: blockRange.location,
                length: min(blockRange.length, storage.length - blockRange.location)
            )
            storage.enumerateAttribute(QuoinAttribute.embedSourceStart, in: clamped) { value, range, stop in
                if let start = value as? NSNumber {
                    contentStart = start.intValue
                    bodyRange = range
                    stop.pointee = true
                }
            }
            guard let contentStart else { return nil }
            if let bodyRange, index >= bodyRange.location, index <= NSMaxRange(bodyRange) {
                return contentStart + (index - bodyRange.location)
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
        func scrollBlockTop(_ range: NSRange, toScreenY screenY: CGFloat, in textView: NSTextView,
                            settle: Bool = true) {
            guard let layoutManager = textView.textLayoutManager,
                  let contentStorage = textView.textContentStorage,
                  let textRange = nsTextRange(range, in: contentStorage),
                  let clip = textView.enclosingScrollView?.contentView
            else { return }
            layoutManager.ensureLayout(for: textRange)
            guard let fragment = layoutManager.textLayoutFragment(for: textRange.location) else { return }
            let documentY = fragment.layoutFragmentFrame.minY + textView.textContainerOrigin.y
            let y = max(0, documentY - screenY)
            // Height-neutral reveals leave the pin where it already is —
            // don't touch the clip view for a sub-point correction, or
            // keyboard traversal picks up a micro-jitter at every block
            // boundary.
            if abs(y - clip.bounds.origin.y) > 0.5 {
                clip.scroll(to: NSPoint(x: clip.bounds.origin.x, y: y))
                textView.enclosingScrollView?.reflectScrolledClipView(clip)
            }
            guard settle else { return }
            // Second pass after TextKit resolves estimated geometry for the
            // spliced region (see pinCaretLine — same lie, same cure).
            DispatchQueue.main.async { [weak self, weak textView] in
                guard let self, let textView,
                      let layoutManager = textView.textLayoutManager else { return }
                if let viewport = layoutManager.textViewportLayoutController.viewportRange {
                    layoutManager.ensureLayout(for: viewport)
                }
                self.scrollBlockTop(range, toScreenY: screenY, in: textView, settle: false)
            }
        }

        /// The on-screen y of the LINE containing `location` (distance from
        /// the viewport's top), or nil when geometry is unavailable. This is
        /// the anchor for the viewport invariant: the line the user touched.
        func lineScreenY(at location: Int, in textView: NSTextView) -> CGFloat? {
            guard location >= 0,
                  let layoutManager = textView.textLayoutManager,
                  let contentStorage = textView.textContentStorage,
                  let textRange = nsTextRange(NSRange(location: location, length: 0), in: contentStorage),
                  let clip = textView.enclosingScrollView?.contentView
            else { return nil }
            layoutManager.ensureLayout(for: textRange)
            guard let fragment = layoutManager.textLayoutFragment(for: textRange.location) else { return nil }
            return fragment.layoutFragmentFrame.minY + textView.textContainerOrigin.y - clip.bounds.origin.y
        }

        /// Scrolls so the line containing `location` sits at `screenY` from
        /// the viewport top — restoring the user's point of attention after
        /// a projection change, whatever happened to the heights around it.
        ///
        /// TWO passes, because TextKit 2 lies at first: the immediate pin
        /// measures against whatever geometry exists NOW — and a fresh
        /// splice's heights are ESTIMATES that can settle hundreds of points
        /// away (a link-heavy list wraps its revealed source; a block
        /// spanning the fold resolves lazily). The reported symptom: click a
        /// list item near the fold and the whole list dives down-screen.
        /// So: eagerly lay out the revealed block first (real within-block
        /// geometry), pin, then re-pin on the next runloop turn after
        /// ensuring the viewport's real layout — idempotent, and a no-op
        /// when the first pin was already right.
        func pinCaretLine(
            at location: Int, toScreenY screenY: CGFloat, in textView: NSTextView,
            ensuringLayoutOf blockRange: NSRange? = nil, settle: Bool = true
        ) {
            guard let layoutManager = textView.textLayoutManager,
                  let contentStorage = textView.textContentStorage,
                  let textRange = nsTextRange(NSRange(location: location, length: 0), in: contentStorage),
                  let clip = textView.enclosingScrollView?.contentView
            else { return }
            if let blockRange, let blockTextRange = nsTextRange(blockRange, in: contentStorage) {
                layoutManager.ensureLayout(for: blockTextRange)
            }
            // Settle the viewport's real geometry BEFORE measuring: the
            // immediate pin otherwise scrolls against estimates and the
            // async correction lands a frame later — a visible double-hop
            // (traced live at 125pt on a fold-straddling list).
            if settle, let viewport = layoutManager.textViewportLayoutController.viewportRange {
                layoutManager.ensureLayout(for: viewport)
            }
            layoutManager.ensureLayout(for: textRange)
            guard let fragment = layoutManager.textLayoutFragment(for: textRange.location) else { return }
            let documentY = fragment.layoutFragmentFrame.minY + textView.textContainerOrigin.y
            let y = max(0, documentY - screenY)
            QuoinPerformanceTrace.log(
                "anchor.pinCaretLine", startedAt: DispatchTime.now().uptimeNanoseconds,
                metadata: "loc=\(location) targetScreenY=\(Int(screenY)) docY=\(Int(documentY)) clipY=\(Int(clip.bounds.origin.y)) newY=\(Int(y)) settlePass=\(!settle)")
            if abs(y - clip.bounds.origin.y) > 0.5 {
                clip.scroll(to: NSPoint(x: clip.bounds.origin.x, y: y))
                textView.enclosingScrollView?.reflectScrolledClipView(clip)
            }
            guard settle else { return }
            DispatchQueue.main.async { [weak self, weak textView] in
                guard let self, let textView,
                      let layoutManager = textView.textLayoutManager else { return }
                // Settle the geometry the user is about to see, then correct.
                if let viewport = layoutManager.textViewportLayoutController.viewportRange {
                    layoutManager.ensureLayout(for: viewport)
                }
                self.pinCaretLine(at: location, toScreenY: screenY, in: textView,
                                  ensuringLayoutOf: blockRange, settle: false)
            }
        }

        /// Scrolls only when the caret is NOT already visible — and then by
        /// the minimal amount, using settled layout. Arrowing through a
        /// document must feel native: no scroll while the caret is on
        /// screen, one small nudge when it crosses the fold. The old
        /// unconditional `scrollRangeToVisible` re-scrolled on every block
        /// activation (against TextKit 2's estimates, no less), which is
        /// what made keyboard traversal lurch at block boundaries.
        func scrollCaretIntoViewIfNeeded(_ location: Int, in textView: NSTextView) {
            guard let layoutManager = textView.textLayoutManager,
                  let contentStorage = textView.textContentStorage,
                  let textRange = nsTextRange(NSRange(location: location, length: 0), in: contentStorage),
                  let clip = textView.enclosingScrollView?.contentView
            else {
                textView.scrollRangeToVisible(NSRange(location: location, length: 0))
                return
            }
            layoutManager.ensureLayout(for: textRange)
            guard let fragment = layoutManager.textLayoutFragment(for: textRange.location) else {
                textView.scrollRangeToVisible(NSRange(location: location, length: 0))
                return
            }
            let origin = textView.textContainerOrigin
            let lineTop = fragment.layoutFragmentFrame.minY + origin.y
            let lineBottom = fragment.layoutFragmentFrame.maxY + origin.y
            let visibleTop = clip.bounds.origin.y
            let visibleBottom = visibleTop + clip.bounds.height
            let padding: CGFloat = 8
            var target: CGFloat?
            if lineTop < visibleTop + padding {
                target = max(0, lineTop - padding)
            } else if lineBottom > visibleBottom - padding {
                target = lineBottom + padding - clip.bounds.height
            }
            guard let target, abs(target - visibleTop) > 0.5 else { return }
            QuoinPerformanceTrace.log(
                "anchor.caretIntoView", startedAt: DispatchTime.now().uptimeNanoseconds,
                metadata: "loc=\(location) from=\(Int(visibleTop)) to=\(Int(target))")
            clip.scroll(to: NSPoint(x: clip.bounds.origin.x, y: max(0, target)))
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
