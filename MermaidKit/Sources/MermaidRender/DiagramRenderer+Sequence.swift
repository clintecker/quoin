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

    static func draw(_ layout: SequenceLayout, theme: DiagramTheme, in context: CGContext) {
        let stroke = theme.ink.withAlphaComponent(0.35)
        let hairline = theme.ink.withAlphaComponent(0.18)

        // Lifelines behind everything.
        for head in layout.heads {
            context.saveGState()
            context.setStrokeColor(resolvedCGColor(hairline))
            context.setLineWidth(1)
            context.setLineDash(phase: 0, lengths: [3, 3])
            context.beginPath()
            context.move(to: CGPoint(x: head.lifelineX, y: head.frame.maxY))
            context.addLine(to: CGPoint(x: head.lifelineX, y: layout.lifelineBottom))
            context.strokePath()
            context.restoreGState()
        }

        for head in layout.heads {
            fillStrokeBox(head.frame, radius: 6, fill: theme.accent.withAlphaComponent(0.06), stroke: stroke, in: context)
            drawText(head.label, center: CGPoint(x: head.frame.midX, y: head.frame.midY),
                     size: 12, weight: .medium, color: theme.ink, in: context)
        }

        for arrow in layout.arrows {
            context.saveGState()
            context.setStrokeColor(resolvedCGColor(stroke))
            context.setLineWidth(1)
            if arrow.dashed { context.setLineDash(phase: 0, lengths: [4, 3]) }
            context.beginPath()
            if arrow.isSelfMessage {
                // Loop out, down, and back into the lifeline.
                context.move(to: CGPoint(x: arrow.fromX, y: arrow.y))
                context.addLine(to: CGPoint(x: arrow.toX, y: arrow.y))
                context.addLine(to: CGPoint(x: arrow.toX, y: arrow.y + 12))
                context.addLine(to: CGPoint(x: arrow.fromX, y: arrow.y + 12))
            } else {
                context.move(to: CGPoint(x: arrow.fromX, y: arrow.y))
                context.addLine(to: CGPoint(x: arrow.toX, y: arrow.y))
            }
            context.strokePath()
            context.restoreGState()

            if arrow.isSelfMessage {
                drawArrowhead(
                    at: CGPoint(x: arrow.fromX, y: arrow.y + 12),
                    from: CGPoint(x: arrow.toX, y: arrow.y + 12),
                    color: stroke, canvas: theme.canvas, in: context
                )
                if !arrow.text.isEmpty {
                    let size = measure(arrow.text, size: 10.5)
                    drawText(arrow.text,
                             center: CGPoint(x: arrow.toX + 8 + size.width / 2, y: arrow.y + 6),
                             size: 10.5, color: theme.secondaryTextColor, in: context)
                }
            } else {
                drawArrowhead(
                    at: CGPoint(x: arrow.toX, y: arrow.y),
                    from: CGPoint(x: arrow.fromX, y: arrow.y),
                    color: stroke, canvas: theme.canvas, in: context
                )
                if !arrow.text.isEmpty {
                    drawText(arrow.text,
                             center: CGPoint(x: (arrow.fromX + arrow.toX) / 2, y: arrow.y - 10),
                             size: 10.5, color: theme.secondaryTextColor, in: context)
                }
            }
        }
    }
}
#endif
