#if canImport(AppKit)
import AppKit
import QuoinCore

// MARK: - Decorated text view

/// `NSTextView` subclass that draws block decorations — code canvases,
/// callout boxes, quote rules, diagram frames, chips, table rules — behind
/// the text. The renderer tags block ranges with `QuoinAttribute
/// .blockDecoration`; geometry comes from the laid-out fragment frames, so
/// the shapes track reflow exactly.
final class QuoinTextView: NSTextView {

    /// Internal for tests (the incremental-maintenance equivalence check).
    var decorationRuns: [(range: NSRange, decoration: BlockDecoration)] = []
    private var runsAreStale = true

    /// Set by the coordinator: a double-click landed on the character at
    /// this index. Returns true when it consumed the gesture (an embed flip)
    /// — the event must NOT fall through to super then: AppKit's word-select
    /// tracking would run while the flip replaces the text underneath it,
    /// and its indexes would resolve into the newly revealed source as a
    /// random selection ("double clicking selects random portions of the
    /// mermaid source").
    var onDoubleClick: ((Int) -> Bool)?

    /// The drawn `✓ done` chip's frame (view coordinates), recorded by the
    /// editingFrame decoration pass each draw; nil when no block is open.
    /// The chip is decoration ink, not a text run (the revealed source is
    /// 1:1 with the file), so clicks are hit-tested here, before AppKit's
    /// caret placement can see them — and its tooltip is a view tooltip
    /// rect, re-registered whenever the drawn frame moves.
    private(set) var doneChipRect: CGRect? {
        didSet {
            guard doneChipRect != oldValue else { return }
            if let tag = doneChipToolTipTag {
                removeToolTip(tag)
                doneChipToolTipTag = nil
            }
            if let rect = doneChipRect {
                doneChipToolTipTag = addToolTip(
                    rect.insetBy(dx: -8, dy: -7), owner: Self.doneChipToolTipText, userData: nil)
            }
        }
    }
    private var doneChipToolTipTag: NSView.ToolTipTag?
    // addToolTip does not retain its owner; keep the string alive.
    private static let doneChipToolTipText = "Done Editing (⌘↩ or esc)" as NSString
    /// Single click on the ✓ done chip: commit and close the open block.
    var onDoneChipClick: (() -> Void)?

    /// Right-click: lets the coordinator prepend block-aware items
    /// (Edit Source / Copy Markdown Source) to the standard text menu.
    var onContextMenu: ((Int, NSMenu) -> Void)?

    /// Smart paste (idea #4): the coordinator turns URLs-over-selection
    /// into links and tabular text into tables; returning false falls
    /// through to the ordinary paste pipeline.
    var onSmartPaste: (() -> Bool)?

    override func paste(_ sender: Any?) {
        if onSmartPaste?() == true { return }
        super.paste(sender)
    }

