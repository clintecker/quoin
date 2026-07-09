#if canImport(AppKit) || canImport(UIKit)
import Foundation
import ImageIO
import QuoinCore
import MermaidRender

#if canImport(AppKit)
import AppKit
#else
import UIKit
#endif

/// A rendered document: one attributed string for the whole document plus
/// the character range of every top-level block, which powers TOC jumps,
/// search navigation, and scroll anchoring across live reloads.
public struct RenderSpliceHint: Sendable {
    public let oldRange: NSRange
    public let replacementRange: NSRange

    public init(oldRange: NSRange, replacementRange: NSRange) {
        self.oldRange = oldRange
        self.replacementRange = replacementRange
    }
}

public struct RenderStoragePatch {
    public let oldRange: NSRange
    public let replacement: NSAttributedString

    public init(oldRange: NSRange, replacement: NSAttributedString) {
        self.oldRange = oldRange
        self.replacement = replacement
    }
}

public struct RenderedDocument {
    public let attributed: NSAttributedString
    public let blockRanges: [BlockID: NSRange]
    /// When a block is active in the editor (syntax reveal), its literal
    /// source is rendered in place; this is that run's location and text.
    public let activeBlockID: BlockID?
    public let activeEditableRange: NSRange?
    public let activeSourceText: String?
    /// AppKit can use this to apply a bounded TextKit splice for simple
    /// active-block edits instead of scanning the whole rendered string.
    public let spliceHint: RenderSpliceHint?
    /// AppKit can apply these attributed replacements directly to live
    /// TextKit storage, in order. Used when the model has already proven a
    /// block-local change (an active-block edit, or an activate/deactivate
    /// flip) and rendering the whole document would be wasted work. Patches
    /// MUST be ordered by DESCENDING location so applying one never shifts
    /// the ranges of those still pending.
    public let storagePatches: [RenderStoragePatch]

    /// Convenience for the single-patch case (active-block edits).
    public var storagePatch: RenderStoragePatch? { storagePatches.first }

    /// Monotonic marker for "has this exact projection been applied to the
    /// live storage yet". `updateNSView` runs on every SwiftUI pass; without
    /// this, a patch-bearing projection would re-apply its patches on each
    /// pass and corrupt the storage (object identity of `attributed` can't
    /// distinguish patch generations — patches deliberately reuse it).
    public let revision: Int

    /// The storage length (UTF-16) the patches expect BEFORE application.
    /// Patches are diffs against a specific storage state; SwiftUI can
    /// coalesce rapid publishes so the view skips an intermediate patch
    /// revision — applying the next batch to that stale storage silently
    /// corrupts the projection (drifting caret mapping, keystrokes falling
    /// outside the editable range and being swallowed). On a length
    /// mismatch the view must ignore the patches and resync by splicing to
    /// `attributed`, which the model keeps authoritative.
    public let patchBaseLength: Int?

    public init(
        attributed: NSAttributedString,
        blockRanges: [BlockID: NSRange],
        activeBlockID: BlockID? = nil,
        activeEditableRange: NSRange? = nil,
        activeSourceText: String? = nil,
        spliceHint: RenderSpliceHint? = nil,
        storagePatch: RenderStoragePatch? = nil,
        storagePatches: [RenderStoragePatch] = [],
        revision: Int = 0,
        patchBaseLength: Int? = nil
    ) {
        self.attributed = attributed
        self.blockRanges = blockRanges
        self.activeBlockID = activeBlockID
        self.activeEditableRange = activeEditableRange
        self.activeSourceText = activeSourceText
        self.spliceHint = spliceHint
        self.storagePatches = storagePatch.map { [$0] } ?? storagePatches
        self.revision = revision
        self.patchBaseLength = patchBaseLength
    }

    public static let empty = RenderedDocument(attributed: NSAttributedString(), blockRanges: [:])
}

/// Renders a `QuoinDocument` into attributed text for TextKit 2.
///
/// M1 scope: full native text rendering for all block types. Math and
/// mermaid render as styled source (their runs are tagged with
/// `QuoinAttribute` keys so QuoinMath/QuoinDiagram can replace them in
/// M2a/M2b without touching this pipeline). Tables use measured tab stops;
/// the richer table attachment view is a later refinement.
public struct AttributedRenderer {

    public let theme: Theme
    /// Directory of the open document, for resolving relative image paths.
    public let baseURL: URL?
    /// Remote images are opt-in per document (local-only by default).
    public let loadsRemoteImages: Bool
    /// Fired (off-main) when an async-decoded image becomes available and
    /// the document should re-render to pick it up.
    public let onContentReady: (@Sendable () -> Void)?

    public init(
        theme: Theme = Theme(),
        baseURL: URL? = nil,
        loadsRemoteImages: Bool = false,
        onContentReady: (@Sendable () -> Void)? = nil
    ) {
        self.theme = theme
        self.baseURL = baseURL
        self.loadsRemoteImages = loadsRemoteImages
        self.onContentReady = onContentReady
    }

    /// Convenience for callers that don't keep a cache (exporters, tests).
    public func render(
        _ document: QuoinDocument,
        activeBlockID: BlockID? = nil,
        activeCaret: Int? = nil
    ) -> RenderedDocument {
        var throwaway: [BlockID: NSAttributedString] = [:]
        return render(document, activeBlockID: activeBlockID, activeCaret: activeCaret, cache: &throwaway)
    }

    /// A block's rendered fragment is a pure function of the block, so an
    /// unchanged block (same content-hashed `BlockID`) reuses its cached
    /// fragment instead of being rebuilt. This turns a keystroke's re-render
    /// from O(document) into O(changed blocks) — the whole-doc rebuild was the
    /// dominant per-keystroke cost. TOC is excluded because it reflects the
    /// document-wide outline, not just its own content.
    private func isCacheable(_ kind: BlockKind) -> Bool {
        if case .tableOfContents = kind { return false }
        return true
    }

