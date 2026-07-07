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

    static func draw(_ layout: SankeyLayout, theme: DiagramTheme, in context: CGContext) {
        // Flow bands first, so the solid node bars and labels sit on top.
        for link in layout.links {
            let color = categoricalColor(link.colorIndex)
            let cx = (link.sourceTop.x + link.targetTop.x) / 2
            let path = CGMutablePath()
            path.move(to: link.sourceTop)
            path.addCurve(to: link.targetTop,
                          control1: CGPoint(x: cx, y: link.sourceTop.y),
                          control2: CGPoint(x: cx, y: link.targetTop.y))
            path.addLine(to: link.targetBottom)
            path.addCurve(to: link.sourceBottom,
                          control1: CGPoint(x: cx, y: link.targetBottom.y),
                          control2: CGPoint(x: cx, y: link.sourceBottom.y))
            path.closeSubpath()

            context.saveGState()
            context.setFillColor(resolvedCGColor(color.withAlphaComponent(theme.prefersDark ? 0.34 : 0.28)))
            context.addPath(path)
            context.fillPath()
            context.restoreGState()
        }

        // Node bars: solid tinted rectangles with a firmer border.
        for node in layout.nodes {
            let color = categoricalColor(node.colorIndex)
            fillStrokeBox(node.rect, radius: 2,
                          fill: color.withAlphaComponent(0.9), stroke: color, in: context)
        }

        // Labels on top of everything.
        for node in layout.nodes where !node.label.isEmpty {
            drawText(node.label, center: node.labelCenter, size: 11, color: theme.ink, in: context)
        }
    }
}
#endif
