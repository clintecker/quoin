import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif

extension DiagramScene {
    static func from(_ layout: ERLayout) -> DiagramScene {
        // Each entity is a visible box (name compartment + attribute rows). It
        // does not *contain* other diagram nodes, so it is a plain node subject
        // to overlap/occlusion checks.
        let nodes = layout.boxes.map { box in
            Node(id: box.name, frame: box.frame, isContainer: false)
        }

        // Each relationship is an orthogonal route between two entity boxes; the
        // crow's-foot markers live on the first/last segments. The relationship
        // verb rides the edge as its label.
        let edges = layout.edges.map { edge -> Edge in
            Edge(polyline: edge.points, label: edge.label.isEmpty ? nil : edge.label)
        }

        // Free-standing relationship labels, placed at the route midpoint so the
        // linter can check them for collisions with boxes and each other.
        let labels: [Label] = layout.edges.compactMap { edge in
            guard !edge.label.isEmpty else { return nil }
            let mid = midpoint(of: edge.points)
            let w = CGFloat(edge.label.count) * 6
            return Label(
                text: edge.label,
                frame: CGRect(x: mid.x - w / 2, y: mid.y - 7, width: w, height: 14)
            )
        }

        return DiagramScene(
            name: "er",
            size: layout.size,
            nodes: nodes,
            edges: edges,
            labels: labels
        )
    }

    /// The geometric midpoint of an orthogonal polyline by arc length.
    private static func midpoint(of points: [CGPoint]) -> CGPoint {
        guard let first = points.first else { return .zero }
        guard points.count > 1 else { return first }
        var total: CGFloat = 0
        for (a, b) in zip(points, points.dropFirst()) {
            total += hypot(b.x - a.x, b.y - a.y)
        }
        var travelled: CGFloat = 0
        let half = total / 2
        for (a, b) in zip(points, points.dropFirst()) {
            let seg = hypot(b.x - a.x, b.y - a.y)
            if travelled + seg >= half {
                let t = seg > 0 ? (half - travelled) / seg : 0
                return CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t)
            }
            travelled += seg
        }
        return points[points.count / 2]
    }
}