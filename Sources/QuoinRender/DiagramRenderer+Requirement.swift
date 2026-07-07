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

extension DiagramRenderer {

    static func draw(_ layout: RequirementLayout, theme: Theme, in context: CGContext) {
        // Connectors first, so box fills sit cleanly on top of any overlap.
        let edgeColor = theme.ink.withAlphaComponent(0.42)
        for edge in layout.edges {
            context.saveGState()
            context.setStrokeColor(resolvedCGColor(edgeColor))
            context.setLineWidth(1)
            context.beginPath()
            context.move(to: edge.from)
            context.addLine(to: edge.to)
            context.strokePath()
            context.restoreGState()
            drawArrowhead(at: edge.to, from: edge.from, color: edgeColor, canvas: theme.canvas, in: context)
            drawEdgeLabel(edge.label, at: CGPoint(x: (edge.from.x + edge.to.x) / 2,
                                                  y: (edge.from.y + edge.to.y) / 2),
                          theme: theme, in: context)
        }

        let padding: CGFloat = 11
        let stereoH: CGFloat = 14
        let nameH: CGFloat = 20
        let sepGap: CGFloat = 8
        let lineH: CGFloat = 15

        for box in layout.boxes {
            let tint = categoricalColor(box.colorIndex)
            let fill = tint.withAlphaComponent(box.isElement ? 0.10 : 0.14)
            let stroke = tint.withAlphaComponent(0.6)
            fillStrokeBox(box.frame, radius: 6, fill: fill, stroke: stroke, in: context)

            let top = box.frame.minY + padding
            drawText(box.stereotype, center: CGPoint(x: box.frame.midX, y: top + stereoH / 2),
                     size: 9.5, color: theme.secondaryTextColor, in: context)
            drawText(box.name, center: CGPoint(x: box.frame.midX, y: top + stereoH + nameH / 2),
                     size: 12.5, weight: .semibold, color: theme.ink, in: context)

            let sepY = top + stereoH + nameH + sepGap / 2
            strokeHLine(y: sepY, from: box.frame.minX + padding, to: box.frame.maxX - padding,
                        color: theme.hairline, in: context)

            var lineY = top + stereoH + nameH + sepGap + lineH / 2
            for line in box.detailLines {
                drawTextLeft(line, at: CGPoint(x: box.frame.minX + padding, y: lineY),
                             size: 10.5, color: theme.secondaryTextColor, in: context)
                lineY += lineH
            }
        }
    }
}
#endif