    public func render(
        _ document: QuoinDocument,
        activeBlockID: BlockID? = nil,
        activeCaret: Int? = nil,
        cache: inout [BlockID: NSAttributedString]
    ) -> RenderedDocument {
        let output = NSMutableAttributedString()
        var blockRanges: [BlockID: NSRange] = [:]
        var activeEditableRange: NSRange?
        var activeSourceText: String?
        var newCache: [BlockID: NSAttributedString] = [:]

        for (index, block) in document.blocks.enumerated() {
            let start = output.length
            if block.id == activeBlockID,
               let slice = document.source.substring(in: block.range) {
                // Syntax reveal: the active block shows its literal source,
                // editable in place. Only the caret's span reveals its
                // delimiters (handoff span-level rule). Never cached — its
                // fragment changes as the caret moves.
                let editable = renderEditableSource(slice, caretOffset: activeCaret, block: block, document: document)
                activeEditableRange = NSRange(location: start, length: editable.length)
                activeSourceText = slice
                output.append(editable)
            } else if isCacheable(block.kind), let cached = cache[block.id] {
                newCache[block.id] = cached
                output.append(cached)
            } else {
                // A fragment awaiting async content (an image still decoding)
                // must NOT be cached: its BlockID is content-hash-stable, so a
                // cached placeholder would be returned forever — the decoded
                // image's re-render would hit the cache and never rebuild. The
                // fragment marks itself pending (QuoinAttribute.pendingContent).
                let fragment = render(block: block, depth: 0, document: document)
                if isCacheable(block.kind), !fragmentHasPendingContent(fragment) {
                    newCache[block.id] = fragment
                }
                output.append(fragment)
            }
            if index < document.blocks.count - 1 {
                let nextKind = document.blocks[index + 1].kind
                // The separator after a revealed block whose slice carries
                // its own trailing newline would lay out as a phantom empty
                // paragraph (~a full line) the reading projection never
                // shows; clamp it to near-zero height (same characters, so
                // every range stays valid).
                if block.id == activeBlockID, let text = activeSourceText,
                   Self.revealNeedsClampedSeparator(text) {
                    output.append(clampedSeparator(after: block.kind, before: nextKind))
                } else {
                    output.append(blockSeparator(after: block.kind, before: nextKind))
                }
            }
            blockRanges[block.id] = NSRange(location: start, length: output.length - start)
        }

        // Footnotes gather at document end: 12/1.6 secondary, top hairline.
        if !document.footnotes.isEmpty {
            let base = output.length
            let (footnoteText, footnoteRanges) = renderFootnotes(document)
            output.append(footnoteText)
            for (id, range) in footnoteRanges {
                blockRanges[id] = NSRange(location: base + range.location, length: range.length)
            }
        }
        // Keep only fragments for blocks still present; drops removed blocks.
        cache = newCache
        return RenderedDocument(
            attributed: output,
            blockRanges: blockRanges,
            activeBlockID: activeBlockID,
            activeEditableRange: activeEditableRange,
            activeSourceText: activeSourceText
        )
    }

    public func renderEditableSourceFragment(
        _ slice: String, caretOffset: Int? = nil,
        block: Block? = nil, document: QuoinDocument? = nil
    ) -> NSAttributedString {
        renderEditableSource(slice, caretOffset: caretOffset, block: block, document: document)
    }

    /// One block's READ fragment, exactly as the full render loop would
    /// produce it (blockID/embed tagging included) — so an activate/
    /// deactivate flip can patch a single block into live storage instead of
    /// re-rendering the document. `hasPendingContent` mirrors the cacheability
    /// rule: a fragment holding a still-decoding image must not be cached.
    public func renderReadFragment(
        _ block: Block, document: QuoinDocument
    ) -> (fragment: NSAttributedString, hasPendingContent: Bool) {
        let fragment = render(block: block, depth: 0, document: document)
        return (fragment, fragmentHasPendingContent(fragment))
    }

    /// Length of the separator the full render inserts between these two
    /// block kinds — deterministic from the kinds, which is what makes
    /// activation flips patchable (the flip never changes a block's kind,
    /// so the separator is untouched).
    public func separatorLength(after kind: BlockKind, before nextKind: BlockKind) -> Int {
        blockSeparator(after: kind, before: nextKind).length
    }

    /// Everything a host needs to apply an activate/deactivate flip as
    /// bounded storage patches instead of a full re-render.
    public struct ActivationFlipUpdate {
        /// Ordered by DESCENDING location, disjoint.
        public let storagePatches: [RenderStoragePatch]
        public let blockRanges: [BlockID: NSRange]
        public let activeEditableRange: NSRange?
        public let activeSourceText: String?
        /// The deactivated block's fresh read fragment, safe to cache
        /// (nil when it holds still-decoding async content).
        public let cacheableReadFragment: (id: BlockID, fragment: NSAttributedString)?
    }

    /// Computes the storage patches for an activation flip (`oldID` closes,
    /// `newID` opens; either may be nil). A flip changes only the flipped
    /// blocks' PROJECTION — the document is untouched — so at most two
    /// fragments change and everything else shifts. Returns nil when the
    /// projection state doesn't line up; the caller then does a full
    /// re-render, which is always correct.
    public func activationFlipUpdate(
        document: QuoinDocument,
        current: RenderedDocument,
        from oldID: BlockID?,
        to newID: BlockID?,
        caret: Int?
    ) -> ActivationFlipUpdate? {
        // Footnote-bearing documents append footnote ranges after the block
        // loop; their bookkeeping isn't worth replicating here.
        guard document.footnotes.isEmpty, oldID != newID else { return nil }

        var patches: [(location: Int, patch: RenderStoragePatch, blockID: BlockID, newLength: Int, oldLength: Int)] = []
        var cacheable: (id: BlockID, fragment: NSAttributedString)?
        var activeSourceText: String?

        // Deactivation: the old editable run flips back to its read fragment,
        // and its separator (clamped during the reveal) back to normal. The
        // patch spans fragment + separator so both projections stay
        // reproducible from either path.
        if let oldID {
            guard let editableRange = current.activeEditableRange,
                  current.activeBlockID == oldID,
                  let blockIndex = document.blocks.firstIndex(where: { $0.id == oldID }),
                  let oldBlockRange = current.blockRanges[oldID],
                  oldBlockRange.location == editableRange.location,
                  oldBlockRange.length >= editableRange.length
            else { return nil }
            let block = document.blocks[blockIndex]
            let (fragment, pending) = renderReadFragment(block, document: document)
            if !pending { cacheable = (oldID, fragment) }
            let replacement = NSMutableAttributedString(attributedString: fragment)
            if blockIndex < document.blocks.count - 1 {
                replacement.append(blockSeparator(
                    after: block.kind, before: document.blocks[blockIndex + 1].kind))
            }
            patches.append((
                location: oldBlockRange.location,
                patch: RenderStoragePatch(oldRange: oldBlockRange, replacement: replacement),
                blockID: oldID, newLength: replacement.length, oldLength: oldBlockRange.length
            ))
        }

        // Activation: the new block's read fragment flips to editable source.
        var newEditableLength = 0
        if let newID {
            guard let blockIndex = document.blocks.firstIndex(where: { $0.id == newID }),
                  let blockRange = current.blockRanges[newID],
                  let slice = document.source.substring(in: document.blocks[blockIndex].range)
            else { return nil }
            let block = document.blocks[blockIndex]
            // The patch spans fragment + separator: the separator's
            // CHARACTERS are constant (range bookkeeping depends on that),
            // but a revealed slice that ends with its own newline needs the
            // separator clamped to near-zero height or it lays out as a
            // phantom empty paragraph the reading projection never shows.
            let editable = renderEditableSourceFragment(slice, caretOffset: caret, block: block, document: document)
            let replacement = NSMutableAttributedString(attributedString: editable)
            if blockIndex < document.blocks.count - 1 {
                let nextKind = document.blocks[blockIndex + 1].kind
                replacement.append(Self.revealNeedsClampedSeparator(slice)
                    ? clampedSeparator(after: block.kind, before: nextKind)
                    : blockSeparator(after: block.kind, before: nextKind))
            }
            patches.append((
                location: blockRange.location,
                patch: RenderStoragePatch(oldRange: blockRange, replacement: replacement),
                blockID: newID, newLength: replacement.length, oldLength: blockRange.length
            ))
            activeSourceText = slice
            newEditableLength = editable.length
        }

        guard !patches.isEmpty else { return nil }
        patches.sort { $0.location > $1.location }
        if patches.count == 2, NSMaxRange(patches[1].patch.oldRange) > patches[0].patch.oldRange.location {
            return nil
        }

        // Shift every block range by the deltas of patches located before it.
        var ranges: [BlockID: NSRange] = [:]
        ranges.reserveCapacity(current.blockRanges.count)
        for (blockID, range) in current.blockRanges {
            var location = range.location
            var length = range.length
            for entry in patches {
                let delta = entry.newLength - entry.oldLength
                if entry.blockID == blockID {
                    length += delta
                } else if entry.location < range.location {
                    location += delta
                }
            }
            ranges[blockID] = NSRange(location: location, length: length)
        }
        var activeEditableRange: NSRange?
        if let newID, let newRange = ranges[newID] {
            activeEditableRange = NSRange(location: newRange.location, length: newEditableLength)
        }

        return ActivationFlipUpdate(
            storagePatches: patches.map(\.patch),
            blockRanges: ranges,
            activeEditableRange: activeEditableRange,
            activeSourceText: activeSourceText,
            cacheableReadFragment: cacheable
        )
    }

