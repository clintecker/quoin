import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif

extension DiagramScene {
    static func from(_ layout: StateLayout) -> DiagramScene {
        // Every simple/start/end/choice/fork/join node keeps its exact frame.
        // Layout already sizes point-like nodes (start/end dots, choice/fork/
        // join bars) into real rects, so no synthesis is needed here.
        var nodes: [DiagramScene.Node] = layout.nodes.map { node in
            DiagramScene.Node(id: node.id, frame: node.frame, isContainer: false)
        }
        // A composite state's box legitimately contains its children → container.
        nodes.append(contentsOf: layout.containers.map { container in
            DiagramScene.Node(id: container.label, frame: container.frame, isContainer: true)
        })

        // Transitions: prefer the routed polyline; fall back to the straight
        // start→end segment when the layout stored no waypoints.
        let edges: [DiagramScene.Edge] = layout.edges.map { edge in
            let poly = edge.points.count >= 2 ? edge.points : [edge.start, edge.end]
            return DiagramScene.Edge(polyline: poly, label: edge.label)
        }

        // Free-standing transition labels, centred on the polyline midpoint.
        let labels: [DiagramScene.Label] = layout.edges.compactMap { edge in
            guard let text = edge.label, !text.isEmpty else { return nil }
            let poly = edge.points.count >= 2 ? edge.points : [edge.start, edge.end]
            let mid = midpoint(of: poly)
            let w = CGFloat(text.count) * 6
            return DiagramScene.Label(
                text: text,
                frame: CGRect(x: mid.x - w / 2, y: mid.y - 7, width: w, height: 14)
            )
        }

        return DiagramScene(
            name: "state",
            size: layout.size,
            nodes: nodes,
            edges: edges,
            labels: labels
        )
    }

    /// Midpoint along a polyline by arc length (falls back to the average of
    /// the endpoints for a two-point segment).
    private static func midpoint(of points: [CGPoint]) -> CGPoint {
        guard points.count > 1 else { return points.first ?? .zero }
        if points.count == 2 {
            return CGPoint(x: (points[0].x + points[1].x) / 2,
                           y: (points[0].y + points[1].y) / 2)
        }
        var total: CGFloat = 0
        for (a, b) in zip(points, points.dropFirst()) {
            total += hypot(b.x - a.x, b.y - a.y)
        }
        let half = total / 2
        var run: CGFloat = 0
        for (a, b) in zip(points, points.dropFirst()) {
            let seg = hypot(b.x - a.x, b.y - a.y)
            if run + seg >= half, seg > 0 {
                let t = (half - run) / seg
                return CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t)
            }
            run += seg
        }
        return points[points.count / 2]
    }
}