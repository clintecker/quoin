#if canImport(AppKit) || canImport(UIKit)
import Foundation
import CoreText
import CoreGraphics
import QuoinCore

#if canImport(AppKit)
import AppKit
#else
import UIKit
#endif

/// TeX-style box layout for `MathNode` trees, drawn with CoreText.
///
/// Every node lays out to a `MathBox` (width/ascent/descent + a draw
/// closure in y-up coordinates at a baseline pen position). Inter-atom
/// spacing follows TeX's thin/medium/thick rules from the atom classes the
/// parser preserved. All dimensions are in ems of the current size, so the
/// result scales with the reading theme.
struct MathTypesetter {

    let theme: Theme
    let baseSize: CGFloat

    init(theme: Theme, baseSize: CGFloat) {
        self.theme = theme
        self.baseSize = baseSize
    }

    // MARK: - Box model

    struct MathBox {
        var width: CGFloat
        var ascent: CGFloat
        var descent: CGFloat
        /// Draws at `pen` = baseline origin, y-up coordinates.
        var draw: (CGContext, CGPoint) -> Void

        var height: CGFloat { ascent + descent }

        static let empty = MathBox(width: 0, ascent: 0, descent: 0, draw: { _, _ in })
    }

    // MARK: - Entry

    /// Lays out a node at the given size; `display` enables display-style
    /// conventions (larger big operators).
    func layout(_ node: MathNode, size: CGFloat? = nil, display: Bool = false) -> MathBox {
        let s = size ?? baseSize
        switch node {
        case .symbol(let glyph, _, let style):
            return textBox(glyph, size: s, italic: style == .italic, bold: style == .bold)

        case .functionName(let name):
            return textBox(name, size: s, italic: false)

        case .space(let ems):
            return MathBox(width: CGFloat(ems) * s, ascent: 0, descent: 0, draw: { _, _ in })

        case .row(let children):
            return rowBox(children, size: s, display: display)

        case .fraction(let numerator, let denominator):
            return fractionBox(numerator, denominator, size: s, display: display)

        case .radical(let degree, let radicand):
            return radicalBox(degree, radicand, size: s, display: display)

        case .scripts(let base, let sub, let sup):
            return scriptsBox(base, sub: sub, sup: sup, size: s, display: display)

        case .delimited(let left, let body, let right):
            return delimitedBox(left, body, right, size: s, display: display)

        case .matrix(let rows, let left, let right, let style):
            return matrixBox(rows, left: left, right: right, style: style, size: s)

        case .unsupported(let source):
            // Never reached when callers gate on isFullySupported, but draw
            // something sane regardless.
            return textBox(source, size: s * 0.85, italic: false, monospaced: true)
        }
    }

    // MARK: - Text

    private func font(size: CGFloat, italic: Bool, bold: Bool = false, monospaced: Bool = false) -> CTFont {
        if monospaced {
            return PlatformFont.monospacedSystemFont(ofSize: size, weight: .regular) as CTFont
        }
        let base = bold ? PlatformFont.boldSystemFont(ofSize: size) : PlatformFont.systemFont(ofSize: size)
        if italic {
            #if canImport(AppKit)
            if let descriptor = base.fontDescriptor.withSymbolicTraits(.italic) as NSFontDescriptor?,
               let italicFont = NSFont(descriptor: descriptor, size: size) {
                return italicFont as CTFont
            }
            #else
            if let descriptor = base.fontDescriptor.withSymbolicTraits(.traitItalic) {
                return UIFont(descriptor: descriptor, size: size) as CTFont
            }
            #endif
        }
        return base as CTFont
    }

