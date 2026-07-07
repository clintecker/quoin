import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif

extension DiagramScene {
    static func from(_ layout: BlockLayout) -> DiagramScene {
        DiagramScene(
            name: "block",
            size: layout.size,
            nodes: layout.nodes.map { node in
                Node(id: node.label, frame: node.frame, isContainer: false)
            },
            edges: layout.edges.map { edge in
                Edge(polyline: edge.points, label: edge.label)
            },
            labels: layout.edges.compactMap { edge -> Label? in
                guard let text = edge.label, !text.isEmpty,
                      edge.points.count >= 2
                else { return nil }
                // Place the label at the polyline's arc-length midpoint, which
                // sits in a gap channel rather than over a cell.
                let center = midpoint(of: edge.points)
                let width = CGFloat(text.count) * 6
                return Label(
                    text: text,
                    frame: CGRect(x: center.x - width / 2, y: center.y - 7,
                                  width: width, height: 14)
                )
            }
        )
    }
}

/// The point halfway along a polyline by arc length.
private func midpoint(of points: [CGPoint]) -> CGPoint {
    guard let first = points.first else { return .zero }
    var total: CGFloat = 0
    for (a, b) in zip(points, points.dropFirst()) {
        total += hypot(b.x - a.x, b.y - a.y)
    }
    guard total > 0 else { return first }
    var travelled: CGFloat = 0
    for (a, b) in zip(points, points.dropFirst()) {
        let seg = hypot(b.x - a.x, b.y - a.y)
        if travelled + seg >= total / 2 {
            let t = seg > 0 ? (total / 2 - travelled) / seg : 0
            return CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t)
        }
        travelled += seg
    }
    return points[points.count - 1]
}
