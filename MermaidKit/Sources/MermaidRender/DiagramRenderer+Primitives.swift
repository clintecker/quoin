#if canImport(AppKit) || canImport(UIKit)
import Foundation
import CoreText
import CoreGraphics
import MermaidLayout

#if canImport(AppKit)
import AppKit
#else
import UIKit
#endif

extension DiagramRenderer {

    static func font(_ size: CGFloat, weight: PlatformFont.Weight = .regular) -> CTFont {
        PlatformFont.systemFont(ofSize: size, weight: weight) as CTFont
    }

    static func measure(_ text: String, size: CGFloat, weight: PlatformFont.Weight = .regular) -> CGSize {
        let attributed = NSAttributedString(string: text, attributes: [
            kCTFontAttributeName as NSAttributedString.Key: font(size, weight: weight),
        ])
        let line = CTLineCreateWithAttributedString(attributed)
        var ascent: CGFloat = 0
        var descent: CGFloat = 0
        let width = CGFloat(CTLineGetTypographicBounds(line, &ascent, &descent, nil))
        return CGSize(width: width, height: ascent + descent)
    }

    /// Draws text centered on `center` in a flipped (y-down) context.
    static func drawText(
        _ text: String,
        center: CGPoint,
        size: CGFloat,
        weight: PlatformFont.Weight = .regular,
        color: PlatformColor,
        in context: CGContext
    ) {
        guard !text.isEmpty else { return }
        let attributed = NSAttributedString(string: text, attributes: [
            kCTFontAttributeName as NSAttributedString.Key: font(size, weight: weight),
            kCTForegroundColorFromContextAttributeName as NSAttributedString.Key: true,
        ])
        let line = CTLineCreateWithAttributedString(attributed)
        var ascent: CGFloat = 0
        var descent: CGFloat = 0
        let width = CGFloat(CTLineGetTypographicBounds(line, &ascent, &descent, nil))

        context.saveGState()
        context.setFillColor(resolvedCGColor(color))
        context.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
        context.textPosition = CGPoint(
            x: center.x - width / 2,
            y: center.y + (ascent - descent) / 2
        )
        CTLineDraw(line, context)
        context.restoreGState()
    }

    /// The true bounding box of everything a box/flowchart diagram draws: the
    /// layout's own `size` (boxes + clamped labels) unioned with every edge
    /// point inflated by the maximum endpoint-marker reach. Markers point
    /// inward along the edge (already inside the point-to-point span) and only
    /// spread a few points perpendicular, so a uniform inflate captures them
    /// without having to know each marker's exact geometry.
    static func contentBounds(size: CGSize, edges: [[CGPoint]]) -> CGRect {
        var box = CGRect(origin: .zero, size: size)
        // Widest perpendicular marker spread across all types: the ER crow's
        // foot / zero-circle and the UML triangle sit within this of the line.
        // Must cover the largest end-marker overhang: arrowheads reach 8.5pt
        // along the edge, ER crow's feet ~18pt along (toward the box, already
        // inside bounds) with ~6pt perpendicular spread. 10pt covers every
        // marker's off-edge spread with margin.
        let markerReach: CGFloat = 10
        for points in edges {
            for p in points {
                box = box.union(CGRect(x: p.x - markerReach, y: p.y - markerReach,
                                       width: markerReach * 2, height: markerReach * 2))
            }
        }
        return box
    }

    /// The standard centred diagram title — one implementation for the nine
    /// chart types that draw one (12.5pt semibold ink, centred at y = 14).
    static func drawDiagramTitle(_ title: String?, width: CGFloat, theme: DiagramTheme, in context: CGContext) {
        guard let title, !title.isEmpty else { return }
        drawText(title, center: CGPoint(x: width / 2, y: 14),
                 size: 12.5, weight: .semibold, color: theme.ink, in: context)
    }

    static func categoricalColor(_ index: Int) -> PlatformColor {
        categoricalPalette[index % categoricalPalette.count]
    }

    /// Draws text rotated 90° (reading bottom-to-top) centered on `center`,
    /// for vertical y-axis labels.
    static func drawTextRotated(
        _ text: String, center: CGPoint, size: CGFloat,
        weight: PlatformFont.Weight = .regular, color: PlatformColor, in context: CGContext
    ) {
        guard !text.isEmpty else { return }
        context.saveGState()
        context.translateBy(x: center.x, y: center.y)
        context.rotate(by: -.pi / 2)
        drawText(text, center: .zero, size: size, weight: weight, color: color, in: context)
        context.restoreGState()
    }

    static func drawTextLeft(
        _ text: String, at origin: CGPoint, size: CGFloat,
        weight: PlatformFont.Weight = .regular, color: PlatformColor, in context: CGContext
    ) {
        let measured = measure(text, size: size, weight: weight)
        drawText(text, center: CGPoint(x: origin.x + measured.width / 2, y: origin.y),
                 size: size, weight: weight, color: color, in: context)
    }
}
#endif
