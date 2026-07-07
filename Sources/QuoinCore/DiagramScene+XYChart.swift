import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif

extension DiagramScene {
    static func from(_ layout: XYChartLayout) -> DiagramScene {
        // A synthesized frame for a label stored only as a center point.
        func labelFrame(_ text: String, _ center: CGPoint) -> CGRect {
            let w = CGFloat(max(text.count, 1)) * 6
            return CGRect(x: center.x - w / 2, y: center.y - 7, width: w, height: 14)
        }

        // The plot rect is a container: bars sit inside it and lines route
        // across it, so it must be exempt from overlap/occlusion checks.
        var nodes: [Node] = [
            Node(id: "plot", frame: layout.plotRect, isContainer: true)
        ]
        // Every bar is a visible box. Ids are stable per series+slot.
        for (i, bar) in layout.bars.enumerated() {
            // A bar is a data mark, not an obstacle: a line series legitimately
            // overlays it, so exempt it from occlusion/overlap checks.
            nodes.append(Node(id: "bar-s\(bar.colorIndex)-\(i)", frame: bar.frame, isContainer: true))
        }

        // Line series are genuine polylines over the plot.
        let edges: [Edge] = layout.lines.map { Edge(polyline: $0.points) }

        // Free-standing labels: x categories, y ticks, and axis titles.
        var labels: [Label] = []
        for l in layout.xLabels {
            labels.append(Label(text: l.text, frame: labelFrame(l.text, l.center)))
        }
        for l in layout.yLabels {
            labels.append(Label(text: l.text, frame: labelFrame(l.text, l.center)))
        }
        if let t = layout.yAxisTitle {
            labels.append(Label(text: t.text, frame: labelFrame(t.text, t.center)))
        }
        if let t = layout.xAxisTitle {
            labels.append(Label(text: t.text, frame: labelFrame(t.text, t.center)))
        }

        return DiagramScene(
            name: "xychart",
            size: layout.size,
            nodes: nodes,
            edges: edges,
            labels: labels
        )
    }
}
