import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif

extension DiagramScene {
    static func from(_ layout: RequirementLayout) -> DiagramScene {
        // Each requirement / element block is a visible box (stereotype + name +
        // detail rows). A box does not *contain* other diagram nodes, so it is a
        // plain node subject to overlap and occlusion checks.
        let nodes = layout.boxes.map { box in
            Node(id: box.name, frame: box.frame, isContainer: false)
        }

        // Each relationship is a straight center-to-center connector between two
        // boxes, clipped to the box edges. The verb (satisfies / traces / …)
        // rides the edge as its label.
        let edges = layout.edges.map { edge -> Edge in
            Edge(
                polyline: [edge.from, edge.to],
                label: edge.label.isEmpty ? nil : edge.label
            )
        }

        // Free-standing relationship labels, placed at the segment midpoint so
        // the linter can check them for collisions with boxes and each other.
        let labels: [Label] = layout.edges.compactMap { edge in
            guard !edge.label.isEmpty else { return nil }
            let mid = CGPoint(x: (edge.from.x + edge.to.x) / 2,
                              y: (edge.from.y + edge.to.y) / 2)
            let w = CGFloat(edge.label.count) * 6
            return Label(
                text: edge.label,
                frame: CGRect(x: mid.x - w / 2, y: mid.y - 7, width: w, height: 14)
            )
        }

        return DiagramScene(
            name: "requirement",
            size: layout.size,
            nodes: nodes,
            edges: edges,
            labels: labels
        )
    }
}