    /// The inter-block separator. Boxed blocks (callouts, code, tables,
    /// diagrams, the front-matter chip) get extra air so two adjacent cards
    /// never touch borders; the separator sits outside either block's
    /// decoration range, so this widens the external gap without padding the
    /// box interiors. A heading hugs the card it introduces, so the extra air
    /// is added only after a card, or before a card not introduced by a heading.
    private func blockSeparator(after currentKind: BlockKind, before nextKind: BlockKind) -> NSAttributedString {
        let separator = NSMutableAttributedString(string: "\n", attributes: bodyAttributes())
        let currentIsHeading: Bool = { if case .heading = currentKind { return true } else { return false } }()
        if isCard(currentKind) || (isCard(nextKind) && !currentIsHeading) {
            // A genuine short empty paragraph guarantees the external gap.
            // Paragraph-spacing on the plain separator alone is unreliable —
            // that newline terminates the previous paragraph and inherits its
            // style — so append a dedicated low spacer line instead.
            var spacer = bodyAttributes()
            spacer[.font] = PlatformFont.systemFont(ofSize: 14)
            let spacerStyle = NSMutableParagraphStyle()
            spacerStyle.lineHeightMultiple = 1
            spacerStyle.paragraphSpacing = 0
            spacer[.paragraphStyle] = spacerStyle
            separator.append(NSAttributedString(string: "\n", attributes: spacer))
        }
        return separator
    }

    /// The footnote section appended at document end (12/1.6 secondary text
    /// under a top hairline). Returns the rendered run plus each footnote's
    /// first-block range *relative to the run's start*; the caller offsets
    /// them by the append position.
    private func renderFootnotes(_ document: QuoinDocument) -> (NSAttributedString, [BlockID: NSRange]) {
        let output = NSMutableAttributedString()
        var ranges: [BlockID: NSRange] = [:]
        output.append(NSAttributedString(string: "\n", attributes: bodyAttributes()))
        output.append(renderThematicBreak())
        for footnote in document.footnotes {
            output.append(NSAttributedString(string: "\n", attributes: bodyAttributes()))
            let start = output.length
            var marker = bodyAttributes()
            marker[.font] = PlatformFont.systemFont(ofSize: 12, weight: .semibold)
            marker[.foregroundColor] = theme.accent
            output.append(NSAttributedString(string: "\(footnote.index). ", attributes: marker))
            for block in footnote.blocks {
                let body = NSMutableAttributedString(attributedString: render(block: block, depth: 0, document: document))
                let full = NSRange(location: 0, length: body.length)
                body.addAttribute(.font, value: PlatformFont.systemFont(ofSize: 12), range: full)
                body.addAttribute(.foregroundColor, value: theme.secondaryTextColor, range: full)
                output.append(body)
            }
            if let firstBlock = footnote.blocks.first {
                ranges[firstBlock.id] = NSRange(location: start, length: output.length - start)
            }
        }
        return (output, ranges)
    }

    /// The active block's raw markdown, styled for in-place editing:
    /// content approximates its rendered look, delimiters stay visible at
    /// 35% ink mono (syntax reveal), and the character mapping stays 1:1.
    ///
    /// Layout preservation is the point of in-place editing: the revealed
    /// source must keep the block's VERTICAL SKELETON — spacing between
    /// hard-break lines, list-item gaps and indents, a heading's air, the
    /// trailing paragraph gap — so entering and leaving edit mode doesn't
    /// reflow the page. For text-family blocks that means transplanting the
    /// READ fragment's paragraph styles onto the source line by line (the
    /// same text alignment that maps clicks to carets finds each source
    /// line's rendered anchor). Embed blocks (code, mermaid, math, table)
    /// keep tuned constants instead: re-rendering a diagram per keystroke
    /// just to copy its one paragraph style would defeat the render cache.
    private func renderEditableSource(
        _ slice: String, caretOffset: Int? = nil,
        block: Block? = nil, document: QuoinDocument? = nil
    ) -> NSAttributedString {
        let styled = NSMutableAttributedString(
            attributedString: MarkdownSourceStyler(theme: theme).style(slice, caretOffset: caretOffset))
        guard styled.length > 0 else { return styled }

        if let block, let document {
            switch block.kind {
            case .paragraph, .heading, .list, .blockQuote, .callout, .thematicBreak, .table:
                let read = render(block: block, depth: 0, document: document)
                transplantParagraphStyles(from: read, onto: styled, source: slice)
                return styled
            default:
                break
            }
        }

        // Fallback (embed kinds, or no block context): mirror the code
        // canvas's line metrics and the body's trailing gap.
        applyFallbackMetrics(to: styled, kind: block?.kind)
        return styled
    }

    /// True when an active block's revealed slice ends with its own newline
    /// — the block separator that FOLLOWS it then forms an empty paragraph
    /// of its own (a phantom ~40pt line the rendered projection never
    /// shows; list ranges end this way). The separator's characters must
    /// stay (all range bookkeeping assumes constant separators), so the
    /// separator is instead styled to near-zero height while the block is
    /// revealed.
    static func revealNeedsClampedSeparator(_ slice: String) -> Bool {
        slice.hasSuffix("\n")
    }

    /// The block separator, styled to near-zero height (same characters).
    func clampedSeparator(after kind: BlockKind, before nextKind: BlockKind) -> NSAttributedString {
        let separator = NSMutableAttributedString(
            attributedString: blockSeparator(after: kind, before: nextKind))
        mutateParagraphStyles(in: separator, range: NSRange(location: 0, length: separator.length)) { style, _ in
            style.maximumLineHeight = 2
            style.minimumLineHeight = 0
            style.paragraphSpacing = 0
            style.paragraphSpacingBefore = 0
            style.lineHeightMultiple = 1
        }
        return separator
    }