    /// Link hover (idea #8): reports the URL under the pointer (nil when
    /// the pointer leaves links) so the coordinator can peek internal
    /// anchor targets. Throttled by character index.
    var onLinkHover: ((URL?, NSRect) -> Void)?
    private var hoverTracking: NSTrackingArea?
    private var lastHoverIndex = -1

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverTracking {
            removeTrackingArea(hoverTracking)
            self.hoverTracking = nil
        }
        guard onLinkHover != nil else { return }
        let area = NSTrackingArea(
            rect: .zero,
            options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self, userInfo: nil)
        addTrackingArea(area)
        hoverTracking = area
    }

    override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        guard let onLinkHover else { return }
        let point = convert(event.locationInWindow, from: nil)
        let index = characterIndexForInsertion(at: point)
        guard index != lastHoverIndex else { return }
        lastHoverIndex = index
        guard index >= 0,
              let storage = textContentStorage?.textStorage,
              index < storage.length,
              let url = storage.attribute(.link, at: index, effectiveRange: nil) as? URL
        else {
            onLinkHover(nil, .zero)
            return
        }
        onLinkHover(url, NSRect(x: point.x - 2, y: point.y - 2, width: 4, height: 4))
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        lastHoverIndex = -1
        onLinkHover?(nil, .zero)
    }

    /// The drawn editing frame's box (text-view coordinates), reported
    /// when it CHANGES — nil when no block is open. The side-by-side
    /// preview panel positions itself against it. Deduped (ledger perf
    /// #10): every drawBackground pass used to fire an async dispatch;
    /// now one fires only when the rect actually differs from the last
    /// report. Panel-content changes with an unchanged frame are covered
    /// by the coordinator's projection-change refresh.
    var onEditingFrameGeometry: ((CGRect?) -> Void)?
    /// Outer nil = nothing reported yet; `.some(nil)` = reported "no
    /// open block".
    private var lastReportedEditingFrame: CGRect??

    private func reportEditingFrameGeometry(_ rect: CGRect?) {
        guard onEditingFrameGeometry != nil, lastReportedEditingFrame != .some(rect) else { return }
        lastReportedEditingFrame = .some(rect)
        // Mutating the view hierarchy mid-draw is illegal — next turn.
        DispatchQueue.main.async { [weak self] in
            self?.onEditingFrameGeometry?(rect)
        }
    }

    /// Ambient paused status: while the live preview is paused (admitted),
    /// the editing frame's stroke turns this color instead of the accent.
    /// Set by the coordinator; changes as a cut, never a fade.
    var editingFrameTintOverride: NSColor?

    override func menu(for event: NSEvent) -> NSMenu? {
        guard let menu = super.menu(for: event) else { return nil }
        let point = convert(event.locationInWindow, from: nil)
        let index = characterIndexForInsertion(at: point)
        if index >= 0 {
            onContextMenu?(index, menu)
        }
        return menu
    }

    override func mouseDown(with event: NSEvent) {
        let clipBefore = enclosingScrollView?.contentView.bounds.origin.y ?? -1
        if event.clickCount == 1, let chip = doneChipRect {
            let point = convert(event.locationInWindow, from: nil)
            // ≥28pt effective hit target around the small caption.
            if chip.insetBy(dx: -8, dy: -7).contains(point) {
                onDoneChipClick?()
                return
            }
        }
        if event.clickCount == 2 {
            let point = convert(event.locationInWindow, from: nil)
            let index = characterIndexForInsertion(at: point)
            if index >= 0, onDoubleClick?(index) == true {
                // Embed flip: consume the event — no word-select tracking
                // over text that is about to be replaced.
                return
            }
            // Fall through to super so text blocks still get word-select.
        }
        super.mouseDown(with: event)
        let clipAfter = enclosingScrollView?.contentView.bounds.origin.y ?? -1
        QuoinPerformanceTrace.log(
            "click.mouseDown", startedAt: DispatchTime.now().uptimeNanoseconds,
            metadata: "clipBefore=\(Int(clipBefore)) clipAfter=\(Int(clipAfter)) moved=\(Int(clipAfter - clipBefore)) clicks=\(event.clickCount)")
    }

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

    /// Redraw with the CURRENT runs — for attribute-only restyles (syntax
    /// reveal flipping delimiter fonts as the caret moves): the run ranges
    /// are unchanged, only their geometry moved, and geometry is read fresh
    /// from the laid-out fragments at draw time. A full `invalidate` here
    /// re-enumerated the whole document's attributes on every caret move.
    func redrawDecorations() {
        needsDisplay = true
        DispatchQueue.main.async { [weak self] in
            self?.needsDisplay = true
        }
    }

    /// Incremental alternative to `invalidateDecorations()` for a bounded
    /// storage edit: drops runs the edit touched, shifts the rest by the
    /// length delta, and rescans ONLY the replaced range. A full rescan
    /// enumerates the whole document's attributes (~170 ms at novel length)
    /// — per keystroke, that was the render layer's last document-scale
    /// cost.
    func noteStorageEdit(oldRange: NSRange, newLength: Int) {
        guard !runsAreStale, let storage = textContentStorage?.textStorage else {
            invalidateDecorations()
            return
        }
        let delta = newLength - oldRange.length
        let oldEnd = NSMaxRange(oldRange)

        // Partition: untouched runs before / after the edit; runs overlapping
        // it widen the rescan window (a run can start before the patched
        // fragment — dropping it without rescanning its full extent would
        // orphan the prefix).
        var before: [(range: NSRange, decoration: BlockDecoration)] = []
        var after: [(range: NSRange, decoration: BlockDecoration)] = []
        var scanStart = oldRange.location
        var scanEndOld = oldEnd
        for run in decorationRuns {
            if NSMaxRange(run.range) <= oldRange.location {
                before.append(run)
            } else if run.range.location >= oldEnd {
                after.append((NSRange(location: run.range.location + delta,
                                      length: run.range.length), run.decoration))
            } else {
                scanStart = min(scanStart, run.range.location)
                scanEndOld = max(scanEndOld, NSMaxRange(run.range))
            }
        }

        var middle: [(range: NSRange, decoration: BlockDecoration)] = []
        let scanEnd = min(max(scanStart, scanEndOld + delta), storage.length)
        if scanStart >= 0, scanEnd > scanStart {
            storage.enumerateAttribute(
                QuoinAttribute.blockDecoration,
                in: NSRange(location: scanStart, length: scanEnd - scanStart)
            ) { value, range, _ in
                if let decoration = value as? BlockDecoration {
                    middle.append((range, decoration))
                }
            }
        }

        decorationRuns = before + middle + after
        needsDisplay = true
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

    func refreshRunsIfNeeded() {
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
        // No open block → no ✓ done target, no preview panel. Cleared from
        // the RUN list, not the dirty rect: a partial redraw that misses
        // the chip must not disable a chip that is still on screen.
        if !decorationRuns.contains(where: {
            if case .editingFrame = $0.decoration.kind { return true }
            return false
        }) {
            doneChipRect = nil
            reportEditingFrameGeometry(nil)
        }
        guard !decorationRuns.isEmpty,
              let layoutManager = textLayoutManager,
              let contentManager = layoutManager.textContentManager
        else { return }

        // Cull to the viewport BEFORE computing geometry: enumerating a
        // run's fragments with .ensuresLayout forces layout, so iterating
        // every decorated block in the document laid out the whole file on
        // each draw — TextKit 2's viewport laziness, defeated by its own
        // decorations. The character-range test is cheap and generous
        // (±4096 characters of slack around the viewport range).
        var visible: NSRange?
        if let viewport = layoutManager.textViewportLayoutController.viewportRange {
            let start = contentManager.offset(from: contentManager.documentRange.location,
                                              to: viewport.location)
            let end = contentManager.offset(from: contentManager.documentRange.location,
                                            to: viewport.endLocation)
            let slack = 4096
            let lower = max(0, start - slack)
            visible = NSRange(location: lower, length: end + slack - lower)
        }

        let origin = textContainerOrigin
        for run in decorationRuns {
            if let visible, NSIntersectionRange(run.range, visible).length == 0,
               run.range.length > 0 {
                continue
            }
            guard let textRange = nsTextRange(run.range, in: contentManager) else { continue }

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
                case .codeCanvas, .callout, .diagramFrame, .editingFrame:
                    // Full-width chrome starts at the card's own text
                    // column: nested cards (code in a quote, a diagram in
                    // a list item) carry the accumulated nesting inset —
                    // x = 0 made them break out of their container.
                    union.origin.x = run.decoration.leadingInset
                    union.size.width = container.size.width - run.decoration.leadingInset
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
            // Symmetric interior padding that clears the last line's
            // descenders; external separation between adjacent cards comes
            // from the widened block separator, not a one-sided bulge here.
            let rect = box.insetBy(dx: 0, dy: -5)
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
            // box.minX is the indented text's left edge; the rule sits in the
            // gutter to its left so glyphs never overlap the bar.
            let bar = CGRect(x: box.minX - 14, y: box.minY + 3, width: 3, height: box.height - 6)
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

        case .editingFrame(let accent):
            // The open block's mode chrome: 1.5pt frame with the drawn
            // ✓ done chip at its top-right (mode indicators are never
            // hover-gated). Drawn ink only — the revealed source under it
            // stays 1:1 with the file. The stroke turns amber while the
            // live preview is paused (ambient status at the locus's edge).
            let stroke = editingFrameTintOverride ?? accent
            let rect = box.insetBy(dx: -4, dy: -4)
            context.addPath(CGPath(
                roundedRect: rect.insetBy(dx: 0.75, dy: 0.75),
                cornerWidth: 8, cornerHeight: 8, transform: nil
            ))
            context.setStrokeColor(stroke.withAlphaComponent(0.8).cgColor)
            context.setLineWidth(1.5)
            context.strokePath()
            // ✓ done wears the same chip shape as its siblings (‹/› edit,
            // ⧉ copy): capsule fill, radius 6, 2×6 padding.
            let label = NSAttributedString(string: "✓ done", attributes: [
                .font: NSFont.systemFont(ofSize: 10.5, weight: .medium),
                .foregroundColor: accent,
            ])
            let size = label.size()
            let chip = CGRect(
                x: rect.maxX - size.width - 6 - 10,
                y: rect.minY + 5,
                width: size.width + 12,
                height: size.height + 4
            )
            context.addPath(CGPath(roundedRect: chip, cornerWidth: 6, cornerHeight: 6, transform: nil))
            context.setFillColor(accent.withAlphaComponent(0.12).cgColor)
            context.fillPath()
            label.draw(at: CGPoint(x: chip.minX + 6, y: chip.minY + 2))
            doneChipRect = chip
            // Side-by-side preview panel tracks this frame.
            reportEditingFrameGeometry(rect)

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

}
#endif
