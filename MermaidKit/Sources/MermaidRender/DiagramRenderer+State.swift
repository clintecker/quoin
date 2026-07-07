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

    static func draw(_ layout: StateLayout, theme: DiagramTheme, in context: CGContext) {
        let stroke = theme.ink.withAlphaComponent(0.35)
        let nodeFill = theme.accent.withAlphaComponent(0.06)
        let solid = theme.ink.withAlphaComponent(0.75)

        // Composite containers first, outermost → innermost so nested tints
        // stack; the title strip carries the composite's name.
        for container in layout.containers.sorted(by: { $0.depth < $1.depth }) {
            context.saveGState()
            context.addPath(CGPath(roundedRect: container.frame, cornerWidth: 8, cornerHeight: 8, transform: nil))
            context.setFillColor(resolvedCGColor(theme.ink.withAlphaComponent(0.03)))
            context.setStrokeColor(resolvedCGColor(stroke))
            context.setLineWidth(1)
            context.drawPath(using: .fillStroke)
            drawText(container.label,
                     center: CGPoint(x: container.frame.midX, y: container.frame.minY + container.titleHeight / 2),
                     size: 11.5, weight: .semibold, color: theme.ink, in: context)
            let sepY = container.frame.minY + container.titleHeight
            context.setStrokeColor(resolvedCGColor(theme.ink.withAlphaComponent(0.15)))
            context.beginPath()
            context.move(to: CGPoint(x: container.frame.minX, y: sepY))
            context.addLine(to: CGPoint(x: container.frame.maxX, y: sepY))
            context.strokePath()
            context.restoreGState()
        }

        // Transitions (including those flattened out of composites): batch the
        // shafts into one stroke so crossing lines don't stack their alpha.
        context.saveGState()
        context.setStrokeColor(resolvedCGColor(stroke))
        context.setLineWidth(1)
        context.beginPath()
        for edge in layout.edges { appendRoundedPolyline(edge.points, to: context) }
        context.strokePath()
        context.restoreGState()

        var placedLabels: [CGRect] = []
        let nodeObstacles = layout.nodes.map(\.frame)
        let allEdgeRects = layout.edges.map { edgeSegmentRects($0.points) }
        for (i, edge) in layout.edges.enumerated() {
            let approach = edge.points.count > 1 ? edge.points[edge.points.count - 2] : edge.start
            drawArrowhead(at: edge.end, from: approach, color: stroke, canvas: theme.canvas, in: context)
            if let label = edge.label, !label.isEmpty {
                var obstacles = nodeObstacles
                for (j, rects) in allEdgeRects.enumerated() where j != i { obstacles += rects }
                let at = labelAnchor(for: edge.points, label: label, bounds: layout.size, obstacles: obstacles, placed: &placedLabels)
                drawEdgeLabel(label, at: at, theme: theme, in: context)
            }
        }

        // Nodes on top so borders sit above the edge ends.
        for node in layout.nodes {
            context.saveGState()
            context.setStrokeColor(resolvedCGColor(stroke))
            context.setLineWidth(1)
            switch node.kind {
            case .start:
                drawStartTerminal(node.frame, color: solid, in: context)
            case .end:
                drawEndTerminal(node.frame, color: solid, in: context)
            case .choice:
                context.addPath(diamondPath(node.frame))
                context.setFillColor(resolvedCGColor(nodeFill))
                context.drawPath(using: .fillStroke)
            case .fork, .join:
                context.addPath(CGPath(roundedRect: node.frame, cornerWidth: 2, cornerHeight: 2, transform: nil))
                context.setFillColor(resolvedCGColor(theme.ink.withAlphaComponent(0.7)))
                context.fillPath()
            case .simple:
                context.addPath(CGPath(roundedRect: node.frame, cornerWidth: 8, cornerHeight: 8, transform: nil))
                context.setFillColor(resolvedCGColor(nodeFill))
                context.drawPath(using: .fillStroke)
                drawText(node.label, center: CGPoint(x: node.frame.midX, y: node.frame.midY),
                         size: 12, weight: .medium, color: theme.ink, in: context)
            }
            context.restoreGState()
        }
    }

    /// Crow's-foot notation drawn along the edge at `end`, oriented away
    /// from `other`: ticks for "one", a circle for "zero", three prongs
    /// for "many".
    static func drawCardinality(
        _ card: ERDiagram.Cardinality, at end: CGPoint, from other: CGPoint,
        color: PlatformColor, in context: CGContext
    ) {
        let angle = atan2(other.y - end.y, other.x - end.x) // pointing inward (up the line)
        func p(out: CGFloat, side: CGFloat) -> CGPoint {
            CGPoint(
                x: end.x + out * cos(angle) - side * sin(angle),
                y: end.y + out * sin(angle) + side * cos(angle)
            )
        }

        context.saveGState()
        context.setStrokeColor(resolvedCGColor(color))
        context.setLineWidth(1.2)
        context.setLineCap(.round)
        context.setLineJoin(.round)

        // A perpendicular "one" tick across the line at `out`.
        func tick(at out: CGFloat, half: CGFloat = 4.5) {
            context.beginPath()
            context.move(to: p(out: out, side: half))
            context.addLine(to: p(out: out, side: -half))
            context.strokePath()
        }
        // The "many" crow's foot: three prongs fanning from an apex up the line
        // out to the entity box — kept compact so it stays in proportion.
        func crowsFoot() {
            let apex = p(out: 11, side: 0)
            context.beginPath()
            for side in [CGFloat(5), 0, -5] {
                context.move(to: apex)
                context.addLine(to: p(out: 1, side: side))
            }
            context.strokePath()
        }
        // The "zero" circle centered on the line at `out`.
        func circle(at out: CGFloat) {
            let c = p(out: out, side: 0)
            context.beginPath()
            context.addEllipse(in: CGRect(x: c.x - 3, y: c.y - 3, width: 6, height: 6))
            context.strokePath()
        }

        switch card {
        case .one:        tick(at: 6); tick(at: 9.5)    // ‖  exactly one
        case .zeroOrOne:  tick(at: 11); circle(at: 5.5) // ○|  zero or one
        case .oneOrMore:  crowsFoot(); tick(at: 14)     // ‹|  one or many
        case .zeroOrMore: crowsFoot(); circle(at: 15)   // ‹○  zero or many
        }
        context.restoreGState()
    }
}
#endif
