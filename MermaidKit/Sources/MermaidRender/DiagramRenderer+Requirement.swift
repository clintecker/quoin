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

    static func draw(_ layout: RequirementLayout, theme: DiagramTheme, in context: CGContext) {
        // Connectors first, so box fills sit cleanly on top of any overlap.
        let edgeColor = theme.ink.withAlphaComponent(0.42)
        for edge in layout.edges {
            let pts = edge.points
            guard let start = pts.first, let end = pts.last else { continue }
            context.saveGState()
            context.setStrokeColor(resolvedCGColor(edgeColor))
            context.setLineWidth(1)
            context.setLineJoin(.round)
            context.beginPath()
            context.move(to: start)
            for p in pts.dropFirst() { context.addLine(to: p) }
            context.strokePath()
            context.restoreGState()
            // Arrowhead points along the final segment.
            let prev = pts.count >= 2 ? pts[pts.count - 2] : start
            drawArrowhead(at: end, from: prev, color: edgeColor, canvas: theme.canvas, in: context)
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

        // Edge labels LAST, on top of every connector and box, so no line is
        // ever drawn through a label (the chip masks whatever sits under it).
        for edge in layout.edges {
            drawEdgeLabel(edge.label, at: routeMidpoint(edge.points), theme: theme, in: context)
        }
    }

    /// The point halfway along a routed polyline by cumulative segment length,
    /// used to anchor the edge label near the middle of the connector.
    private static func routeMidpoint(_ points: [CGPoint]) -> CGPoint {
        guard let first = points.first else { return .zero }
        guard points.count > 1 else { return first }
        var total: CGFloat = 0
        var lengths: [CGFloat] = []
        for (a, b) in zip(points, points.dropFirst()) {
            let d = abs(b.x - a.x) + abs(b.y - a.y)
            lengths.append(d)
            total += d
        }
        guard total > 0 else { return first }
        var acc: CGFloat = 0
        for (i, seg) in lengths.enumerated() {
            if acc + seg >= total / 2 {
                let t = seg > 0 ? (total / 2 - acc) / seg : 0
                let a = points[i], b = points[i + 1]
                return CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t)
            }
            acc += seg
        }
        return points[points.count / 2]
    }
}
#endif
