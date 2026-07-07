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
                      let first = edge.points.first, let last = edge.points.last
                else { return nil }
                let center = CGPoint(x: (first.x + last.x) / 2,
                                     y: (first.y + last.y) / 2)
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
