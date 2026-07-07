import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif

extension DiagramScene {
    static func from(_ layout: SankeyLayout) -> DiagramScene {
        DiagramScene(
            name: "sankey",
            size: layout.size,
            // Each node is a flow bar; bars never contain other bars.
            nodes: layout.nodes.map { node in
                Node(id: node.label, frame: node.rect, isContainer: false)
            },
            // Each link is a flow band; represent it as its centerline from the
            // source bar's right edge to the target bar's left edge.
            edges: layout.links.map { link in
                let sourceCenter = CGPoint(
                    x: link.sourceTop.x,
                    y: (link.sourceTop.y + link.sourceBottom.y) / 2)
                let targetCenter = CGPoint(
                    x: link.targetTop.x,
                    y: (link.targetTop.y + link.targetBottom.y) / 2)
                return Edge(polyline: [sourceCenter, targetCenter], label: nil)
            },
            // Node labels sit outboard of their bars (not centered on them), so
            // they are free-standing and can collide with neighbouring columns.
            labels: layout.nodes.map { node in
                let w = CGFloat(node.label.count) * 6
                return Label(
                    text: node.label,
                    frame: CGRect(
                        x: node.labelCenter.x - w / 2,
                        y: node.labelCenter.y - 7,
                        width: w,
                        height: 14))
            }
        )
    }
}
