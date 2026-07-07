import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif

/// Geometry for a `block-beta` diagram: a uniform grid of block frames plus
/// orthogonally-routed edges between their borders. Pure geometry — the
/// renderer only draws.
public struct BlockLayout: Sendable {
    public struct Node: Sendable {
        public let frame: CGRect
        public let label: String
        public let shape: BlockDiagram.Shape
        /// Palette index (by grid row) for a subtle categorical tint.
        public let colorIndex: Int
        public init(frame: CGRect, label: String, shape: BlockDiagram.Shape, colorIndex: Int) {
            self.frame = frame
            self.label = label
            self.shape = shape
            self.colorIndex = colorIndex
        }
    }

    public struct Edge: Sendable {
        /// Border-to-border route; the arrowhead sits at the last point.
        public let points: [CGPoint]
        public let label: String?
        public init(points: [CGPoint], label: String?) {
            self.points = points
            self.label = label
        }
    }

    public let size: CGSize
    public let nodes: [Node]
    public let edges: [Edge]

    public init(size: CGSize, nodes: [Node], edges: [Edge]) {
        self.size = size
        self.nodes = nodes
        self.edges = edges
    }
}

extension DiagramLayoutEngine {

    public static func layout(_ diagram: BlockDiagram, measure: DiagramTextMeasurer) -> BlockLayout {
        let margin: CGFloat = 18
        let gapX: CGFloat = 30
        let gapY: CGFloat = 42
        let cellHeight: CGFloat = 46

        let cols = min(max(1, diagram.columns), 12)

        // A uniform cell width sized to the widest label (clamped) keeps grid
        // centers regular so orthogonal edges align.
        var widest: CGFloat = 0
        for block in diagram.blocks where block.shape != .space {
            widest = max(widest, measure(block.label, nodeFontSize).width)
        }
        let cellWidth = min(max(widest + 30, 96), 220)

        let count = diagram.blocks.count
        let rows = max(1, Int((Double(count) / Double(cols)).rounded(.up)))

        func frame(atIndex i: Int) -> CGRect {
            let col = i % cols
            let row = i / cols
            return CGRect(
                x: margin + CGFloat(col) * (cellWidth + gapX),
                y: margin + CGFloat(row) * (cellHeight + gapY),
                width: cellWidth, height: cellHeight
            )
        }

        var nodes: [BlockLayout.Node] = []
        var frameByID: [String: CGRect] = [:]
        for (i, block) in diagram.blocks.enumerated() {
            let f = frame(atIndex: i)
            if block.shape != .space {
                nodes.append(BlockLayout.Node(
                    frame: f, label: block.label, shape: block.shape, colorIndex: i / cols
                ))
                if frameByID[block.id] == nil { frameByID[block.id] = f }
            }
        }

        // Orthogonal border-to-border routing between grid cells.
        func route(_ a: CGRect, _ b: CGRect) -> [CGPoint] {
            let aC = CGPoint(x: a.midX, y: a.midY)
            let bC = CGPoint(x: b.midX, y: b.midY)
            if abs(aC.y - bC.y) < 1 {
                return bC.x >= aC.x
                    ? [CGPoint(x: a.maxX, y: aC.y), CGPoint(x: b.minX, y: bC.y)]
                    : [CGPoint(x: a.minX, y: aC.y), CGPoint(x: b.maxX, y: bC.y)]
            }
            if abs(aC.x - bC.x) < 1 {
                return bC.y >= aC.y
                    ? [CGPoint(x: aC.x, y: a.maxY), CGPoint(x: bC.x, y: b.minY)]
                    : [CGPoint(x: aC.x, y: a.minY), CGPoint(x: bC.x, y: b.maxY)]
            }
            // Elbow: leave A vertically, then approach B horizontally.
            let start = CGPoint(x: aC.x, y: bC.y > aC.y ? a.maxY : a.minY)
            let corner = CGPoint(x: aC.x, y: bC.y)
            let end = CGPoint(x: bC.x > aC.x ? b.minX : b.maxX, y: bC.y)
            return [start, corner, end]
        }

        var edges: [BlockLayout.Edge] = []
        for edge in diagram.edges {
            guard let a = frameByID[edge.from], let b = frameByID[edge.to] else { continue }
            edges.append(BlockLayout.Edge(points: route(a, b), label: edge.label))
        }

        let width = margin * 2 + CGFloat(cols) * cellWidth + CGFloat(cols - 1) * gapX
        let height = margin * 2 + CGFloat(rows) * cellHeight + CGFloat(rows - 1) * gapY
        return BlockLayout(
            size: CGSize(width: min(max(width, 120), 3800),
                         height: min(max(height, 80), 3800)),
            nodes: nodes,
            edges: edges
        )
    }
}
