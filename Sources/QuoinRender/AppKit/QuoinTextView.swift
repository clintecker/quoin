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

    /// Set by the coordinator: a double-click landed on the character at this
    /// index. The coordinator decides whether it's an embed block worth
    /// flipping to source.
    var onDoubleClick: ((Int) -> Void)?

    override func mouseDown(with event: NSEvent) {
        let clipBefore = enclosingScrollView?.contentView.bounds.origin.y ?? -1
        if event.clickCount == 2 {
            let point = convert(event.locationInWindow, from: nil)
            let index = characterIndexForInsertion(at: point)
            if index >= 0 { onDoubleClick?(index) }
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
