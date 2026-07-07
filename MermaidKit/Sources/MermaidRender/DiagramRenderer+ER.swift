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

    static func draw(_ layout: ERLayout, theme: DiagramTheme, in context: CGContext) {
        let stroke = theme.ink.withAlphaComponent(0.35)
        let hairline = theme.ink.withAlphaComponent(0.18)
        let fill = theme.accent.withAlphaComponent(0.06)

        // Batch shafts by dash style so crossing edges don't stack alpha.
        strokeEdgeShafts(layout.edges.map { ($0.points, !$0.identifying) }, color: stroke, in: context)
        var placedLabels: [CGRect] = []
        let nodeObstacles = layout.boxes.map(\.frame)
        let allEdgeRects = layout.edges.map { edgeSegmentRects($0.points) }
        for (i, edge) in layout.edges.enumerated() {
            let fromApproach = edge.points.count > 1 ? edge.points[1] : edge.end
            let toApproach = edge.points.count > 1 ? edge.points[edge.points.count - 2] : edge.start
            drawCardinality(edge.fromCard, at: edge.start, from: fromApproach, color: stroke, in: context)
            drawCardinality(edge.toCard, at: edge.end, from: toApproach, color: stroke, in: context)

            if !edge.label.isEmpty {
                var obstacles = nodeObstacles
                for (j, rects) in allEdgeRects.enumerated() where j != i { obstacles += rects }
                let at = labelAnchor(for: edge.points, label: edge.label, bounds: layout.size, obstacles: obstacles, placed: &placedLabels)
                drawEdgeLabel(edge.label, at: at, theme: theme, in: context)
            }
        }

        for box in layout.boxes {
            fillStrokeBox(box.frame, radius: 4, fill: fill, stroke: stroke, in: context)

            drawText(box.name,
                     center: CGPoint(x: box.frame.midX, y: box.frame.minY + box.nameHeight / 2),
                     size: 12, weight: .semibold, color: theme.ink, in: context)

            if !box.attributes.isEmpty {
                var rowY = box.frame.minY + box.nameHeight
                strokeHLine(y: rowY, from: box.frame.minX, to: box.frame.maxX, color: hairline, in: context)

                rowY += 5
                let typeX = box.frame.minX + 12
                for attribute in box.attributes {
                    let center = rowY + box.rowHeight / 2
                    drawTextLeft(attribute.type, at: CGPoint(x: typeX, y: center),
                                 size: 10.5, color: theme.secondaryTextColor, in: context)
                    let typeWidth = measure(attribute.type, size: 10.5).width
                    drawTextLeft(attribute.name, at: CGPoint(x: typeX + typeWidth + 8, y: center),
                                 size: 10.5, weight: .medium, color: theme.ink, in: context)
                    rowY += box.rowHeight
                }
            }
        }
    }
}
#endif
