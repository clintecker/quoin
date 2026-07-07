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
    static func attachmentString(source: String, theme: DiagramTheme) -> NSAttributedString? {
        guard let diagram = MermaidParser.parse(source) else { return nil }

        let key = "mermaid|\(theme.fingerprint)|\(source)" as NSString
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
            case .timeline(let timeline):
                let layout = DiagramLayoutEngine.layout(timeline, measure: measure)
                size = layout.size
                draw = { context in Self.draw(layout, theme: theme, in: context) }
            case .mindmap(let mindmap):
                let layout = DiagramLayoutEngine.layout(mindmap, measure: measure)
                size = layout.size
                edgePolylines = layout.edges.map { [$0.from, $0.to] }
                draw = { context in Self.draw(layout, theme: theme, in: context) }
            case .journey(let journey):
                let layout = DiagramLayoutEngine.layout(journey, measure: measure)
                size = layout.size
                draw = { context in Self.draw(layout, theme: theme, in: context) }
            case .quadrant(let quadrant):
                let layout = DiagramLayoutEngine.layout(quadrant, measure: measure)
                size = layout.size
                draw = { context in Self.draw(layout, theme: theme, in: context) }
            case .packet(let packet):
                let layout = DiagramLayoutEngine.layout(packet, measure: measure)
                size = layout.size
                draw = { context in Self.draw(layout, theme: theme, in: context) }
            case .xychart(let chart):
                let layout = DiagramLayoutEngine.layout(chart, measure: measure)
                size = layout.size
                draw = { context in Self.draw(layout, theme: theme, in: context) }
            case .kanban(let board):
                let layout = DiagramLayoutEngine.layout(board, measure: measure)
                size = layout.size
                draw = { context in Self.draw(layout, theme: theme, in: context) }
            case .radar(let radar):
                let layout = DiagramLayoutEngine.layout(radar, measure: measure)
                size = layout.size
                draw = { context in Self.draw(layout, theme: theme, in: context) }
            case .treemap(let treemap):
                let layout = DiagramLayoutEngine.layout(treemap, measure: measure)
                size = layout.size
                draw = { context in Self.draw(layout, theme: theme, in: context) }
            case .gitGraph(let graph):
                let layout = DiagramLayoutEngine.layout(graph, measure: measure)
                size = layout.size
                edgePolylines = layout.edges.map { [$0.from, $0.to] }
                draw = { context in Self.draw(layout, theme: theme, in: context) }
            case .sankey(let d):
                let layout = DiagramLayoutEngine.layout(d, measure: measure)
                size = layout.size
                draw = { context in Self.draw(layout, theme: theme, in: context) }
            case .requirement(let d):
                let layout = DiagramLayoutEngine.layout(d, measure: measure)
                size = layout.size
                draw = { context in Self.draw(layout, theme: theme, in: context) }
            case .zenuml(let d):
                let layout = DiagramLayoutEngine.layout(d, measure: measure)
                size = layout.size
                draw = { context in Self.draw(layout, theme: theme, in: context) }
            case .c4(let d):
                let layout = DiagramLayoutEngine.layout(d, measure: measure)
                size = layout.size
                draw = { context in Self.draw(layout, theme: theme, in: context) }
            case .architecture(let d):
                let layout = DiagramLayoutEngine.layout(d, measure: measure)
                size = layout.size
                draw = { context in Self.draw(layout, theme: theme, in: context) }
            case .block(let d):
                let layout = DiagramLayoutEngine.layout(d, measure: measure)
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

    // MARK: - Pie

    // MARK: - Gantt

    static let labelSize: CGFloat = 10.5

}
#endif
