import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif

extension DiagramScene {
    static func from(_ layout: ArchitectureLayout) -> DiagramScene {
        var nodes: [DiagramScene.Node] = []

        // Tinted group containers legitimately hold their member services, so
        // they are containers (exempt from overlap/occlusion).
        for (gi, group) in layout.groups.enumerated() {
            let id = group.label.isEmpty ? "group#\(gi)" : group.label
            nodes.append(DiagramScene.Node(id: id, frame: group.frame, isContainer: true))
        }

        // Service boxes and junction dots. Junctions carry no label, so give
        // them a stable synthesized id for reporting.
        for (si, svc) in layout.services.enumerated() {
            let id: String
            if svc.isJunction {
                id = "junction#\(si)"
            } else {
                id = svc.label.isEmpty ? "service#\(si)" : svc.label
            }
            nodes.append(DiagramScene.Node(id: id, frame: svc.frame, isContainer: false))
        }

        // Orthogonal wires; architecture edges carry no labels.
        let edges = layout.edges.map { DiagramScene.Edge(polyline: $0.points, label: nil) }

        return DiagramScene(
            name: "architecture",
            size: layout.size,
            nodes: nodes,
            edges: edges,
            labels: []
        )
    }
}
