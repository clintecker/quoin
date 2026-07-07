import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif

extension DiagramScene {
    static func from(_ layout: GitGraphLayout) -> DiagramScene {
        // The real dot radius used by DiagramLayoutEngine.layout(_ :GitGraph:).
        let dotRadius: CGFloat = 7

        // Every commit is a point; synthesise a dot-sized box around its centre.
        let nodes: [DiagramScene.Node] = layout.commits.map { commit in
            DiagramScene.Node(
                id: commit.id,
                frame: CGRect(
                    x: commit.center.x - dotRadius,
                    y: commit.center.y - dotRadius,
                    width: dotRadius * 2,
                    height: dotRadius * 2),
                isContainer: false)
        }

        // Parent→child connectors (branch points and merges included).
        let edges: [DiagramScene.Edge] = layout.edges.map { edge in
            DiagramScene.Edge(polyline: [edge.from, edge.to], label: nil)
        }

        // Free-standing labels: lane (branch-name) labels in the left gutter,
        // plus any commit tags, which float above their dot.
        var labels: [DiagramScene.Label] = layout.laneLabels.map { lane in
            let w = CGFloat(max(lane.name.count, 1)) * 6
            // The lane label point is left-anchored at the gutter margin.
            return DiagramScene.Label(
                text: lane.name,
                frame: CGRect(x: lane.point.x, y: lane.point.y - 7, width: w, height: 14))
        }
        for commit in layout.commits {
            guard let tag = commit.tag, !tag.isEmpty else { continue }
            let w = CGFloat(tag.count) * 6
            labels.append(DiagramScene.Label(
                text: tag,
                frame: CGRect(
                    x: commit.center.x - w / 2,
                    y: commit.center.y - dotRadius - 18,
                    width: w,
                    height: 14)))
        }

        return DiagramScene(
            name: "gitgraph",
            size: layout.size,
            nodes: nodes,
            edges: edges,
            labels: labels
        )
    }
}