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
                let center = polylineMidpoint(edge.points)
                let width = DiagramScene.estimatedLabelSize(text).width
                return Label(
                    text: text,
                    frame: CGRect(x: center.x - width / 2, y: center.y - 7,
                                  width: width, height: 14)
                )
            }
        )
    }
}

