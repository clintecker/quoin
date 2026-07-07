import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif

extension DiagramScene {
    /// Lower a laid-out UML class diagram into the common scene IR.
    ///
    /// Each class box becomes a `Node` (its compartments — name / attributes /
    /// methods — are internal chrome, not separate nodes, so a class is one
    /// solid box the linter treats as opaque). Class boxes never *contain*
    /// other boxes, so none is a container. Relations become `Edge`s carrying
    /// their orthogonal route; a relation's multiplicity/role label is a
    /// free-standing `Label` pinned to the route's midpoint so the linter can
    /// catch it colliding with a box or another label.
    static func from(_ layout: ClassLayout) -> DiagramScene {
        let nodes = layout.boxes.map { box in
            Node(id: box.name, frame: box.frame, isContainer: false)
        }

        let edges = layout.edges.map { edge in
            Edge(polyline: edge.points, label: edge.label)
        }

        let labels: [Label] = layout.edges.compactMap { edge in
            guard let text = edge.label, !text.isEmpty else { return nil }
            let center = midpoint(of: edge.points)
            let w = CGFloat(text.count) * 6
            return Label(
                text: text,
                frame: CGRect(x: center.x - w / 2, y: center.y - 7, width: w, height: 14)
            )
        }

        return DiagramScene(
            name: "class",
            size: layout.size,
            nodes: nodes,
            edges: edges,
            labels: labels
        )
    }

    /// Point halfway along a routed polyline by arc length; falls back to the
    /// single endpoint (or origin) for degenerate routes.
    private static func midpoint(of points: [CGPoint]) -> CGPoint {
        guard points.count > 1 else { return points.first ?? .zero }
        var total: CGFloat = 0
        for (a, b) in zip(points, points.dropFirst()) {
            total += hypot(b.x - a.x, b.y - a.y)
        }
        guard total > 0 else { return points[0] }
        var remaining = total / 2
        for (a, b) in zip(points, points.dropFirst()) {
            let len = hypot(b.x - a.x, b.y - a.y)
            if len >= remaining {
                let t = len == 0 ? 0 : remaining / len
                return CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t)
            }
            remaining -= len
        }
        return points[points.count / 2]
    }
}
