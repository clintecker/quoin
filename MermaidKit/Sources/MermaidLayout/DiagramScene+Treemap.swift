import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif

extension DiagramScene {
    /// Lowers a treemap to the common scene IR: leaf cells are plain nodes,
    /// internal group rects are containers, and ids are disambiguated by
    /// depth and position. No edges and no free-standing labels.
    static func from(_ layout: TreemapLayout) -> DiagramScene {
        DiagramScene(
            name: "treemap",
            size: layout.size,
            // One Node per cell. Internal group rects (isLeaf == false) legitimately
            // contain their children, so they are containers and exempt from overlap
            // checks; leaves are ordinary nodes. IDs are disambiguated by depth +
            // position because sibling branches can reuse a label.
            nodes: layout.cells.map { cell in
                Node(
                    id: "\(cell.label)#d\(cell.depth)@\(Int(cell.frame.minX)),\(Int(cell.frame.minY))",
                    frame: cell.frame,
                    isContainer: !cell.isLeaf
                )
            },
            // Treemaps have no connectors.
            edges: [],
            // Each cell's label is centred inside its own rect (implicit in the Node),
            // so there are no free-standing labels to collide.
            labels: []
        )
    }
}