    private func textBox(_ text: String, size: CGFloat, italic: Bool, bold: Bool = false, monospaced: Bool = false) -> MathBox {
        let ctFont = font(size: size, italic: italic, bold: bold, monospaced: monospaced)
        let ink = theme.ink
        let attributed = NSAttributedString(string: text, attributes: [
            kCTFontAttributeName as NSAttributedString.Key: ctFont,
            kCTForegroundColorFromContextAttributeName as NSAttributedString.Key: true,
        ])
        let line = CTLineCreateWithAttributedString(attributed)
        var ascent: CGFloat = 0
        var descent: CGFloat = 0
        var leading: CGFloat = 0
        let width = CGFloat(CTLineGetTypographicBounds(line, &ascent, &descent, &leading))

        return MathBox(width: width, ascent: ascent, descent: descent) { context, pen in
            context.saveGState()
            context.setFillColor(resolvedCGColor(ink))
            context.textPosition = pen
            CTLineDraw(line, context)
            context.restoreGState()
        }
    }

    // MARK: - Rows with TeX spacing

    private func rowBox(_ children: [MathNode], size: CGFloat, display: Bool) -> MathBox {
        var boxes: [(box: MathBox, cls: MathAtomClass?)] = []
        for child in children {
            let box = layout(child, size: size, display: display)
            boxes.append((box, atomClass(of: child)))
        }

        var width: CGFloat = 0
        var ascent: CGFloat = 0
        var descent: CGFloat = 0
        var placements: [(MathBox, CGFloat)] = []
        var previous: MathAtomClass?

        for (box, cls) in boxes {
            if let previous, let cls {
                width += spacing(between: previous, and: cls) * size
            }
            placements.append((box, width))
            width += box.width
            ascent = max(ascent, box.ascent)
            descent = max(descent, box.descent)
            previous = cls ?? previous
        }

        return MathBox(width: width, ascent: ascent, descent: descent) { context, pen in
            for (box, x) in placements {
                box.draw(context, CGPoint(x: pen.x + x, y: pen.y))
            }
        }
    }

    private func atomClass(of node: MathNode) -> MathAtomClass? {
        switch node {
        case .symbol(_, let cls, _): return cls
        case .functionName: return .largeOperator
        case .fraction, .radical, .delimited, .row, .matrix: return .ordinary
        case .scripts(let base, _, _): return atomClass(of: base)
        case .space, .unsupported: return nil
        }
    }

    /// TeX inter-atom spacing (in ems): thin 3/18 · medium 4/18 · thick 5/18.
    private func spacing(between left: MathAtomClass, and right: MathAtomClass) -> CGFloat {
        let thin: CGFloat = 3.0 / 18.0
        let medium: CGFloat = 4.0 / 18.0
        let thick: CGFloat = 5.0 / 18.0

        switch (left, right) {
        case (.ordinary, .binary), (.binary, .ordinary),
             (.closing, .binary), (.binary, .opening),
             (.binary, .largeOperator), (.largeOperator, .binary):
            return medium
        case (.ordinary, .relation), (.relation, .ordinary),
             (.closing, .relation), (.relation, .opening),
             (.largeOperator, .relation), (.relation, .largeOperator):
            return thick
        case (.ordinary, .largeOperator), (.largeOperator, .ordinary),
             (.closing, .largeOperator), (.largeOperator, .opening):
            return thin
        case (.punctuation, _):
            return thin
        default:
            return 0
        }
    }

    // MARK: - Fractions

    private func fractionBox(_ numerator: MathNode, _ denominator: MathNode, size: CGFloat, display: Bool) -> MathBox {
        let partSize = size * (display ? 0.9 : 0.8)
        let top = layout(numerator, size: partSize, display: false)
        let bottom = layout(denominator, size: partSize, display: false)

        let ruleThickness = max(1, size * 0.045)
        let gap = size * 0.14
        let axis = size * 0.26 // math axis above baseline
        let width = max(top.width, bottom.width) + size * 0.24

        let ascent = axis + ruleThickness / 2 + gap + top.height
        let descent = -(axis - ruleThickness / 2 - gap - bottom.height)
        let ink = theme.ink

        return MathBox(width: width, ascent: ascent, descent: max(descent, bottom.height + gap - axis)) { context, pen in
            let ruleY = pen.y + axis
            context.saveGState()
            context.setFillColor(resolvedCGColor(ink))
            context.fill(CGRect(x: pen.x + size * 0.04, y: ruleY - ruleThickness / 2,
                                width: width - size * 0.08, height: ruleThickness))
            context.restoreGState()

            let topPen = CGPoint(
                x: pen.x + (width - top.width) / 2,
                y: ruleY + ruleThickness / 2 + gap + top.descent
            )
            top.draw(context, topPen)

            let bottomPen = CGPoint(
                x: pen.x + (width - bottom.width) / 2,
                y: ruleY - ruleThickness / 2 - gap - bottom.ascent
            )
            bottom.draw(context, bottomPen)
        }
    }

