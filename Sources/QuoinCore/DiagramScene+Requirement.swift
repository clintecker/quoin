import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif

extension DiagramScene {
    static func from(_ layout: RequirementLayout) -> DiagramScene {
        // Each requirement / element block is a visible box (stereotype + name +
        // detail rows). A box does not *contain* other diagram nodes, so it is a
        // plain node subject to overlap and occlusion checks.
        let nodes = layout.boxes.map { box in
            Node(id: box.name, frame: box.frame, isContainer: false)
        }

        // Each relationship is an orthogonal connector routed through the empty
        // channels between boxes. The verb (satisfies / traces / …) rides the
        // edge as its label.
        let edges = layout.edges.map { edge -> Edge in
            Edge(
                polyline: edge.points,
                label: edge.label.isEmpty ? nil : edge.label
            )
        }

        // Free-standing relationship labels, placed at the route midpoint (by
        // arc length) so the linter can check them for collisions. Clamped to
        // the canvas so a route near an edge doesn't push the label off-canvas.
        let labels: [Label] = layout.edges.compactMap { edge in
            guard !edge.label.isEmpty else { return nil }
            let mid = polylineMidpoint(edge.points)
            let w = CGFloat(edge.label.count) * 6
            var x = mid.x - w / 2
            var yTop = mid.y - 7
            x = max(0, min(x, layout.size.width - w))
            yTop = max(0, min(yTop, layout.size.height - 14))
            return Label(text: edge.label, frame: CGRect(x: x, y: yTop, width: w, height: 14))
        }

        return DiagramScene(
            name: "requirement",
            size: layout.size,
            nodes: nodes,
            edges: edges,
            labels: labels
        )
    }

    /// The point halfway along a polyline by cumulative segment length.
    private static func polylineMidpoint(_ points: [CGPoint]) -> CGPoint {
        guard let first = points.first else { return .zero }
        guard points.count > 1 else { return first }
        var lengths: [CGFloat] = []
        var total: CGFloat = 0
        for (a, b) in zip(points, points.dropFirst()) {
            let d = (b.x - a.x).magnitude + (b.y - a.y).magnitude
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