    /// Copies each rendered line's paragraph style onto the corresponding
    /// source line. Source lines with no rendered counterpart (fences,
    /// blank lines) inherit the style at their alignment boundary — their
    /// neighbor's.
    private func transplantParagraphStyles(
        from read: NSAttributedString,
        onto styled: NSMutableAttributedString,
        source: String
    ) {
        guard read.length > 0 else { return }
        let text = styled.string as NSString
        let full = NSRange(location: 0, length: text.length)
        var lineRanges: [NSRange] = []
        var location = 0
        while location < text.length {
            let line = text.lineRange(for: NSRange(location: location, length: 0))
            lineRanges.append(line)
            location = NSMaxRange(line)
            if line.length == 0 { break }
        }
        guard !lineRanges.isEmpty else { return }

        let anchors = EditMapping.renderedOffsets(
            forSourceOffsets: lineRanges.map(\.location),
            renderedText: read.string,
            sourceText: source
        )
        for (line, anchor) in zip(lineRanges, anchors) {
            let clampedAnchor = min(max(0, anchor), read.length - 1)
            guard let style = read.attribute(.paragraphStyle, at: clampedAnchor, effectiveRange: nil)
                as? NSParagraphStyle else { continue }
            let clamped = NSRange(location: line.location,
                                  length: min(line.length, full.length - line.location))
            guard clamped.length > 0 else { continue }
            styled.addAttribute(.paragraphStyle, value: style, range: clamped)
        }
    }

    /// Tuned constants for blocks whose read fragment shouldn't be rebuilt
    /// per keystroke (diagram/code canvases): code-canvas line height,
    /// tight interior, body trailing gap.
    private func applyFallbackMetrics(to styled: NSMutableAttributedString, kind: BlockKind?) {
        let text = styled.string as NSString
        let full = NSRange(location: 0, length: text.length)
        var lastParagraph = full
        text.enumerateSubstrings(in: full, options: [.byParagraphs, .substringNotRequired]) { _, range, _, _ in
            if range.length > 0 { lastParagraph = range }
        }
        mutateParagraphStyles(in: styled, range: full) { style, _ in
            style.lineHeightMultiple = 1.6   // code canvas metric (12/1.6)
            style.paragraphSpacing = 0
        }
        mutateParagraphStyles(in: styled, range: lastParagraph) { style, _ in
            style.paragraphSpacing = theme.paragraphSpacing
        }
    }

    /// Mutates a copy of each effective paragraph style run within `range`.
    private func mutateParagraphStyles(
        in output: NSMutableAttributedString, range: NSRange,
        _ mutate: (NSMutableParagraphStyle, NSRange) -> Void
    ) {
        guard range.length > 0, range.location < output.length else { return }
        let clamped = NSRange(location: range.location,
                              length: min(range.length, output.length - range.location))
        output.enumerateAttribute(.paragraphStyle, in: clamped) { value, runRange, _ in
            let style = ((value as? NSParagraphStyle)?.mutableCopy() as? NSMutableParagraphStyle)
                ?? NSMutableParagraphStyle()
            mutate(style, runRange)
            output.addAttribute(.paragraphStyle, value: style, range: runRange)
        }
    }

    // MARK: - Blocks

    /// Blocks drawn as a bordered/filled card, which need extra external air
    /// so two adjacent ones never share a border line.
    private func isCard(_ kind: BlockKind) -> Bool {
        switch kind {
        case .codeBlock, .mermaid, .table, .callout, .frontMatter, .htmlBlock:
            return true
        default:
            return false
        }
    }

    private func render(block: Block, depth: Int, document: QuoinDocument) -> NSAttributedString {
        let content: NSAttributedString
        switch block.kind {
        case .heading(let level, let inlines, _):
            content = renderHeading(level: level, inlines: inlines)
        case .paragraph(let inlines):
            content = renderInlines(inlines, base: bodyAttributes())
        case .codeBlock(let language, let code):
            content = renderCodeBlock(language: language, code: code)
        case .mermaid(let source):
            content = renderMermaidFallback(source: source)
        case .mathBlock(let latex):
            content = renderMathBlockFallback(latex: latex)
        case .table(let header, let rows, let alignments):
            content = renderTable(header: header, rows: rows, alignments: alignments)
        case .list(let items, let ordered, let start):
            content = renderList(items: items, ordered: ordered, start: start, depth: depth, document: document)
        case .blockQuote(let children):
            content = renderBlockQuote(children: children, depth: depth, document: document)
        case .callout(let kind, let children):
            content = renderCallout(kind: kind, children: children, depth: depth, document: document)
        case .frontMatter(let yaml):
            content = renderFrontMatter(yaml: yaml)
        case .tableOfContents:
            content = renderTOC(outline: document.outline)
        case .thematicBreak:
            content = renderThematicBreak()
        case .htmlBlock(let html):
            content = renderCodeBlock(language: "html", code: html)
        }

        let tagged = NSMutableAttributedString(attributedString: content)
        let whole = NSRange(location: 0, length: tagged.length)
        tagged.addAttribute(QuoinAttribute.blockID, value: block.id.description, range: whole)
        // Embed blocks flip to source on double-click, not single click, so a
        // click to admire a rendered diagram/table doesn't turn it into code.
        switch block.kind {
        case .codeBlock, .mermaid, .mathBlock, .table, .htmlBlock:
            tagged.addAttribute(QuoinAttribute.embedBlock, value: NSNumber(value: true), range: whole)
        default:
            break
        }
        // Resolve the code body's caret-mapping marker to the real source
        // offset: the rendered body is 1:1 with the source content, which sits
        // after the opening fence line in the block's source slice.
        if case .codeBlock = block.kind,
           let slice = document.source.substring(in: block.range) {
            let sliceNS = slice as NSString
            tagged.enumerateAttribute(QuoinAttribute.embedSourceStart, in: whole) { value, range, _ in
                guard (value as? NSNumber)?.intValue == -1 else { return }
                let bodyText = tagged.attributedSubstring(from: range).string
                let found = sliceNS.range(of: bodyText)
                if found.location != NSNotFound {
                    tagged.addAttribute(QuoinAttribute.embedSourceStart,
                                        value: NSNumber(value: found.location), range: range)
                } else {
                    tagged.removeAttribute(QuoinAttribute.embedSourceStart, range: range)
                }
            }
        }
        return tagged
    }

    private func renderHeading(level: Int, inlines: [Inline]) -> NSAttributedString {
        var attributes = bodyAttributes()
        attributes[.font] = theme.headingFont(level: level)
        // H1–H3 in full ink; H4–H6 at 55% per the element spec.
        attributes[.foregroundColor] = level <= 3 ? theme.ink : theme.secondaryTextColor
        let style = paragraphStyle()
        let spacing = theme.headingSpacing(level: level)
        style.lineHeightMultiple = theme.headingLineHeightMultiple(level: level)
        style.paragraphSpacingBefore = spacing.above
        style.paragraphSpacing = spacing.below
        attributes[.paragraphStyle] = style
        return renderInlines(inlines, base: attributes)
    }