    // MARK: - Radicals

    private func radicalBox(_ degree: MathNode?, _ radicand: MathNode, size: CGFloat, display: Bool) -> MathBox {
        let body = layout(radicand, size: size, display: display)
        let ruleThickness = max(1, size * 0.045)
        let gap = size * 0.12
        let signWidth = size * 0.55
        let degreeBox = degree.map { layout($0, size: size * 0.6, display: false) }
        let degreeAdvance = degreeBox.map { max(0, $0.width - signWidth * 0.35) } ?? 0

        let ascent = body.ascent + gap + ruleThickness + size * 0.06
        let descent = body.descent
        let width = degreeAdvance + signWidth + body.width + size * 0.12
        let ink = theme.ink

        return MathBox(width: width, ascent: ascent, descent: descent) { context, pen in
            context.saveGState()
            context.setStrokeColor(resolvedCGColor(ink))
            context.setLineWidth(ruleThickness)
            context.setLineJoin(.miter)
            context.setLineCap(.round)

            let signX = pen.x + degreeAdvance
            let topY = pen.y + ascent - ruleThickness / 2
            let bottomY = pen.y - descent

            // The radical sign: tick, downstroke, upstroke, overline.
            context.beginPath()
            context.move(to: CGPoint(x: signX, y: pen.y + body.height * 0.25 - body.descent))
            context.addLine(to: CGPoint(x: signX + signWidth * 0.3, y: pen.y + body.height * 0.12 - body.descent))
            context.addLine(to: CGPoint(x: signX + signWidth * 0.55, y: bottomY))
            context.addLine(to: CGPoint(x: signX + signWidth, y: topY))
            context.addLine(to: CGPoint(x: signX + signWidth + body.width + size * 0.12, y: topY))
            context.strokePath()
            context.restoreGState()

            body.draw(context, CGPoint(x: signX + signWidth + size * 0.06, y: pen.y))

            if let degreeBox {
                degreeBox.draw(context, CGPoint(
                    x: pen.x,
                    y: pen.y + body.height * 0.45 - body.descent
                ))
            }
        }
    }

    // MARK: - Scripts

    private func scriptsBox(_ base: MathNode, sub: MathNode?, sup: MathNode?, size: CGFloat, display: Bool) -> MathBox {
        // Display style: big operators take their limits above and below
        // (∑ᵢ₌₁ⁿ style), like TeX's \limits.
        if display, case .symbol(_, .largeOperator, _) = base {
            return limitsBox(base, sub: sub, sup: sup, size: size)
        }
        let baseBox = layout(base, size: size, display: display)
        let scriptSize = size * 0.68
        let supBox = sup.map { layout($0, size: scriptSize, display: false) }
        let subBox = sub.map { layout($0, size: scriptSize, display: false) }

        let supRaise = size * 0.42
        let subDrop = size * 0.20
        let scriptsWidth = max(supBox?.width ?? 0, subBox?.width ?? 0)
        let width = baseBox.width + scriptsWidth + size * 0.03

        var ascent = baseBox.ascent
        var descent = baseBox.descent
        if let supBox { ascent = max(ascent, supRaise + supBox.ascent) }
        if let subBox { descent = max(descent, subDrop + subBox.descent) }

        return MathBox(width: width, ascent: ascent, descent: descent) { context, pen in
            baseBox.draw(context, pen)
            let scriptX = pen.x + baseBox.width + size * 0.03
            if let supBox {
                supBox.draw(context, CGPoint(x: scriptX, y: pen.y + supRaise))
            }
            if let subBox {
                subBox.draw(context, CGPoint(x: scriptX, y: pen.y - subDrop))
            }
        }
    }

