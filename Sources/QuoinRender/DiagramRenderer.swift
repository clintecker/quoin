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

/// Draws parsed Mermaid diagrams in the Graphite design language: SF
/// labels, hairline strokes, radius-8 blocks, semantic tints. Layout comes
/// from the platform-free engine in QuoinCore; this file only draws.
enum DiagramRenderer {

    private final class Entry {
        let image: PlatformImage
        init(image: PlatformImage) { self.image = image }
    }

    private static let cache = NSCache<NSString, Entry>()

    /// A rendered attachment for mermaid source, or nil when the dialect
    /// isn't supported yet (caller keeps the styled-source fallback).
    static func attachmentString(source: String, theme: Theme) -> NSAttributedString? {
        guard let diagram = MermaidParser.parse(source) else { return nil }

        let key = "mermaid|\(theme.prefersDark ? "dark" : "light")|\(source)" as NSString
        let entry: Entry
        if let cached = cache.object(forKey: key) {
            entry = cached
        } else {
            let measure: DiagramTextMeasurer = { text, fontSize in
                Self.measure(text, size: CGFloat(fontSize))
            }
            let size: CGSize
            let draw: (CGContext) -> Void
            switch diagram {
            case .flowchart(let chart):
                let layout = DiagramLayoutEngine.layout(chart, measure: measure)
                size = layout.size
                draw = { context in Self.draw(layout, theme: theme, in: context) }
            case .sequence(let sequence):
                let layout = DiagramLayoutEngine.layout(sequence, measure: measure)
                size = layout.size
                draw = { context in Self.draw(layout, theme: theme, in: context) }
            case .pie(let pie):
                let layout = DiagramLayoutEngine.layout(pie, measure: measure)
                size = layout.size
                draw = { context in Self.draw(layout, theme: theme, in: context) }
            case .classDiagram(let classDiagram):
                let layout = DiagramLayoutEngine.layout(classDiagram, measure: measure)
                size = layout.size
                draw = { context in Self.draw(layout, theme: theme, in: context) }
            case .er(let er):
                let layout = DiagramLayoutEngine.layout(er, measure: measure)
                size = layout.size
                draw = { context in Self.draw(layout, theme: theme, in: context) }
            }
            guard size.width > 0, size.height > 0, size.width < 4000, size.height < 4000 else { return nil }

            #if canImport(AppKit)
            let appearance = NSAppearance(named: theme.prefersDark ? .darkAqua : .aqua)
            let image = NSImage(size: size, flipped: true) { _ in
                guard let context = NSGraphicsContext.current?.cgContext else { return false }
                if let appearance {
                    appearance.performAsCurrentDrawingAppearance { draw(context) }
                } else {
                    draw(context)
                }
                return true
            }
            #else
            let renderer = UIGraphicsImageRenderer(size: size)
            let image = renderer.image { rendererContext in
                draw(rendererContext.cgContext)
            }
            #endif
            entry = Entry(image: image)
            cache.setObject(entry, forKey: key)
        }

        let attachment = NSTextAttachment()
        attachment.image = entry.image
        attachment.bounds = CGRect(origin: .zero, size: entry.image.size)
        return NSAttributedString(attachment: attachment)
    }

    // MARK: - Text (flipped-context CoreText)