    private func renderCodeBlock(language: String?, code: String) -> NSAttributedString {
        // Code canvas is #1E2430 in BOTH appearances (handoff rule). The
        // canvas itself is a block decoration drawn by the reader view; the
        // text carries a header row (language chip + copy button) and the
        // highlighted code, single-spaced.
        let output = NSMutableAttributedString()

        let headerStyle = paragraphStyle()
        headerStyle.alignment = .right
        headerStyle.paragraphSpacingBefore = 8
        headerStyle.paragraphSpacing = 2
        headerStyle.firstLineHeadIndent = 12
        headerStyle.headIndent = 12
        headerStyle.tailIndent = -12
        var chip = bodyAttributes()
        chip[.font] = theme.captionFont()
        chip[.foregroundColor] = PlatformColor.white.withAlphaComponent(0.45)
        chip[.paragraphStyle] = headerStyle
        if let language, !language.isEmpty {
            output.append(NSAttributedString(string: "\(language)    ", attributes: chip))
        }
        var copy = chip
        copy[QuoinAttribute.copySource] = code
        if let url = QuoinLink.copyURL {
            copy[.link] = url
        }
        output.append(NSAttributedString(string: "⧉ copy\n", attributes: copy))

        var attributes = bodyAttributes()
        attributes[.font] = theme.codeBlockFont()
        attributes[.foregroundColor] = theme.codeText
        let style = paragraphStyle()
        style.lineHeightMultiple = 1.6
        style.firstLineHeadIndent = 12
        style.headIndent = 12
        style.tailIndent = -12
        // One visual block: code lines are paragraphs but must not inherit
        // the body's inter-paragraph gap.
        style.paragraphSpacing = 0
        style.paragraphSpacingBefore = 0
        attributes[.paragraphStyle] = style
        let body = NSMutableAttributedString(string: code, attributes: attributes)

        // Native syntax highlighting: six token colors per the design spec.
        // Character indices align with UTF-16 only for BMP text, so map each
        // character offset to its UTF-16 offset. Prefix sums make every token's
        // range O(1) instead of re-summing the string prefix per token.
        let chars = Array(code)
        var utf16Offsets = [Int](repeating: 0, count: chars.count + 1)
        for i in 0..<chars.count { utf16Offsets[i + 1] = utf16Offsets[i] + String(chars[i]).utf16.count }
        for token in SyntaxHighlighter.highlight(code: code, language: language) {
            let lower = token.range.lowerBound
            let upper = min(token.range.upperBound, chars.count)
            let nsRange = NSRange(location: utf16Offsets[lower], length: utf16Offsets[upper] - utf16Offsets[lower])
            guard nsRange.location + nsRange.length <= body.length else { continue }
            body.addAttribute(.foregroundColor, value: codeTokenColor(token.kind), range: nsRange)
        }

        // Bottom padding inside the canvas: the last code paragraph carries it.
        padLastLine(in: body, spacing: 8)
        // Marker: this run is the code body, 1:1 with the block's source
        // content. render(block:) resolves it to the real source offset so a
        // click can land the caret precisely when the block flips to source.
        body.addAttribute(QuoinAttribute.embedSourceStart, value: NSNumber(value: -1),
                          range: NSRange(location: 0, length: body.length))
        output.append(body)

        output.addAttribute(
            QuoinAttribute.blockDecoration,
            value: BlockDecoration(kind: .codeCanvas(fill: theme.codeSurface)),
            range: NSRange(location: 0, length: output.length)
        )
        return output
    }