    /// ∑/∫-style stacked limits: operator enlarged, superscript centered
    /// above, subscript centered below.
    private func limitsBox(_ base: MathNode, sub: MathNode?, sup: MathNode?, size: CGFloat) -> MathBox {
        let opBox = layout(base, size: size * 1.35, display: false)
        let scriptSize = size * 0.68
        let supBox = sup.map { layout($0, size: scriptSize, display: false) }
        let subBox = sub.map { layout($0, size: scriptSize, display: false) }
        let gap = size * 0.12

        let width = max(opBox.width, supBox?.width ?? 0, subBox?.width ?? 0)
        var ascent = opBox.ascent
        var descent = opBox.descent
        if let supBox { ascent += gap + supBox.height }
        if let subBox { descent += gap + subBox.height }

        return MathBox(width: width, ascent: ascent, descent: descent) { context, pen in
            opBox.draw(context, CGPoint(x: pen.x + (width - opBox.width) / 2, y: pen.y))
            if let supBox {
                supBox.draw(context, CGPoint(
                    x: pen.x + (width - supBox.width) / 2,
                    y: pen.y + opBox.ascent + gap + supBox.descent
                ))
            }
            if let subBox {
                subBox.draw(context, CGPoint(
                    x: pen.x + (width - subBox.width) / 2,
                    y: pen.y - opBox.descent - gap - subBox.ascent
                ))
            }
        }
    }

    // MARK: - Delimiters

    /// A single fence glyph scaled to `targetHeight` and vertically centered
    /// on `bodyBox`'s extent. Shared by the inline delimiter path and the
    /// matrix/grid path, which differ only in the target height they pass.
    private func stretchedFence(_ glyph: String, targetHeight: CGFloat, around bodyBox: MathBox, size: CGFloat) -> MathBox {
        guard !glyph.isEmpty else { return .empty }
        let probe = textBox(glyph, size: size, italic: false)
        let scale = max(1, targetHeight / max(probe.height, 1))
        let scaled = textBox(glyph, size: size * scale, italic: false)
        // Center the fence on the body's vertical extent.
        let offset = (bodyBox.ascent - bodyBox.descent) / 2 - (scaled.ascent - scaled.descent) / 2
        return MathBox(
            width: scaled.width,
            ascent: scaled.ascent + offset,
            descent: scaled.descent - offset
        ) { context, pen in
            scaled.draw(context, CGPoint(x: pen.x, y: pen.y + offset))
        }
    }

    private func delimitedBox(_ left: String, _ body: MathNode, _ right: String, size: CGFloat, display: Bool) -> MathBox {
        let bodyBox = layout(body, size: size, display: display)

        let target = max(bodyBox.height, size)
        let leftBox = stretchedFence(left, targetHeight: target, around: bodyBox, size: size)
        let rightBox = stretchedFence(right, targetHeight: target, around: bodyBox, size: size)
        let width = leftBox.width + bodyBox.width + rightBox.width
        let ascent = max(bodyBox.ascent, leftBox.ascent, rightBox.ascent)
        let descent = max(bodyBox.descent, leftBox.descent, rightBox.descent)

        return MathBox(width: width, ascent: ascent, descent: descent) { context, pen in
            leftBox.draw(context, pen)
            bodyBox.draw(context, CGPoint(x: pen.x + leftBox.width, y: pen.y))
            rightBox.draw(context, CGPoint(x: pen.x + leftBox.width + bodyBox.width, y: pen.y))
        }
    }

    // MARK: - Matrices, cases, aligned

