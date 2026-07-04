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
            // Edge polylines whose routes or endpoint markers can reach past the
            // layout's own `size`; folded into the content bounds below so they
            // never clip. Self-contained types (pie/sequence/gantt) leave this
            // empty — their `size` already covers everything they draw.
            var edgePolylines: [[CGPoint]] = []
            switch diagram {
            case .flowchart(let chart):
                let layout = DiagramLayoutEngine.layout(chart, measure: measure)
                size = layout.size
                edgePolylines = layout.edges.map(\.points)
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
                edgePolylines = layout.edges.map(\.points)
                draw = { context in Self.draw(layout, theme: theme, in: context) }
            case .er(let er):
                let layout = DiagramLayoutEngine.layout(er, measure: measure)
                size = layout.size
                edgePolylines = layout.edges.map(\.points)
                draw = { context in Self.draw(layout, theme: theme, in: context) }
            case .state(let state):
                let layout = DiagramLayoutEngine.layout(state, measure: measure)
                size = layout.size
                edgePolylines = layout.edges.map(\.points)
                draw = { context in Self.draw(layout, theme: theme, in: context) }
            case .gantt(let gantt):
                let layout = DiagramLayoutEngine.layout(gantt, measure: measure)
                size = layout.size
                draw = { context in Self.draw(layout, theme: theme, in: context) }
            }
            guard size.width > 0, size.height > 0, size.width < 4000, size.height < 4000 else { return nil }

            // The true drawn bounds: the layout's `size` (which covers boxes and
            // clamped labels) unioned with every edge point inflated by the
            // maximum marker reach — crow's feet, UML markers, and arrowheads
            // reach inward along the edge (already spanned) but spread a few
            // points perpendicular, so a uniform inflate of the route points
            // captures them. Translating to this box's origin also rescues any
            // route that ran to a negative coordinate.
            let bounds = contentBounds(size: size, edges: edgePolylines)
            guard bounds.width < 4000, bounds.height < 4000 else { return nil }
            let pad: CGFloat = 6
            let canvasSize = CGSize(width: bounds.width + pad * 2, height: bounds.height + pad * 2)
            let originX = pad - bounds.minX
            let originY = pad - bounds.minY

            #if canImport(AppKit)
            let appearance = NSAppearance(named: theme.prefersDark ? .darkAqua : .aqua)
            let image = NSImage(size: canvasSize, flipped: true) { _ in
                guard let context = NSGraphicsContext.current?.cgContext else { return false }
                context.translateBy(x: originX, y: originY)
                let render = { draw(context) }
                if let appearance {
                    appearance.performAsCurrentDrawingAppearance(render)
                } else {
                    render()
                }
                return true
            }
            #else
            let renderer = UIGraphicsImageRenderer(size: canvasSize)
            let image = renderer.image { rendererContext in
                rendererContext.cgContext.translateBy(x: originX, y: originY)
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

        // Batch edge shafts by dash style and stroke each group in a single
        // pass, so crossing edges composite as one region instead of stacking
        // their translucent strokes into darker seams. Arrowheads and labels
        // draw on top afterward.
        var solidShafts: [[CGPoint]] = []
        var dashedShafts: [[CGPoint]] = []
        var arrows: [(tip: CGPoint, from: CGPoint)] = []
        for edge in layout.edges {
            // Leave a small gap between an arrowhead and the box it points at.
            var points = edge.points
            let approach = points.count > 1 ? points[points.count - 2] : edge.start
            if edge.hasArrow, points.count >= 2 {
                let end = points[points.count - 1]
                let dx = end.x - approach.x, dy = end.y - approach.y
                let len = max(hypot(dx, dy), 0.001)
                let gap: CGFloat = 3
                points[points.count - 1] = CGPoint(x: end.x - dx / len * gap, y: end.y - dy / len * gap)
                arrows.append((points[points.count - 1], approach))
            }
            if edge.dashed { dashedShafts.append(points) } else { solidShafts.append(points) }
        }

        func strokeGroup(_ shafts: [[CGPoint]], dashed: Bool) {
            guard !shafts.isEmpty else { return }
            context.saveGState()
            context.setStrokeColor(resolvedCGColor(stroke))
            context.setLineWidth(1)
            if dashed { context.setLineDash(phase: 0, lengths: [4, 3]) }
            context.beginPath()
            for shaft in shafts { appendRoundedPolyline(shaft, to: context) }
            context.strokePath()
            context.restoreGState()
        }
        strokeGroup(solidShafts, dashed: false)
        strokeGroup(dashedShafts, dashed: true)

        for arrow in arrows {
            drawArrowhead(at: arrow.tip, from: arrow.from, color: stroke, canvas: theme.canvas, in: context)
        }
        for edge in layout.edges {
            guard let label = edge.label, !label.isEmpty else { continue }
            let point = edge.labelPoint ?? polylineMidpoint(edge.points)
            drawEdgeLabel(label, at: point, theme: theme, in: context)
        }

        for node in layout.nodes {
            context.saveGState()
            context.setFillColor(resolvedCGColor(fill))
            context.setStrokeColor(resolvedCGColor(stroke))
            context.setLineWidth(1)

            // State-diagram terminals draw specially: a filled dot and a
            // ringed dot, in ink rather than the accent tint.
            if node.shape == .stateStart {
                drawStartTerminal(node.frame, color: theme.ink.withAlphaComponent(0.75), in: context)
                context.restoreGState()
                continue
            }
            if node.shape == .stateEnd {
                drawEndTerminal(node.frame, color: theme.ink.withAlphaComponent(0.75), in: context)
                context.restoreGState()
                continue
            }
            if node.shape == .cylinder {
                context.restoreGState()
                let capH = drawCylinder(node.frame, fill: fill, stroke: stroke, in: context)
                // Center the label in the body, below the top cap.
                drawText(node.label, center: CGPoint(x: node.frame.midX, y: node.frame.midY + capH / 2),
                         size: 12, weight: .medium, color: theme.ink, in: context)
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
                path = diamondPath(node.frame)
            case .cylinder: // handled above with a continue; keep exhaustive
                path = CGPath(roundedRect: node.frame, cornerWidth: 4, cornerHeight: 4, transform: nil)
            }
            context.restoreGState()
            fillStrokeShape(path, fill: fill, stroke: stroke, in: context)

            drawText(node.label, center: CGPoint(x: node.frame.midX, y: node.frame.midY),
                     size: 12, weight: .medium, color: theme.ink, in: context)
        }
    }

    /// Strokes an orthogonal polyline with lightly rounded corners so elbows
    /// read as intentional turns, not kinks. Assumes the caller has set the
    /// stroke colour / width / dash.
    private static func strokePolyline(_ points: [CGPoint], in context: CGContext) {
        guard points.count >= 2 else { return }
        context.beginPath()
        appendRoundedPolyline(points, to: context)
        context.strokePath()
    }

    /// Strokes a set of edge shafts, batching by dash style so each group is a
    /// single composite stroke — crossing edges then don't stack their
    /// translucent strokes into darker seams. Each entry is (polyline, dashed).
    private static func strokeEdgeShafts(
        _ shafts: [(points: [CGPoint], dashed: Bool)], color: PlatformColor, in context: CGContext
    ) {
        for dashed in [false, true] {
            let group = shafts.filter { $0.dashed == dashed }
            guard !group.isEmpty else { continue }
            context.saveGState()
            context.setStrokeColor(resolvedCGColor(color))
            context.setLineWidth(1)
            if dashed { context.setLineDash(phase: 0, lengths: [4, 3]) }
            context.beginPath()
            for shaft in group { appendRoundedPolyline(shaft.points, to: context) }
            context.strokePath()
            context.restoreGState()
        }
    }

    /// Appends a rounded polyline as a new subpath *without* stroking, so many
    /// edges can be accumulated into one path and stroked in a single pass.
    /// A single stroke composites overlapping segments as one region, so
    /// crossing edges don't stack their alpha into darker seams.
    private static func appendRoundedPolyline(_ points: [CGPoint], to context: CGContext) {
        guard points.count >= 2 else { return }
        context.move(to: points[0])
        if points.count > 2 {
            for index in 1..<(points.count - 1) {
                let prev = points[index - 1], corner = points[index], next = points[index + 1]
                let inLen = hypot(corner.x - prev.x, corner.y - prev.y)
                let outLen = hypot(next.x - corner.x, next.y - corner.y)
                // Clamp the corner radius so neither arc consumes more than half
                // of its adjacent segment. Two corners share a middle segment, so
                // capping each at half its length keeps their arcs from eating
                // past each other and pinching into a cusp on short jogs.
                let radius = min(5, inLen / 2, outLen / 2)
                context.addArc(tangent1End: corner, tangent2End: next, radius: radius)
            }
        }
        context.addLine(to: points.last!)
    }

    /// Point at `fraction` of the arc length along the polyline (0 = start,
    /// 1 = end). `0.5` is the midpoint where an edge label sits by default;
    /// other fractions let sibling labels slide apart along their edges.
    private static func polylinePoint(_ points: [CGPoint], fraction: CGFloat) -> CGPoint {
        guard points.count > 1 else { return points.first ?? .zero }
        var total: CGFloat = 0
        for i in 1..<points.count { total += hypot(points[i].x - points[i-1].x, points[i].y - points[i-1].y) }
        var remaining = total * min(max(fraction, 0), 1)
        for i in 1..<points.count {
            let seg = hypot(points[i].x - points[i-1].x, points[i].y - points[i-1].y)
            if remaining <= seg || i == points.count - 1 {
                let t = seg == 0 ? 0 : remaining / seg
                return CGPoint(x: points[i-1].x + (points[i].x - points[i-1].x) * t,
                               y: points[i-1].y + (points[i].y - points[i-1].y) * t)
            }
            remaining -= seg
        }
        return points.last!
    }

    /// Midpoint by arc length along the polyline — where an edge label sits.
    private static func polylineMidpoint(_ points: [CGPoint]) -> CGPoint {
        polylinePoint(points, fraction: 0.5)
    }

    /// The true bounding box of everything a box/flowchart diagram draws: the
    /// layout's own `size` (boxes + clamped labels) unioned with every edge
    /// point inflated by the maximum endpoint-marker reach. Markers point
    /// inward along the edge (already inside the point-to-point span) and only
    /// spread a few points perpendicular, so a uniform inflate captures them
    /// without having to know each marker's exact geometry.
    private static func contentBounds(size: CGSize, edges: [[CGPoint]]) -> CGRect {
        var box = CGRect(origin: .zero, size: size)
        // Widest perpendicular marker spread across all types: the ER crow's
        // foot / zero-circle and the UML triangle sit within this of the line.
        let markerReach: CGFloat = 8
        for points in edges {
            for p in points {
                box = box.union(CGRect(x: p.x - markerReach, y: p.y - markerReach,
                                       width: markerReach * 2, height: markerReach * 2))
            }
        }
        return box
    }

    /// A filled arrowhead at `tip`. The head fills the canvas color first to
    /// erase the shaft beneath it, then the (often translucent) arrow color on
    /// top — otherwise the shaft's alpha adds to the head's and leaves a darker
    /// seam down the middle.
    private static func drawArrowhead(
        at tip: CGPoint, from origin: CGPoint, color: PlatformColor, canvas: PlatformColor, in context: CGContext
    ) {
        let angle = atan2(tip.y - origin.y, tip.x - origin.x)
        let length: CGFloat = 8.5
        let spread: CGFloat = 0.40
        let path = CGMutablePath()
        path.move(to: tip)
        path.addLine(to: CGPoint(x: tip.x - length * cos(angle - spread), y: tip.y - length * sin(angle - spread)))
        path.addLine(to: CGPoint(x: tip.x - length * cos(angle + spread), y: tip.y - length * sin(angle + spread)))
        path.closeSubpath()

        context.saveGState()
        context.setFillColor(resolvedCGColor(canvas))
        context.addPath(path)
        context.fillPath()
        context.setFillColor(resolvedCGColor(color))
        context.addPath(path)
        context.fillPath()
        context.restoreGState()
    }

    // MARK: - Shared drawing primitives

    /// Draws an edge label centered on `mid` over a canvas-colored pad so the
    /// routed line doesn't show through. Callers pick `mid` themselves — the
    /// flowchart uses an index midpoint, box diagrams use `polylineMidpoint`.
    /// Picks an anchor for an edge label that avoids the node boxes and any
    /// labels already placed — the draw-time counterpart of the flowchart
    /// layout's placement pass, for the box diagrams (class/ER/state) whose
    /// layouts don't compute a labelPoint. Scores segment midpoints plus small
    /// sideways nudges by overlap and keeps the cheapest; records the choice in
    /// `placed` so sibling labels spread apart.
    private static func labelAnchor(
        for points: [CGPoint], label: String, bounds: CGSize,
        obstacles: [CGRect], placed: inout [CGRect]
    ) -> CGPoint {
        let size = measure(label, size: 10.5)
        let w = size.width + 6, h = size.height + 2
        // Keep the whole label inside the canvas so a sideways nudge can't push
        // it off the edge and clip.
        func clampX(_ x: CGFloat) -> CGFloat { min(max(x, w / 2), max(w / 2, bounds.width - w / 2)) }
        func clampY(_ y: CGFloat) -> CGFloat { min(max(y, h / 2), max(h / 2, bounds.height - h / 2)) }
        func overlap(_ r1: CGRect, _ r2: CGRect) -> CGFloat {
            let ix = max(0, min(r1.maxX, r2.maxX) - max(r1.minX, r2.minX))
            let iy = max(0, min(r1.maxY, r2.maxY) - max(r1.minY, r2.minY))
            return ix * iy
        }
        // Reserve the marker/arrowhead zone near each endpoint so a label's
        // opaque pad can't cover a crow's-foot, tick, UML marker, or arrowhead:
        // ER crow's feet / zero-circles reach ~18pt off a border and spread a
        // few points to the side, so a 20pt-radius keep-out clears them.
        var obstacles = obstacles
        for end in [points.first, points.last].compactMap({ $0 }) {
            obstacles.append(CGRect(x: end.x - 20, y: end.y - 20, width: 40, height: 40))
        }
        // Sample along the edge's arc length, not just at the midpoint, so two
        // antiparallel edges between the same box pair can slide their labels
        // apart along their lines instead of stacking into one phrase. Each
        // sample is also nudged sideways to clear a box or a sibling label.
        let fractions: [CGFloat] = [0.5, 0.38, 0.62, 0.27, 0.73]
        let nudges: [CGFloat] = [0, w / 2 + 5, -(w / 2 + 5), w + 9, -(w + 9)]
        let mid = polylineMidpoint(points)
        var best = CGPoint(x: clampX(mid.x), y: clampY(mid.y))
        var bestScore = CGFloat.greatestFiniteMagnitude
        for f in fractions {
            let base = polylinePoint(points, fraction: f)
            for dx in nudges {
                let cx = clampX(base.x + dx)
                let cy = clampY(base.y)
                let rect = CGRect(x: cx - w / 2, y: cy - h / 2, width: w, height: h)
                // Prefer the midpoint and the line itself; but let real overlap
                // (a box, or a sibling label) easily outvote those preferences.
                var score: CGFloat = abs(dx) * 0.15 + abs(f - 0.5) * 18
                for o in obstacles { score += overlap(rect, o.insetBy(dx: -3, dy: -3)) * 4 }
                for p in placed { score += overlap(rect, p.insetBy(dx: -4, dy: -4)) * 6 }
                if score < bestScore { bestScore = score; best = CGPoint(x: cx, y: cy) }
            }
        }
        placed.append(CGRect(x: best.x - w / 2, y: best.y - h / 2, width: w, height: h))
        return best
    }

    private static func drawEdgeLabel(_ label: String, at mid: CGPoint, theme: Theme, in context: CGContext) {
        let size = measure(label, size: 10.5)
        let pad: CGFloat = 3
        context.setFillColor(resolvedCGColor(theme.canvas))
        context.fill(CGRect(
            x: mid.x - size.width / 2 - pad, y: mid.y - size.height / 2 - pad,
            width: size.width + pad * 2, height: size.height + pad * 2
        ))
        drawText(label, center: mid, size: 10.5, color: theme.secondaryTextColor, in: context)
    }

    /// Fills a node/box shape and strokes its border — the shared body for
    /// every diagram shape (rectangle, diamond, stadium, circle) so they stay
    /// visually consistent across flowchart, class, ER, and state diagrams.
    private static func fillStrokeShape(
        _ path: CGPath, fill: PlatformColor, stroke: PlatformColor, in context: CGContext
    ) {
        context.saveGState()
        context.setFillColor(resolvedCGColor(fill))
        context.setStrokeColor(resolvedCGColor(stroke))
        context.setLineWidth(1)
        context.addPath(path)
        context.drawPath(using: .fillStroke)
        context.restoreGState()
    }

    /// Convenience for the common rounded-rectangle body.
    private static func fillStrokeBox(
        _ frame: CGRect, radius: CGFloat, fill: PlatformColor, stroke: PlatformColor, in context: CGContext
    ) {
        fillStrokeShape(CGPath(roundedRect: frame, cornerWidth: radius, cornerHeight: radius, transform: nil),
                        fill: fill, stroke: stroke, in: context)
    }

    /// State-machine start terminal: a solid filled dot.
    private static func drawStartTerminal(_ frame: CGRect, color: PlatformColor, in context: CGContext) {
        context.setFillColor(resolvedCGColor(color))
        context.fillEllipse(in: frame)
    }

    /// State-machine end terminal: a ring around a solid dot.
    private static func drawEndTerminal(_ frame: CGRect, color: PlatformColor, in context: CGContext) {
        context.setStrokeColor(resolvedCGColor(color))
        context.strokeEllipse(in: frame.insetBy(dx: 1, dy: 1))
        context.setFillColor(resolvedCGColor(color))
        context.fillEllipse(in: frame.insetBy(dx: 4.5, dy: 4.5))
    }

    /// A database cylinder: rectangular body with an elliptical top cap and a
    /// bottom front arc. The silhouette (sides + top-back and bottom-front
    /// arcs) is filled and stroked, then the top's visible front rim is drawn.
    /// Returns the cap half-height so the caller can center the label below it.
    @discardableResult
    private static func drawCylinder(
        _ f: CGRect, fill: PlatformColor, stroke: PlatformColor, in context: CGContext
    ) -> CGFloat {
        let capH = min(f.height * 0.14, 7)
        let bodyTop = f.minY + capH
        let bodyBottom = f.maxY - capH

        let silhouette = CGMutablePath()
        silhouette.move(to: CGPoint(x: f.minX, y: bodyTop))
        silhouette.addLine(to: CGPoint(x: f.minX, y: bodyBottom))
        silhouette.addQuadCurve(to: CGPoint(x: f.maxX, y: bodyBottom),
                                control: CGPoint(x: f.midX, y: bodyBottom + capH * 2)) // front arc
        silhouette.addLine(to: CGPoint(x: f.maxX, y: bodyTop))
        silhouette.addQuadCurve(to: CGPoint(x: f.minX, y: bodyTop),
                                control: CGPoint(x: f.midX, y: bodyTop - capH * 2))     // back arc
        silhouette.closeSubpath()

        context.saveGState()
        context.setFillColor(resolvedCGColor(fill))
        context.addPath(silhouette)
        context.fillPath()
        context.setStrokeColor(resolvedCGColor(stroke))
        context.setLineWidth(1)
        context.addPath(silhouette)
        context.strokePath()

        // The top cap's visible front rim (bulging down into the body).
        let rim = CGMutablePath()
        rim.move(to: CGPoint(x: f.minX, y: bodyTop))
        rim.addQuadCurve(to: CGPoint(x: f.maxX, y: bodyTop),
                         control: CGPoint(x: f.midX, y: bodyTop + capH * 2))
        context.addPath(rim)
        context.strokePath()
        context.restoreGState()
        return capH
    }

    /// Diamond (decision / choice) path inscribed in `f`.
    private static func diamondPath(_ f: CGRect) -> CGPath {
        let p = CGMutablePath()
        p.move(to: CGPoint(x: f.midX, y: f.minY))
        p.addLine(to: CGPoint(x: f.maxX, y: f.midY))
        p.addLine(to: CGPoint(x: f.midX, y: f.maxY))
        p.addLine(to: CGPoint(x: f.minX, y: f.midY))
        p.closeSubpath()
        return p
    }

    /// A self-bracketed horizontal hairline (compartment separators).
    private static func strokeHLine(
        y: CGFloat, from x0: CGFloat, to x1: CGFloat, color: PlatformColor, in context: CGContext
    ) {
        context.saveGState()
        context.setStrokeColor(resolvedCGColor(color))
        context.setLineWidth(1)
        context.beginPath()
        context.move(to: CGPoint(x: x0, y: y))
        context.addLine(to: CGPoint(x: x1, y: y))
        context.strokePath()
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

    // MARK: - Pie

    /// A categorical palette for charts (pie slices, gantt section bands).
    /// More saturated and distinct than the text-highlight pastels so slices
    /// read as separate data series; tuned to sit well on light and dark.
    private static let categoricalPalette: [PlatformColor] = [
        rgbStatic(0x5B8FF9), // blue
        rgbStatic(0x5AD8A6), // green
        rgbStatic(0xF6BD16), // gold
        rgbStatic(0xE8684A), // coral
        rgbStatic(0x6DC8EC), // sky
        rgbStatic(0x9270CA), // purple
    ]

    private static func categoricalColor(_ index: Int) -> PlatformColor {
        categoricalPalette[index % categoricalPalette.count]
    }

    private static func draw(_ layout: PieLayout, theme: Theme, in context: CGContext) {
        if let title = layout.title {
            drawText(title,
                     center: CGPoint(x: layout.center.x, y: layout.center.y - layout.radius - 16),
                     size: 12.5, weight: .semibold, color: theme.ink, in: context)
        }

        // Fill wedges without a per-wedge stroke, then draw one canvas-colored
        // separator per boundary from the hub to the rim. Stroking each wedge
        // outline drew every boundary twice and piled overlapping strokes at
        // the center; a single line per boundary keeps the hub clean.
        for slice in layout.slices {
            context.saveGState()
            context.setFillColor(resolvedCGColor(categoricalColor(slice.colorIndex)))
            context.beginPath()
            context.move(to: layout.center)
            context.addArc(
                center: layout.center, radius: layout.radius,
                startAngle: CGFloat(slice.startAngle), endAngle: CGFloat(slice.endAngle),
                clockwise: false
            )
            context.closePath()
            context.fillPath()
            context.restoreGState()
        }
        context.saveGState()
        context.setStrokeColor(resolvedCGColor(theme.canvas))
        context.setLineWidth(2)
        context.setLineCap(.round)
        for slice in layout.slices {
            context.beginPath()
            context.move(to: layout.center)
            context.addLine(to: CGPoint(
                x: layout.center.x + layout.radius * cos(CGFloat(slice.startAngle)),
                y: layout.center.y + layout.radius * sin(CGFloat(slice.startAngle))
            ))
            context.strokePath()
        }
        context.restoreGState()

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

    // MARK: - Gantt

    private static func draw(_ layout: GanttLayout, theme: Theme, in context: CGContext) {
        if let title = layout.title {
            drawText(title, center: CGPoint(x: layout.size.width / 2, y: 14),
                     size: 12.5, weight: .semibold, color: theme.ink, in: context)
        }

        // Section tint bands behind everything, in the section's palette color.
        for band in layout.sections {
            context.saveGState()
            context.setFillColor(resolvedCGColor(categoricalColor(band.colorIndex).withAlphaComponent(0.10)))
            context.fill(band.frame)
            context.restoreGState()
        }

        // Day grid: hairline verticals with a small index label at the base.
        for tick in layout.ticks {
            context.saveGState()
            context.setStrokeColor(resolvedCGColor(theme.hairline))
            context.setLineWidth(1)
            context.beginPath()
            context.move(to: CGPoint(x: tick.x, y: tick.top))
            context.addLine(to: CGPoint(x: tick.x, y: tick.bottom))
            context.strokePath()
            context.restoreGState()
            drawText(tick.label, center: CGPoint(x: tick.x, y: tick.bottom + 9),
                     size: 9, color: theme.tertiaryTextColor, in: context)
        }

        for bar in layout.bars {
            // Task label, right-aligned into the gutter.
            let measured = measure(bar.label, size: labelSize)
            drawText(bar.label,
                     center: CGPoint(x: bar.labelPoint.x - measured.width / 2, y: bar.labelPoint.y),
                     size: labelSize, color: theme.secondaryTextColor, in: context)

            let fill = ganttFill(bar.status, theme: theme)
            context.saveGState()
            context.setFillColor(resolvedCGColor(fill))
            if bar.isMilestone {
                // A diamond centered in the bar's box.
                let f = bar.frame
                context.beginPath()
                context.move(to: CGPoint(x: f.midX, y: f.minY))
                context.addLine(to: CGPoint(x: f.maxX, y: f.midY))
                context.addLine(to: CGPoint(x: f.midX, y: f.maxY))
                context.addLine(to: CGPoint(x: f.minX, y: f.midY))
                context.closePath()
                context.fillPath()
            } else {
                context.addPath(CGPath(roundedRect: bar.frame, cornerWidth: 3, cornerHeight: 3, transform: nil))
                context.fillPath()
                if bar.status == .critical {
                    context.setStrokeColor(resolvedCGColor(PlatformColor.systemRed))
                    context.setLineWidth(1.5)
                    context.addPath(CGPath(roundedRect: bar.frame.insetBy(dx: 0.75, dy: 0.75),
                                           cornerWidth: 3, cornerHeight: 3, transform: nil))
                    context.strokePath()
                }
            }
            context.restoreGState()
        }
    }

    private static let labelSize: CGFloat = 10.5

    /// Bar fill by task status: active is the full accent, normal a lighter
    /// tint, done a muted ink, critical a warm red.
    private static func ganttFill(_ status: GanttChart.Status, theme: Theme) -> PlatformColor {
        switch status {
        case .normal: return theme.accent.withAlphaComponent(0.55)
        case .active: return theme.accent
        case .done: return theme.ink.withAlphaComponent(0.28)
        case .critical: return PlatformColor.systemRed.withAlphaComponent(0.85)
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

        // Batch shafts by dash style so crossing edges don't stack alpha.
        strokeEdgeShafts(layout.edges.map { ($0.points, $0.kind.dashed) }, color: stroke, in: context)
        var placedLabels: [CGRect] = []
        let obstacles = layout.boxes.map(\.frame)
        for edge in layout.edges {
            let approach = edge.points.count > 1 ? edge.points[edge.points.count - 2] : edge.start
            drawRelationMarker(edge.kind, at: edge.end, from: approach,
                               stroke: stroke, canvas: theme.canvas, in: context)
            if let label = edge.label, !label.isEmpty {
                let at = labelAnchor(for: edge.points, label: label, bounds: layout.size, obstacles: obstacles, placed: &placedLabels)
                drawEdgeLabel(label, at: at, theme: theme, in: context)
            }
        }

        for box in layout.boxes {
            fillStrokeBox(box.frame, radius: 4, fill: fill, stroke: stroke, in: context)

            drawText(box.name,
                     center: CGPoint(x: box.frame.midX, y: box.frame.minY + box.nameHeight / 2),
                     size: 12, weight: .semibold, color: theme.ink, in: context)

            var rowY = box.frame.minY + box.nameHeight
            func separator() {
                strokeHLine(y: rowY, from: box.frame.minX, to: box.frame.maxX, color: hairline, in: context)
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
            drawArrowhead(at: tip, from: origin, color: stroke, canvas: canvas, in: context)
        case .link:
            break
        }
    }

    // MARK: - ER

    private static func draw(_ layout: ERLayout, theme: Theme, in context: CGContext) {
        let stroke = theme.ink.withAlphaComponent(0.35)
        let hairline = theme.ink.withAlphaComponent(0.18)
        let fill = theme.accent.withAlphaComponent(0.06)

        // Batch shafts by dash style so crossing edges don't stack alpha.
        strokeEdgeShafts(layout.edges.map { ($0.points, !$0.identifying) }, color: stroke, in: context)
        var placedLabels: [CGRect] = []
        let obstacles = layout.boxes.map(\.frame)
        for edge in layout.edges {
            let fromApproach = edge.points.count > 1 ? edge.points[1] : edge.end
            let toApproach = edge.points.count > 1 ? edge.points[edge.points.count - 2] : edge.start
            drawCardinality(edge.fromCard, at: edge.start, from: fromApproach, color: stroke, in: context)
            drawCardinality(edge.toCard, at: edge.end, from: toApproach, color: stroke, in: context)

            if !edge.label.isEmpty {
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

    // MARK: - State

    private static func draw(_ layout: StateLayout, theme: Theme, in context: CGContext) {
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
        let obstacles = layout.nodes.map(\.frame)
        for edge in layout.edges {
            let approach = edge.points.count > 1 ? edge.points[edge.points.count - 2] : edge.start
            drawArrowhead(at: edge.end, from: approach, color: stroke, canvas: theme.canvas, in: context)
            if let label = edge.label, !label.isEmpty {
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
    private static func drawCardinality(
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