    private func renderFrontMatter(yaml: String) -> NSAttributedString {
        // Compact metadata chip above the H1 (spec): the fields collapse to
        // one truncated caption line; clicking the block reveals the full
        // YAML source for editing (block activation).
        let condensed = yaml
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: "   ·   ")
        var attributes = bodyAttributes()
        attributes[.font] = theme.captionFont()
        attributes[.foregroundColor] = theme.secondaryTextColor
        let style = paragraphStyle()
        style.lineHeightMultiple = 1.4
        style.lineBreakMode = .byTruncatingTail
        style.paragraphSpacing = 4
        style.paragraphSpacingBefore = 2
        style.firstLineHeadIndent = 8
        style.headIndent = 8
        style.tailIndent = -8
        attributes[.paragraphStyle] = style
        attributes[QuoinAttribute.blockDecoration] = BlockDecoration(kind: .chip(fill: theme.inlineCodeFill))
        return NSAttributedString(string: condensed, attributes: attributes)
    }

    private func renderCallout(kind: CalloutKind, children: [Block], depth: Int, document: QuoinDocument) -> NSAttributedString {
        let semantic: PlatformColor
        let symbol: String
        switch kind {
        case .note: semantic = .systemBlue; symbol = "ℹ︎"
        case .tip: semantic = .systemGreen; symbol = "✓"
        case .important: semantic = .systemPurple; symbol = "❯"
        case .warning: semantic = .systemOrange; symbol = "⚠︎"
        case .caution, .danger: semantic = .systemRed; symbol = "✕"
        }

        let output = NSMutableAttributedString()
        var title = bodyAttributes()
        title[.font] = PlatformFont.systemFont(ofSize: 12.5, weight: .semibold)
        title[.foregroundColor] = semantic
        let titleStyle = paragraphStyle()
        titleStyle.paragraphSpacingBefore = 8
        titleStyle.paragraphSpacing = 4
        title[.paragraphStyle] = titleStyle
        output.append(NSAttributedString(string: "\(symbol) \(kind.title)\n", attributes: title))

        for (index, child) in children.enumerated() {
            if index > 0 {
                output.append(NSAttributedString(string: "\n", attributes: bodyAttributes()))
            }
            output.append(render(block: child, depth: depth + 1, document: document))
        }
        let full = NSRange(location: 0, length: output.length)
        output.enumerateAttribute(.paragraphStyle, in: full) { value, range, _ in
            let style = (value as? NSParagraphStyle)?.mutableCopy() as? NSMutableParagraphStyle ?? paragraphStyle()
            style.firstLineHeadIndent += 12
            style.headIndent += 12
            style.tailIndent = -12
            output.addAttribute(.paragraphStyle, value: style, range: range)
        }
        // Bottom padding inside the box: the last paragraph carries it.
        padLastLine(in: output, spacing: 8)
        // Rounded 4% tint + 15% border in the semantic color, drawn as a
        // block decoration by the reader view.
        output.addAttribute(
            QuoinAttribute.blockDecoration,
            value: BlockDecoration(kind: .callout(color: semantic)),
            range: full
        )
        return output
    }

    private func renderTOC(outline: [HeadingInfo]) -> NSAttributedString {
        let output = NSMutableAttributedString()
        for (index, heading) in outline.enumerated() {
            var attributes = bodyAttributes()
            attributes[.foregroundColor] = theme.linkColor
            attributes[.link] = QuoinLink.anchorURL(slug: heading.slug) as Any
            let style = paragraphStyle()
            style.paragraphSpacing = 2
            style.firstLineHeadIndent = CGFloat(max(0, heading.level - 1)) * 16
            style.headIndent = style.firstLineHeadIndent
            attributes[.paragraphStyle] = style
            output.append(NSAttributedString(
                string: heading.title + (index < outline.count - 1 ? "\n" : ""),
                attributes: attributes
            ))
        }
        return output
    }

    private func renderMermaidFallback(source: String) -> NSAttributedString {
        // Native rendering via MermaidKit; unparseable sources keep the
        // styled-source fallback.
        if let native = MermaidRenderer.attachmentString(source: source, theme: theme.diagramTheme) {
            let output = NSMutableAttributedString(attributedString: native)
            let style = paragraphStyle()
            style.paragraphSpacingBefore = theme.paragraphSpacing
            style.paragraphSpacing = theme.paragraphSpacing
            output.addAttributes([
                .paragraphStyle: style,
                QuoinAttribute.diagramSource: source,
                QuoinAttribute.blockDecoration: BlockDecoration(kind: .diagramFrame(color: theme.hairline)),
            ], range: NSRange(location: 0, length: output.length))
            return output
        }

        return renderSourceCard(
            language: "mermaid", code: source,
            sourceKey: QuoinAttribute.diagramSource, source: source,
            caption: "mermaid · this diagram type isn't natively rendered yet"
        )
    }

    private func renderMathBlockFallback(latex: String) -> NSAttributedString {
        // Display math: natively typeset, centered, 16pt above/below per the
        // element spec. Unsupported LaTeX keeps the styled-source fallback.
        if let native = MathImageRenderer.attachmentString(
            latex: latex, display: true, theme: theme, baseSize: theme.bodySize
        ) {
            let output = NSMutableAttributedString(attributedString: native)
            let style = paragraphStyle()
            style.alignment = .center
            style.paragraphSpacingBefore = 16
            style.paragraphSpacing = 16
            output.addAttributes([
                .paragraphStyle: style,
                QuoinAttribute.mathSource: latex,
            ], range: NSRange(location: 0, length: output.length))
            return output
        }

        // Unsupported LaTeX: the same tidy source-card treatment as an
        // unrenderable mermaid diagram — a dark canvas with a caption — so
        // degradation reads as intentional, never as a broken half-render.
        return renderSourceCard(
            language: "latex", code: latex,
            sourceKey: QuoinAttribute.mathSource, source: latex,
            caption: "math · this LaTeX isn't natively typeset yet"
        )
    }

    /// The shared fallback for content we can't render natively (an
    /// unsupported mermaid dialect or LaTeX): a code canvas of the raw source
    /// tagged with its `sourceKey`, plus a muted caption explaining the
    /// degradation. The tag covers only the card, not the caption — matching
    /// how the native paths tag their runs — so a later engine can find and
    /// replace exactly the source region.
    private func renderSourceCard(
        language: String,
        code: String,
        sourceKey: NSAttributedString.Key,
        source: String,
        caption: String
    ) -> NSAttributedString {
        let output = NSMutableAttributedString(attributedString: renderCodeBlock(language: language, code: code))
        output.addAttribute(sourceKey, value: source, range: NSRange(location: 0, length: output.length))
        var captionAttributes = bodyAttributes()
        captionAttributes[.font] = theme.captionFont()
        captionAttributes[.foregroundColor] = theme.secondaryTextColor
        output.append(NSAttributedString(string: "\n" + caption, attributes: captionAttributes))
        return output
    }

    private func renderTable(header: [TableCell], rows: [[TableCell]], alignments: [TableAlignment]) -> NSAttributedString {
        // M1 table rendering: measured tab stops. The column geometry (widths,
        // alignment inference, tab stops) is a pure computation over the cells
        // — extracted into TableLayout — leaving this method to emit the rows.
        let bodyFont = theme.bodyFont()
        let headerFont = boldVariant(of: bodyFont)
        let columnGap: CGFloat = 24
        guard let layout = TableLayout.compute(
            header: header, rows: rows, alignments: alignments,
            bodyFont: bodyFont, headerFont: headerFont,
            columnGap: columnGap, maxColumnWidth: theme.maxContentWidth / 2,
            measure: { text, font in (text as NSString).size(withAttributes: [.font: font]).width }
        ) else { return NSAttributedString() }

        let style = paragraphStyle()
        style.tabStops = layout.tabStops
        style.defaultTabInterval = columnGap
        style.lineHeightMultiple = 1.2
        style.paragraphSpacing = 5
        style.paragraphSpacingBefore = 3

        func renderRow(_ cells: [TableCell], font: PlatformFont, color: PlatformColor) -> NSAttributedString {
            let row = NSMutableAttributedString()
            var attributes = bodyAttributes()
            attributes[.font] = font
            attributes[.foregroundColor] = color
            attributes[.paragraphStyle] = style
            for (i, cell) in cells.enumerated() {
                var cellAttributes = attributes
                if layout.isNumeric[min(i, layout.columnCount - 1)] {
                    cellAttributes[.font] = PlatformFont.monospacedDigitSystemFont(
                        ofSize: font.pointSize,
                        weight: font == headerFont ? .semibold : .regular
                    )
                }
                row.append(renderInlines(cell.inlines, base: cellAttributes))
                if i < cells.count - 1 {
                    row.append(NSAttributedString(string: "\t", attributes: attributes))
                }
            }
            return row
        }

        let output = NSMutableAttributedString()
        output.append(renderRow(header, font: headerFont, color: theme.textColor))
        for row in rows {
            output.append(NSAttributedString(string: "\n", attributes: bodyAttributes()))
            output.append(renderRow(row, font: bodyFont, color: theme.textColor))
        }
        // Header 1.5pt rule + body hairlines, drawn by the reader view.
        output.addAttribute(
            QuoinAttribute.blockDecoration,
            value: BlockDecoration(kind: .tableRules(
                width: layout.totalWidth,
                header: theme.quoteRule,
                body: theme.tableRule
            )),
            range: NSRange(location: 0, length: output.length)
        )
        return output
    }

    private func renderList(items: [QuoinCore.ListItem], ordered: Bool, start: Int, depth: Int, document: QuoinDocument) -> NSAttributedString {
        let output = NSMutableAttributedString()
        for (index, item) in items.enumerated() {
            if index > 0 {
                output.append(NSAttributedString(string: "\n", attributes: bodyAttributes()))
            }
            output.append(renderListItem(item, ordinal: ordered ? start + index : nil, depth: depth, document: document))
        }
        return output
    }

    private func renderListItem(_ item: QuoinCore.ListItem, ordinal: Int?, depth: Int, document: QuoinDocument) -> NSAttributedString {
        let indent = CGFloat(depth + 1) * 22
        let style = paragraphStyle()
        style.firstLineHeadIndent = indent - 22
        style.headIndent = indent
        style.paragraphSpacing = theme.paragraphSpacing * 0.35

        var markerAttributes = bodyAttributes()
        markerAttributes[.paragraphStyle] = style

        let output = NSMutableAttributedString()

        // The marker: checkbox, ordinal, or bullet.
        if let task = item.task {
            var checkbox = markerAttributes
            checkbox[.foregroundColor] = theme.linkColor
            if let offset = item.taskMarkerRange?.offset, let url = QuoinLink.taskURL(markerOffset: offset) {
                checkbox[.link] = url
                checkbox[QuoinAttribute.taskMarkerOffset] = NSNumber(value: offset)
            }
            let glyph = task == .checked ? "☑" : "☐"
            output.append(NSAttributedString(string: glyph + "  ", attributes: checkbox))
        } else if let ordinal {
            output.append(NSAttributedString(string: "\(ordinal).  ", attributes: markerAttributes))
        } else {
            output.append(NSAttributedString(string: "•  ", attributes: markerAttributes))
        }

        // Item content: first paragraph flows inline after the marker, any
        // further blocks (nested lists, paragraphs) follow on their own lines.
        for (blockIndex, block) in item.blocks.enumerated() {
            if blockIndex > 0 {
                output.append(NSAttributedString(string: "\n", attributes: markerAttributes))
            }
            switch block.kind {
            case .paragraph(let inlines):
                var attributes = bodyAttributes()
                attributes[.paragraphStyle] = style
                if item.task == .checked {
                    // Done rows strike and fade to 40% per the element spec.
                    attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
                    attributes[.foregroundColor] = theme.ink.withAlphaComponent(0.4)
                    attributes[.strikethroughColor] = theme.ink.withAlphaComponent(0.4)
                }
                output.append(renderInlines(inlines, base: attributes))
            case .list(let nested, let nestedOrdered, let nestedStart):
                output.append(renderList(items: nested, ordered: nestedOrdered, start: nestedStart, depth: depth + 1, document: document))
            default:
                output.append(render(block: block, depth: depth + 1, document: document))
            }
        }
        return output
    }

    private func renderBlockQuote(children: [Block], depth: Int, document: QuoinDocument) -> NSAttributedString {
        let output = NSMutableAttributedString()
        for (index, child) in children.enumerated() {
            if index > 0 {
                output.append(NSAttributedString(string: "\n", attributes: bodyAttributes()))
            }
            output.append(render(block: child, depth: depth + 1, document: document))
        }
        let full = NSRange(location: 0, length: output.length)

        // A nested card (code block, diagram, table, callout) already carries
        // its own blockDecoration and styling. The quote's italic / recolor /
        // indent passes and its full-range quote-rule overwrite must skip those
        // ranges, or the child loses its canvas and renders as bare, italicised,
        // muted monospace. Collect the card ranges, then style only the gaps.
        var cardRanges: [NSRange] = []
        output.enumerateAttribute(QuoinAttribute.blockDecoration, in: full) { value, range, _ in
            if value != nil { cardRanges.append(range) }
        }
        func intersectsCard(_ range: NSRange) -> Bool {
            cardRanges.contains { NSIntersectionRange($0, range).length > 0 }
        }
        // Text runs are the parts of `full` not covered by any card.
        var textRuns: [NSRange] = []
        var cursor = 0
        for card in cardRanges.sorted(by: { $0.location < $1.location }) {
            if card.location > cursor {
                textRuns.append(NSRange(location: cursor, length: card.location - cursor))
            }
            cursor = max(cursor, NSMaxRange(card))
        }
        if cursor < full.length {
            textRuns.append(NSRange(location: cursor, length: full.length - cursor))
        }

        output.enumerateAttribute(.paragraphStyle, in: full) { value, range, _ in
            guard !intersectsCard(range) else { return }
            let style = (value as? NSParagraphStyle)?.mutableCopy() as? NSMutableParagraphStyle ?? paragraphStyle()
            style.firstLineHeadIndent += 16
            style.headIndent += 16
            output.addAttribute(.paragraphStyle, value: style, range: range)
        }
        // Element spec: pad-left 16, italic, 55% ink, 3pt rule at the left
        // edge (drawn as a block decoration by the reader view).
        output.enumerateAttribute(.font, in: full) { value, range, _ in
            guard !intersectsCard(range) else { return }
            // Inline code carries its own monospace font + fill; italicising it
            // shifts the baseline off the surrounding quote text. Leave it be.
            if output.attribute(.backgroundColor, at: range.location, effectiveRange: nil) != nil { return }
            let font = value as? PlatformFont ?? theme.bodyFont()
            output.addAttribute(.font, value: italicVariant(of: font), range: range)
        }
        for run in textRuns {
            output.addAttribute(.foregroundColor, value: theme.secondaryTextColor, range: run)
            output.addAttribute(
                QuoinAttribute.blockDecoration,
                value: BlockDecoration(kind: .quoteRule(color: theme.quoteRule)),
                range: run
            )
        }
        return output
    }

    private func renderThematicBreak() -> NSAttributedString {
        // 1px hairline @12% ink, 20 above/below. Drawn as a line of box
        // glyphs until the block decoration pass draws a true rule.
        var attributes = bodyAttributes()
        attributes[.foregroundColor] = theme.hairline
        attributes[.font] = PlatformFont.systemFont(ofSize: 8)
        let style = paragraphStyle()
        style.alignment = .center
        style.paragraphSpacingBefore = 20
        style.paragraphSpacing = 20
        attributes[.paragraphStyle] = style
        return NSAttributedString(string: String(repeating: "─", count: 60), attributes: attributes)
    }

    // MARK: - Inlines

    private func renderInlines(_ inlines: [Inline], base: [NSAttributedString.Key: Any]) -> NSAttributedString {
        let output = NSMutableAttributedString()
        for inline in inlines {
            output.append(renderInline(inline, attributes: base))
        }
        return output
    }

    private func renderInline(_ inline: Inline, attributes: [NSAttributedString.Key: Any]) -> NSAttributedString {
        switch inline {
        case .text(let text):
            return NSAttributedString(string: text, attributes: attributes)

        case .code(let code):
            var attrs = attributes
            attrs[.font] = theme.inlineCodeFont()
            attrs[.backgroundColor] = theme.inlineCodeFill
            return NSAttributedString(string: code, attributes: attrs)

        case .emphasis(let children):
            var attrs = attributes
            attrs[.font] = italicVariant(of: attrs[.font] as? PlatformFont ?? theme.bodyFont())
            return renderInlines(children, base: attrs)

        case .strong(let children):
            // Bold text is full ink (#1D1D1F) per the element spec.
            var attrs = attributes
            attrs[.font] = boldVariant(of: attrs[.font] as? PlatformFont ?? theme.bodyFont())
            attrs[.foregroundColor] = theme.ink
            return renderInlines(children, base: attrs)

        case .strikethrough(let children):
            // 45% ink per the element spec.
            var attrs = attributes
            attrs[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
            attrs[.foregroundColor] = theme.ink.withAlphaComponent(0.45)
            return renderInlines(children, base: attrs)

        case .link(let destination, let children):
            // Accent text with a 35%-alpha accent underline.
            var attrs = attributes
            attrs[.foregroundColor] = theme.linkColor
            attrs[.underlineStyle] = NSUnderlineStyle.single.rawValue
            attrs[.underlineColor] = theme.linkColor.withAlphaComponent(0.35)
            if let destination {
                if destination.hasPrefix("#") {
                    attrs[.link] = QuoinLink.anchorURL(slug: String(destination.dropFirst())) as Any
                } else if let url = URL(string: destination) {
                    attrs[.link] = url
                }
            }
            return renderInlines(children, base: attrs)

        case .image(let source, let alt):
            return renderImage(source: source, alt: alt, attributes: attributes)

        case .math(let latex):
            // Natively typeset inline math, baseline-aligned with the text;
            // unsupported LaTeX degrades to marked styled source (PRD rule).
            if let native = MathImageRenderer.attachmentString(
                latex: latex, display: false, theme: theme, baseSize: theme.bodySize
            ) {
                let output = NSMutableAttributedString(attributedString: native)
                var carried = attributes
                carried[QuoinAttribute.mathSource] = latex
                carried.removeValue(forKey: .font)
                output.addAttributes(carried, range: NSRange(location: 0, length: output.length))
                return output
            }
            var attrs = attributes
            attrs[.font] = theme.inlineCodeFont()
            attrs[.foregroundColor] = theme.secondaryTextColor
            attrs[QuoinAttribute.mathSource] = latex
            return NSAttributedString(string: latex, attributes: attrs)

        case .highlight(let children, let color):
            // Pill highlight in the span's palette color (⇧⌘H cycles it).
            var attrs = attributes
            attrs[.backgroundColor] = (Theme.Highlight(rawValue: color.rawValue) ?? .lime).color
            attrs[.foregroundColor] = theme.textColor
            return renderInlines(children, base: attrs)

        case .footnoteReference(_, let index):
            // Superscript accent marker; bidirectional jump lands in Phase C.
            var attrs = attributes
            attrs[.font] = PlatformFont.systemFont(ofSize: theme.bodySize * 0.75)
            attrs[.foregroundColor] = theme.accent
            attrs[.baselineOffset] = theme.bodySize * 0.33
            return NSAttributedString(string: "\(index)", attributes: attrs)

        case .softBreak:
            return NSAttributedString(string: " ", attributes: attributes)

        case .lineBreak:
            return NSAttributedString(string: "\n", attributes: attributes)

        case .html(let raw):
            var attrs = attributes
            attrs[.font] = theme.inlineCodeFont()
            attrs[.foregroundColor] = theme.secondaryTextColor
            return NSAttributedString(string: raw, attributes: attrs)
        }
    }

    // MARK: - Images

    private func renderImage(source: String?, alt: String, attributes: [NSAttributedString.Key: Any]) -> NSAttributedString {
        func placeholder(_ label: String) -> NSAttributedString {
            var attrs = attributes
            attrs[.font] = theme.inlineCodeFont()
            attrs[.foregroundColor] = theme.secondaryTextColor
            attrs[.backgroundColor] = theme.inlineCodeFill
            return NSAttributedString(string: " ▢ \(label) ", attributes: attrs)
        }

        guard let source, !source.isEmpty else { return placeholder(alt.isEmpty ? "image" : alt) }

        if source.hasPrefix("http://") || source.hasPrefix("https://") {
            // Local-only policy: remote images are placeholders unless the
            // user opts in for this document (opt-in fetch arrives with the
            // async image pipeline in M2a).
            return placeholder("remote image: \(source)")
        }

        let fileURL: URL
        if source.hasPrefix("/") {
            fileURL = URL(fileURLWithPath: source)
        } else if let baseURL {
            fileURL = baseURL.appendingPathComponent(source).standardizedFileURL
        } else {
            return placeholder(alt.isEmpty ? source : alt)
        }

        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return placeholder("missing image: \(source)")
        }
        // Async decode: first render shows a quiet placeholder; the decoded
        // image arrives via onContentReady → re-render. The pending flag keeps
        // this placeholder fragment out of the block cache so that re-render
        // actually rebuilds it (a cached placeholder would stick forever).
        guard let image = AsyncImageStore.shared.image(
            at: fileURL,
            maxDimension: theme.maxContentWidth * 2,
            onReady: onContentReady ?? {}
        ) else {
            let marked = NSMutableAttributedString(
                attributedString: placeholder(alt.isEmpty ? "loading image…" : alt)
            )
            marked.addAttribute(QuoinAttribute.pendingContent, value: NSNumber(value: true),
                                range: NSRange(location: 0, length: marked.length))
            return marked
        }

        let attachment = NSTextAttachment()
        let scale = min(1, theme.maxContentWidth / max(image.size.width, 1))
        attachment.image = image
        attachment.bounds = CGRect(
            x: 0, y: 0,
            width: image.size.width * scale,
            height: image.size.height * scale
        )
        let output = NSMutableAttributedString(attachment: attachment)
        output.addAttributes(attributes, range: NSRange(location: 0, length: output.length))
        return output
    }


    // MARK: - Attribute helpers

    /// True when a rendered fragment contains an async placeholder still
    /// waiting on content (a decoding image tagged `pendingContent`). Such
    /// fragments are dropped from the cache so the decoded image rebuilds.
    private func fragmentHasPendingContent(_ fragment: NSAttributedString) -> Bool {
        var pending = false
        fragment.enumerateAttribute(
            QuoinAttribute.pendingContent,
            in: NSRange(location: 0, length: fragment.length)
        ) { value, _, stop in
            if value != nil { pending = true; stop.pointee = true }
        }
        return pending
    }

    private func bodyAttributes() -> [NSAttributedString.Key: Any] {
        [
            .font: theme.bodyFont(),
            .foregroundColor: theme.textColor,
            .paragraphStyle: paragraphStyle(),
        ]
    }

    /// Maps a highlighter token kind to its Graphite code color.
    private func codeTokenColor(_ kind: SyntaxTokenKind) -> PlatformColor {
        switch kind {
        case .keyword: return Theme.CodeToken.keyword
        case .function: return Theme.CodeToken.function
        case .type: return Theme.CodeToken.type
        case .comment: return Theme.CodeToken.comment
        case .string: return Theme.CodeToken.string
        case .number: return Theme.CodeToken.number
        }
    }

    private func paragraphStyle() -> NSMutableParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.lineHeightMultiple = theme.bodyLineHeightMultiple
        style.paragraphSpacing = theme.paragraphSpacing
        return style
    }

    /// Adds bottom padding inside a boxed block (code canvas, callout box) by
    /// widening the last line's `paragraphSpacing`. Reads the last line's
    /// effective paragraph style so it preserves the caller's line metrics and
    /// indents; a no-op on an empty string or a line without a paragraph style.
    private func padLastLine(in output: NSMutableAttributedString, spacing: CGFloat) {
        let text = output.string as NSString
        guard text.length > 0 else { return }
        let lastLine = text.lineRange(for: NSRange(location: text.length - 1, length: 0))
        guard let style = (output.attribute(.paragraphStyle, at: lastLine.location, effectiveRange: nil)
            as? NSParagraphStyle)?.mutableCopy() as? NSMutableParagraphStyle else { return }
        style.paragraphSpacing = spacing
        output.addAttribute(.paragraphStyle, value: style, range: lastLine)
    }

    private func boldVariant(of font: PlatformFont) -> PlatformFont {
        #if canImport(AppKit)
        return NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask)
        #else
        guard let descriptor = font.fontDescriptor.withSymbolicTraits(
            font.fontDescriptor.symbolicTraits.union(.traitBold)
        ) else { return font }
        return UIFont(descriptor: descriptor, size: font.pointSize)
        #endif
    }

    private func italicVariant(of font: PlatformFont) -> PlatformFont {
        #if canImport(AppKit)
        return NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask)
        #else
        guard let descriptor = font.fontDescriptor.withSymbolicTraits(
            font.fontDescriptor.symbolicTraits.union(.traitItalic)
        ) else { return font }
        return UIFont(descriptor: descriptor, size: font.pointSize)
        #endif
    }
}

#if canImport(AppKit)
public typealias PlatformImage = NSImage
#else
public typealias PlatformImage = UIImage
#endif
#endif
