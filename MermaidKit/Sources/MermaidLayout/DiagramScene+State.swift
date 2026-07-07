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
            let mid = polylineMidpoint(poly)
            let w = DiagramScene.estimatedLabelSize(text).width
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

}