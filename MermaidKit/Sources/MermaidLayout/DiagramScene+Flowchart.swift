import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif

extension DiagramScene {
    /// Lowers a flowchart layout to the common scene IR: every placed box is
    /// a plain node (subgraphs are flattened by the parser), connectors keep
    /// their orthogonal routes, and each |label| becomes a free-standing
    /// Label at the layout's labelPoint (endpoint midpoint fallback).
    static func from(_ layout: FlowchartLayout) -> DiagramScene {
        DiagramScene(
            name: "flowchart",
            size: layout.size,
            // One Node per placed box. Flowchart subgraphs are flattened by the
            // parser (v1), so no PlacedNode is a container — every box holds
            // content and must be checked for overlap/occlusion.
            nodes: layout.nodes.map { node in
                Node(id: node.id, frame: node.frame, isContainer: false)
            },
            // One Edge per connector, carrying its full orthogonal route and its
            // optional |label| text.
            edges: layout.edges.map { edge in
                Edge(polyline: edge.points, label: edge.label)
            },
            // Free-standing edge labels only: an edge's centred |label| chip can
            // collide with boxes or other labels. Center at the layout's chosen
            // labelPoint (fall back to the route midpoint, matching the renderer).
            labels: layout.edges.compactMap { edge -> Label? in
                guard let text = edge.label, !text.isEmpty else { return nil }
                let center = edge.labelPoint ?? CGPoint(
                    x: (edge.start.x + edge.end.x) / 2,
                    y: (edge.start.y + edge.end.y) / 2
                )
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