    private func matrixBox(_ rows: [[MathNode]], left: String, right: String,
                           style: MathMatrixStyle, size: CGFloat) -> MathBox {
        guard !rows.isEmpty else { return .empty }

        // Lay out every cell; track per-column width and per-row ascent/descent.
        let columns = rows.map(\.count).max() ?? 0
        var cellBoxes: [[MathBox]] = []
        var colWidth = [CGFloat](repeating: 0, count: columns)
        var rowAscent = [CGFloat](repeating: 0, count: rows.count)
        var rowDescent = [CGFloat](repeating: 0, count: rows.count)
        for (r, row) in rows.enumerated() {
            var boxes: [MathBox] = []
            for (c, cell) in row.enumerated() {
                let box = layout(cell, size: size, display: false)
                boxes.append(box)
                colWidth[c] = max(colWidth[c], box.width)
                rowAscent[r] = max(rowAscent[r], box.ascent)
                rowDescent[r] = max(rowDescent[r], box.descent)
            }
            // Empty rows still take a line.
            if row.isEmpty { rowAscent[r] = size * 0.5; rowDescent[r] = size * 0.2 }
            cellBoxes.append(boxes)
        }

        let rowGap = size * 0.35
        // `aligned` columns meet at the & with almost no gutter; grids space out.
        let colGap = style == .aligned ? size * 0.16 : size * 0.7

        var totalHeight: CGFloat = 0
        for r in 0..<rows.count {
            totalHeight += rowAscent[r] + rowDescent[r]
            if r > 0 { totalHeight += rowGap }
        }
        let gridWidth = colWidth.reduce(0, +) + CGFloat(max(columns - 1, 0)) * colGap

        // Center the grid on the math axis.
        let axis = size * 0.26
        let ascent = totalHeight / 2 + axis
        let descent = totalHeight / 2 - axis

        // Column x-origins.
        var colX = [CGFloat](repeating: 0, count: columns)
        var running: CGFloat = 0
        for c in 0..<columns {
            colX[c] = running
            running += colWidth[c] + colGap
        }

        func cellOriginX(col: Int, box: MathBox) -> CGFloat {
            switch style {
            case .cases:
                return colX[col]                                   // left-aligned
            case .aligned:
                // Even columns right-aligned, odd left-aligned (meet at &).
                return col % 2 == 0 ? colX[col] + (colWidth[col] - box.width) : colX[col]
            case .centered:
                return colX[col] + (colWidth[col] - box.width) / 2
            }
        }

        let grid = MathBox(width: gridWidth, ascent: ascent, descent: descent) { context, pen in
            // First row's baseline sits below the top by its ascent.
            var yTop = pen.y + ascent
            for (r, boxes) in cellBoxes.enumerated() {
                let baseline = yTop - rowAscent[r]
                for (c, box) in boxes.enumerated() {
                    box.draw(context, CGPoint(x: pen.x + cellOriginX(col: c, box: box), y: baseline))
                }
                yTop -= rowAscent[r] + rowDescent[r] + rowGap
            }
        }

        guard !left.isEmpty || !right.isEmpty else { return grid }

        // Wrap in stretched fences by delegating to the delimiter layout,
        // which sizes the glyphs to the grid's height.
        return delimitedBoxAround(grid, left: left, right: right, size: size)
    }

    /// Fences an already-laid-out box (the grid) with stretched delimiters.
    private func delimitedBoxAround(_ bodyBox: MathBox, left: String, right: String, size: CGFloat) -> MathBox {
        let leftBox = stretchedFence(left, targetHeight: bodyBox.height, around: bodyBox, size: size)
        let rightBox = stretchedFence(right, targetHeight: bodyBox.height, around: bodyBox, size: size)
        let width = leftBox.width + bodyBox.width + rightBox.width + size * 0.1
        return MathBox(width: width,
                       ascent: max(bodyBox.ascent, leftBox.ascent, rightBox.ascent),
                       descent: max(bodyBox.descent, leftBox.descent, rightBox.descent)) { context, pen in
            leftBox.draw(context, pen)
            bodyBox.draw(context, CGPoint(x: pen.x + leftBox.width + size * 0.05, y: pen.y))
            rightBox.draw(context, CGPoint(x: pen.x + leftBox.width + bodyBox.width + size * 0.05, y: pen.y))
        }
    }
}

/// Resolves a possibly-dynamic platform color to CGColor for the current
/// appearance at draw time.
func resolvedCGColor(_ color: PlatformColor) -> CGColor {
    #if canImport(AppKit)
    return color.usingColorSpace(.sRGB)?.cgColor ?? color.cgColor
    #else
    return color.cgColor
    #endif
}
#endif
