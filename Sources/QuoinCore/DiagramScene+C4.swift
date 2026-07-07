import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif

extension DiagramScene {
    /// Lowers a C4 model layout to the common scene IR. Every element is a
    /// leaf box (boundaries and deployment nodes are flattened away by the
    /// parser, so nothing here is a container). Relationships are straight
    /// border-to-border arrows; their labels are free-standing at the segment
    /// midpoint, where they can collide with boxes or each other.
    static func from(_ layout: C4Layout) -> DiagramScene {
        DiagramScene(
            name: "c4",
            size: layout.size,
            nodes: layout.boxes.enumerated().map { i, box in
                let title = box.titleLines.joined(separator: " ")
                let id = title.isEmpty ? "\(box.stereotype) #\(i)" : title
                return Node(id: id, frame: box.frame, isContainer: false)
            },
            edges: layout.edges.map { edge in
                Edge(polyline: [edge.from, edge.to], label: edge.label)
            },
            labels: layout.edges.compactMap { edge -> Label? in
                guard let text = edge.label, !text.isEmpty else { return nil }
                let center = CGPoint(x: (edge.from.x + edge.to.x) / 2,
                                     y: (edge.from.y + edge.to.y) / 2)
                let w = CGFloat(text.count) * 6
                return Label(text: text,
                             frame: CGRect(x: center.x - w / 2, y: center.y - 7,
                                           width: w, height: 14))
            }
        )
    }
}