    private static func font(_ size: CGFloat, weight: PlatformFont.Weight = .regular) -> CTFont {
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
    private static func drawText(
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

    // MARK: - Flowchart

    private static func draw(_ layout: FlowchartLayout, theme: Theme, in context: CGContext) {
        let stroke = theme.ink.withAlphaComponent(0.35)
        let fill = theme.accent.withAlphaComponent(0.06)

        for edge in layout.edges {
            context.saveGState()
            context.setStrokeColor(resolvedCGColor(stroke))
            context.setLineWidth(1)
            if edge.dashed { context.setLineDash(phase: 0, lengths: [4, 3]) }
            context.beginPath()
            // Orthogonal polyline with softly rounded corners.
            context.move(to: edge.points[0])
            if edge.points.count > 2 {
                for index in 1..<(edge.points.count - 1) {
                    context.addArc(tangent1End: edge.points[index],
                                   tangent2End: edge.points[index + 1], radius: 5)
                }
            }
            context.addLine(to: edge.points.last!)
            context.strokePath()
            context.restoreGState()

            if edge.hasArrow {
                let approach = edge.points.count > 1 ? edge.points[edge.points.count - 2] : edge.start
                drawArrowhead(at: edge.end, from: approach, color: stroke, in: context)
            }
            if let label = edge.label, !label.isEmpty {
                let mid = CGPoint(x: (edge.start.x + edge.end.x) / 2, y: (edge.start.y + edge.end.y) / 2)
                let size = measure(label, size: 10.5)
                let pad: CGFloat = 3
                let rect = CGRect(
                    x: mid.x - size.width / 2 - pad, y: mid.y - size.height / 2 - pad,
                    width: size.width + pad * 2, height: size.height + pad * 2
                )
                context.setFillColor(resolvedCGColor(theme.canvas))
                context.fill(rect)
                drawText(label, center: mid, size: 10.5, color: theme.secondaryTextColor, in: context)
            }
        }

        for node in layout.nodes {
            context.saveGState()
            context.setFillColor(resolvedCGColor(fill))
            context.setStrokeColor(resolvedCGColor(stroke))
            context.setLineWidth(1)

            // State-diagram terminals draw specially: a filled dot and a
            // ringed dot, in ink rather than the accent tint.
            if node.shape == .stateStart {
                context.setFillColor(resolvedCGColor(theme.ink.withAlphaComponent(0.75)))
                context.fillEllipse(in: node.frame)
                context.restoreGState()
                continue
            }
            if node.shape == .stateEnd {
                context.setStrokeColor(resolvedCGColor(theme.ink.withAlphaComponent(0.75)))
                context.strokeEllipse(in: node.frame.insetBy(dx: 1, dy: 1))
                context.setFillColor(resolvedCGColor(theme.ink.withAlphaComponent(0.75)))
                context.fillEllipse(in: node.frame.insetBy(dx: 4.5, dy: 4.5))
                context.restoreGState()
                continue
            }

            let path: CGPath
            switch node.shape {
            case .rectangle:
                path = CGPath(roundedRect: node.frame, cornerWidth: 4, cornerHeight: 4, transform: nil)
            case .rounded:
                path = CGPath(roundedRect: node.frame, cornerWidth: 8, cornerHeight: 8, transform: nil)
            case .stadium:
                let r = node.frame.height / 2
                path = CGPath(roundedRect: node.frame, cornerWidth: r, cornerHeight: r, transform: nil)
            case .circle, .stateStart, .stateEnd: // terminals handled above
                path = CGPath(ellipseIn: node.frame, transform: nil)
            case .diamond:
                let p = CGMutablePath()
                p.move(to: CGPoint(x: node.frame.midX, y: node.frame.minY))
                p.addLine(to: CGPoint(x: node.frame.maxX, y: node.frame.midY))
                p.addLine(to: CGPoint(x: node.frame.midX, y: node.frame.maxY))
                p.addLine(to: CGPoint(x: node.frame.minX, y: node.frame.midY))
                p.closeSubpath()
                path = p
            }
            context.addPath(path)
            context.drawPath(using: .fillStroke)
            context.restoreGState()

            drawText(node.label, center: CGPoint(x: node.frame.midX, y: node.frame.midY),
                     size: 12, weight: .medium, color: theme.ink, in: context)
        }
    }

    private static func drawArrowhead(at tip: CGPoint, from origin: CGPoint, color: PlatformColor, in context: CGContext) {
        let angle = atan2(tip.y - origin.y, tip.x - origin.x)
        let length: CGFloat = 7
        let spread: CGFloat = 0.46
        context.saveGState()
        context.setFillColor(resolvedCGColor(color))
        context.beginPath()
        context.move(to: tip)
        context.addLine(to: CGPoint(
            x: tip.x - length * cos(angle - spread),
            y: tip.y - length * sin(angle - spread)
        ))
        context.addLine(to: CGPoint(
            x: tip.x - length * cos(angle + spread),
            y: tip.y - length * sin(angle + spread)
        ))
        context.closePath()
        context.fillPath()
        context.restoreGState()
    }

    // MARK: - Sequence

    private static func draw(_ layout: SequenceLayout, theme: Theme, in context: CGContext) {
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
            context.saveGState()
            context.setFillColor(resolvedCGColor(theme.accent.withAlphaComponent(0.06)))
            context.setStrokeColor(resolvedCGColor(stroke))
            context.setLineWidth(1)
            let path = CGPath(roundedRect: head.frame, cornerWidth: 6, cornerHeight: 6, transform: nil)
            context.addPath(path)
            context.drawPath(using: .fillStroke)
            context.restoreGState()
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
                    color: stroke, in: context
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
                    color: stroke, in: context
                )
                if !arrow.text.isEmpty {
                    drawText(arrow.text,
                             center: CGPoint(x: (arrow.fromX + arrow.toX) / 2, y: arrow.y - 10),
                             size: 10.5, color: theme.secondaryTextColor, in: context)
                }
            }
        }
    }

    // MARK: - Pie

    private static func categoricalColor(_ index: Int) -> PlatformColor {
        let palette = Theme.Highlight.allCases
        return palette[index % palette.count].color
    }

    private static func draw(_ layout: PieLayout, theme: Theme, in context: CGContext) {
        if let title = layout.title {
            drawText(title,
                     center: CGPoint(x: layout.center.x, y: layout.center.y - layout.radius - 16),
                     size: 12.5, weight: .semibold, color: theme.ink, in: context)
        }

        for slice in layout.slices {
            context.saveGState()
            context.setFillColor(resolvedCGColor(categoricalColor(slice.colorIndex)))
            context.setStrokeColor(resolvedCGColor(theme.canvas))
            context.setLineWidth(1.5)
            context.beginPath()
            context.move(to: layout.center)
            context.addArc(
                center: layout.center, radius: layout.radius,
                startAngle: CGFloat(slice.startAngle), endAngle: CGFloat(slice.endAngle),
                clockwise: false
            )
            context.closePath()
            context.drawPath(using: .fillStroke)
            context.restoreGState()
        }

        // Legend with value chips, vertically stacked.
        var y = layout.legendOrigin.y
        for slice in layout.slices {
            let swatch = CGRect(x: layout.legendOrigin.x, y: y + 4, width: 10, height: 10)
            context.saveGState()
            context.setFillColor(resolvedCGColor(categoricalColor(slice.colorIndex)))
            context.addPath(CGPath(roundedRect: swatch, cornerWidth: 2, cornerHeight: 2, transform: nil))
            context.fillPath()
            context.restoreGState()

            let percent = Int((slice.fraction * 100).rounded())
            let label = "\(slice.label) (\(percent)%)"
            let size = measure(label, size: 10.5)
            drawText(label,
                     center: CGPoint(x: swatch.maxX + 6 + size.width / 2, y: swatch.midY),
                     size: 10.5, color: theme.secondaryTextColor, in: context)
            y += 20
        }
    }

    // MARK: - Class

    private static func drawTextLeft(
        _ text: String, at origin: CGPoint, size: CGFloat,
        weight: PlatformFont.Weight = .regular, color: PlatformColor, in context: CGContext
    ) {
        let measured = measure(text, size: size, weight: weight)
        drawText(text, center: CGPoint(x: origin.x + measured.width / 2, y: origin.y),
                 size: size, weight: weight, color: color, in: context)
    }

    private static func draw(_ layout: ClassLayout, theme: Theme, in context: CGContext) {
        let stroke = theme.ink.withAlphaComponent(0.35)
        let hairline = theme.ink.withAlphaComponent(0.18)
        let fill = theme.accent.withAlphaComponent(0.06)

        for edge in layout.edges {
            context.saveGState()
            context.setStrokeColor(resolvedCGColor(stroke))
            context.setLineWidth(1)
            if edge.kind.dashed { context.setLineDash(phase: 0, lengths: [4, 3]) }
            context.beginPath()
            context.move(to: edge.start)
            context.addLine(to: edge.end)
            context.strokePath()
            context.restoreGState()

            drawRelationMarker(edge.kind, at: edge.end, from: edge.start,
                               stroke: stroke, canvas: theme.canvas, in: context)

            if let label = edge.label, !label.isEmpty {
                let mid = CGPoint(x: (edge.start.x + edge.end.x) / 2,
                                  y: (edge.start.y + edge.end.y) / 2)
                let size = measure(label, size: 10.5)
                let pad: CGFloat = 3
                context.setFillColor(resolvedCGColor(theme.canvas))
                context.fill(CGRect(
                    x: mid.x - size.width / 2 - pad, y: mid.y - size.height / 2 - pad,
                    width: size.width + pad * 2, height: size.height + pad * 2
                ))
                drawText(label, center: mid, size: 10.5, color: theme.secondaryTextColor, in: context)
            }
        }

        for box in layout.boxes {
            context.saveGState()
            context.setFillColor(resolvedCGColor(fill))
            context.setStrokeColor(resolvedCGColor(stroke))
            context.setLineWidth(1)
            let path = CGPath(roundedRect: box.frame, cornerWidth: 4, cornerHeight: 4, transform: nil)
            context.addPath(path)
            context.drawPath(using: .fillStroke)
            context.restoreGState()

            drawText(box.name,
                     center: CGPoint(x: box.frame.midX, y: box.frame.minY + box.nameHeight / 2),
                     size: 12, weight: .semibold, color: theme.ink, in: context)

            var rowY = box.frame.minY + box.nameHeight
            func separator() {
                context.saveGState()
                context.setStrokeColor(resolvedCGColor(hairline))
                context.setLineWidth(1)
                context.beginPath()
                context.move(to: CGPoint(x: box.frame.minX, y: rowY))
                context.addLine(to: CGPoint(x: box.frame.maxX, y: rowY))
                context.strokePath()
                context.restoreGState()
            }
            let textX = box.frame.minX + 12
            if !box.attributes.isEmpty {
                separator()
                rowY += 5
                for attribute in box.attributes {
                    drawTextLeft(attribute, at: CGPoint(x: textX, y: rowY + box.rowHeight / 2),
                                 size: 10.5, color: theme.secondaryTextColor, in: context)
                    rowY += box.rowHeight
                }
            }
            if !box.methods.isEmpty {
                separator()
                rowY += 5
                for method in box.methods {
                    drawTextLeft(method, at: CGPoint(x: textX, y: rowY + box.rowHeight / 2),
                                 size: 10.5, color: theme.secondaryTextColor, in: context)
                    rowY += box.rowHeight
                }
            }
        }
    }

    private static func drawRelationMarker(
        _ kind: ClassDiagram.RelationKind, at tip: CGPoint, from origin: CGPoint,
        stroke: PlatformColor, canvas: PlatformColor, in context: CGContext
    ) {
        let angle = atan2(tip.y - origin.y, tip.x - origin.x)
        func point(back: CGFloat, side: CGFloat) -> CGPoint {
            CGPoint(
                x: tip.x - back * cos(angle) - side * sin(angle),
                y: tip.y - back * sin(angle) + side * cos(angle)
            )
        }

        switch kind {
        case .inheritance, .realization:
            // Hollow triangle, canvas-filled so the line doesn't show through.
            context.saveGState()
            context.setFillColor(resolvedCGColor(canvas))
            context.setStrokeColor(resolvedCGColor(stroke))
            context.setLineWidth(1)
            context.beginPath()
            context.move(to: tip)
            context.addLine(to: point(back: 11, side: 6))
            context.addLine(to: point(back: 11, side: -6))
            context.closePath()
            context.drawPath(using: .fillStroke)
            context.restoreGState()
        case .composition, .aggregation:
            context.saveGState()
            context.setFillColor(resolvedCGColor(kind == .composition ? stroke : canvas))
            context.setStrokeColor(resolvedCGColor(stroke))
            context.setLineWidth(1)
            context.beginPath()
            context.move(to: tip)
            context.addLine(to: point(back: 7, side: 4.5))
            context.addLine(to: point(back: 14, side: 0))
            context.addLine(to: point(back: 7, side: -4.5))
            context.closePath()
            context.drawPath(using: .fillStroke)
            context.restoreGState()
        case .association, .dependency:
            drawArrowhead(at: tip, from: origin, color: stroke, in: context)
        case .link:
            break
        }
    }

    // MARK: - ER

    private static func draw(_ layout: ERLayout, theme: Theme, in context: CGContext) {
        let stroke = theme.ink.withAlphaComponent(0.35)
        let hairline = theme.ink.withAlphaComponent(0.18)
        let fill = theme.accent.withAlphaComponent(0.06)

        for edge in layout.edges {
            context.saveGState()
            context.setStrokeColor(resolvedCGColor(stroke))
            context.setLineWidth(1)
            if !edge.identifying { context.setLineDash(phase: 0, lengths: [4, 3]) }
            context.beginPath()
            context.move(to: edge.start)
            context.addLine(to: edge.end)
            context.strokePath()
            context.restoreGState()

            drawCardinality(edge.fromCard, at: edge.start, from: edge.end, color: stroke, in: context)
            drawCardinality(edge.toCard, at: edge.end, from: edge.start, color: stroke, in: context)

            if !edge.label.isEmpty {
                let mid = CGPoint(x: (edge.start.x + edge.end.x) / 2,
                                  y: (edge.start.y + edge.end.y) / 2)
                let size = measure(edge.label, size: 10.5)
                let pad: CGFloat = 3
                context.setFillColor(resolvedCGColor(theme.canvas))
                context.fill(CGRect(
                    x: mid.x - size.width / 2 - pad, y: mid.y - size.height / 2 - pad,
                    width: size.width + pad * 2, height: size.height + pad * 2
                ))
                drawText(edge.label, center: mid, size: 10.5, color: theme.secondaryTextColor, in: context)
            }
        }

        for box in layout.boxes {
            context.saveGState()
            context.setFillColor(resolvedCGColor(fill))
            context.setStrokeColor(resolvedCGColor(stroke))
            context.setLineWidth(1)
            let path = CGPath(roundedRect: box.frame, cornerWidth: 4, cornerHeight: 4, transform: nil)
            context.addPath(path)
            context.drawPath(using: .fillStroke)
            context.restoreGState()

            drawText(box.name,
                     center: CGPoint(x: box.frame.midX, y: box.frame.minY + box.nameHeight / 2),
                     size: 12, weight: .semibold, color: theme.ink, in: context)

            if !box.attributes.isEmpty {
                var rowY = box.frame.minY + box.nameHeight
                context.saveGState()
                context.setStrokeColor(resolvedCGColor(hairline))
                context.setLineWidth(1)
                context.beginPath()
                context.move(to: CGPoint(x: box.frame.minX, y: rowY))
                context.addLine(to: CGPoint(x: box.frame.maxX, y: rowY))
                context.strokePath()
                context.restoreGState()

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

    /// Crow's-foot notation drawn along the edge at `end`, oriented away
    /// from `other`: ticks for "one", a circle for "zero", three prongs
    /// for "many".
    private static func drawCardinality(
        _ card: ERDiagram.Cardinality, at end: CGPoint, from other: CGPoint,
        color: PlatformColor, in context: CGContext
    ) {
        let angle = atan2(other.y - end.y, other.x - end.x) // pointing inward
        func point(out: CGFloat, side: CGFloat) -> CGPoint {
            CGPoint(
                x: end.x + out * cos(angle) - side * sin(angle),
                y: end.y + out * sin(angle) + side * cos(angle)
            )
        }

        context.saveGState()
        context.setStrokeColor(resolvedCGColor(color))
        context.setLineWidth(1)
        context.beginPath()

        switch card {
        case .one:
            // Two ticks.
            for out in [CGFloat(6), 10] {
                context.move(to: point(out: out, side: 5))
                context.addLine(to: point(out: out, side: -5))
            }
        case .zeroOrOne:
            context.move(to: point(out: 6, side: 5))
            context.addLine(to: point(out: 6, side: -5))
            context.strokePath()
            context.beginPath()
            let center = point(out: 13, side: 0)
            context.addEllipse(in: CGRect(x: center.x - 3.5, y: center.y - 3.5, width: 7, height: 7))
        case .oneOrMore:
            // Crow's foot at the box plus a tick behind it.
            context.move(to: point(out: 8, side: 0))
            context.addLine(to: point(out: 0, side: 6))
            context.move(to: point(out: 8, side: 0))
            context.addLine(to: point(out: 0, side: 0))
            context.move(to: point(out: 8, side: 0))
            context.addLine(to: point(out: 0, side: -6))
            context.move(to: point(out: 12, side: 5))
            context.addLine(to: point(out: 12, side: -5))
        case .zeroOrMore:
            context.move(to: point(out: 8, side: 0))
            context.addLine(to: point(out: 0, side: 6))
            context.move(to: point(out: 8, side: 0))
            context.addLine(to: point(out: 0, side: 0))
            context.move(to: point(out: 8, side: 0))
            context.addLine(to: point(out: 0, side: -6))
            context.strokePath()
            context.beginPath()
            let center = point(out: 12 + 3.5, side: 0)
            context.addEllipse(in: CGRect(x: center.x - 3.5, y: center.y - 3.5, width: 7, height: 7))
        }
        context.strokePath()
        context.restoreGState()
    }
}
#endif
