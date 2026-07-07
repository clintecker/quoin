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

    static func draw(_ layout: TreemapLayout, theme: DiagramTheme, in context: CGContext) {
        for cell in layout.cells {
            let tint = theme.categoricalColor(cell.colorIndex)
            if cell.isLeaf {
                context.saveGState()
                context.setFillColor(resolvedCGColor(tint.withAlphaComponent(0.30)))
                context.fill(cell.frame.insetBy(dx: 0.5, dy: 0.5))
                context.setStrokeColor(resolvedCGColor(tint.withAlphaComponent(0.6)))
                context.setLineWidth(1)
                context.stroke(cell.frame.insetBy(dx: 0.5, dy: 0.5))
                context.restoreGState()

                // Label + value, only when the cell is roomy enough.
                if cell.frame.width > 40, cell.frame.height > 20 {
                    let measured = measure(cell.label, size: 10)
                    if measured.width <= cell.frame.width - 8 {
                        drawText(cell.label, center: CGPoint(x: cell.frame.midX, y: cell.frame.midY - 5),
                                 size: 10, color: theme.ink, in: context)
                        drawText(formatTreemapValue(cell.value),
                                 center: CGPoint(x: cell.frame.midX, y: cell.frame.midY + 9),
                                 size: 9, color: theme.secondaryTextColor, in: context)
                    }
                }
            } else {
                // Group: outline + a header label at the top.
                context.saveGState()
                context.setStrokeColor(resolvedCGColor(tint.withAlphaComponent(0.7)))
                context.setLineWidth(cell.depth == 1 ? 1.5 : 1)
                context.stroke(cell.frame)
                context.restoreGState()
                if cell.frame.height > 44, cell.frame.width > 40 {
                    drawTextLeft(cell.label, at: CGPoint(x: cell.frame.minX + 6, y: cell.frame.minY + 10),
                                 size: 9.5, weight: .semibold, color: theme.secondaryTextColor, in: context)
                }
            }
        }
    }

    private static func formatTreemapValue(_ value: Double) -> String {
        value == value.rounded() ? String(Int(value)) : String(format: "%.1f", value)
    }
}
#endif
