import Foundation
#if canImport(CoreGraphics)
// On Apple platforms the CGRect/CGPoint conveniences (midX, init(x:y:…))
// live in CoreGraphics; on Linux swift-corelibs-foundation provides them.
import CoreGraphics
#endif

/// Measures a text label at a font size — injected by the renderer so the
/// layout engines stay platform-free and unit-testable.
public typealias DiagramTextMeasurer = (_ text: String, _ fontSize: Double) -> CGSize

/// Geometry produced by the layout engines; the renderer only draws.
public struct FlowchartLayout: Sendable {
    public struct PlacedNode: Sendable {
        public let id: String
        public let label: String
        public let shape: Flowchart.NodeShape
        public let frame: CGRect
    }

    public struct PlacedEdge: Sendable {
        public let start: CGPoint
        public let end: CGPoint
        /// Full polyline route (orthogonal between offset nodes); always
        /// begins at `start` and ends at `end`.
        public let points: [CGPoint]
        public let label: String?
        public let dashed: Bool
        public let hasArrow: Bool

        public init(start: CGPoint, end: CGPoint, points: [CGPoint]? = nil,
                    label: String?, dashed: Bool, hasArrow: Bool) {
            self.start = start
            self.end = end
            self.points = points ?? [start, end]
            self.label = label
            self.dashed = dashed
            self.hasArrow = hasArrow
        }
    }

    public let size: CGSize
    public let nodes: [PlacedNode]
    public let edges: [PlacedEdge]
}

public struct SequenceLayout: Sendable {
    public struct Head: Sendable {
        public let label: String
        public let frame: CGRect
        public var lifelineX: CGFloat { frame.midX }
    }

    public struct Arrow: Sendable {
        public let fromX: CGFloat
        public let toX: CGFloat
        public let y: CGFloat
        public let text: String
        public let dashed: Bool
        /// Message to the same participant: drawn as a small loop.
        public let isSelfMessage: Bool

        public init(fromX: CGFloat, toX: CGFloat, y: CGFloat, text: String, dashed: Bool, isSelfMessage: Bool = false) {
            self.fromX = fromX
            self.toX = toX
            self.y = y
            self.text = text
            self.dashed = dashed
            self.isSelfMessage = isSelfMessage
        }
    }

    public let size: CGSize
    public let heads: [Head]
    public let lifelineBottom: CGFloat
    public let arrows: [Arrow]
}

public struct PieLayout: Sendable {
    public struct Slice: Sendable {
        public let label: String
        public let value: Double
        public let fraction: Double
        public let startAngle: Double // radians, 12 o'clock = -π/2, clockwise
        public let endAngle: Double
        public let colorIndex: Int
    }

    public let size: CGSize
    public let center: CGPoint
    public let radius: CGFloat
    public let title: String?
    public let slices: [Slice]
    public let legendOrigin: CGPoint
}

public struct ClassLayout: Sendable {
    public struct Box: Sendable {
        public let name: String
        public let attributes: [String]
        public let methods: [String]
        public let frame: CGRect
        /// Height of the name compartment; member rows follow below.
        public let nameHeight: CGFloat
        public let rowHeight: CGFloat
    }

    public struct Edge: Sendable {
        public let start: CGPoint      // at the `from` box border
        public let end: CGPoint        // at the `to` box border, marker here
        /// Orthogonal route from `start` to `end`; first is `start`, last is
        /// `end`. The marker orients along the final segment.
        public let points: [CGPoint]
        public let kind: ClassDiagram.RelationKind
        public let label: String?
    }

    public let size: CGSize
    public let boxes: [Box]
    public let edges: [Edge]
}

public struct ERLayout: Sendable {
    public struct Box: Sendable {
        public let name: String
        public let attributes: [ERDiagram.Attribute]
        public let frame: CGRect
        public let nameHeight: CGFloat
        public let rowHeight: CGFloat
    }

    public struct Edge: Sendable {
        public let start: CGPoint
        public let end: CGPoint
        /// Orthogonal route from `start` to `end`; crow's-foot markers orient
        /// along the first and last segments.
        public let points: [CGPoint]
        public let fromCard: ERDiagram.Cardinality
        public let toCard: ERDiagram.Cardinality
        public let label: String
        public let identifying: Bool
    }

    public let size: CGSize
    public let boxes: [Box]
    public let edges: [Edge]
}

public struct StateLayout: Sendable {
    public enum NodeKind: Sendable { case simple, start, end, choice, fork, join }

    public struct Node: Sendable {
        public let id: String
        public let label: String
        public let kind: NodeKind
        public let frame: CGRect
    }

    /// A composite state's container box. `titleHeight` is the label strip at
    /// the top; children live below it. `depth` (0 = outermost) tints nesting.
    public struct Container: Sendable {
        public let label: String
        public let frame: CGRect
        public let titleHeight: CGFloat
        public let depth: Int
    }

    public struct Edge: Sendable {
        public let start: CGPoint
        public let end: CGPoint
        public let points: [CGPoint]
        public let label: String?
    }

    public let size: CGSize
    public let nodes: [Node]
    public let containers: [Container]
    public let edges: [Edge]
}

// MARK: - Engine

public enum DiagramLayoutEngine {

    public static let nodeFontSize: Double = 12
    public static let labelFontSize: Double = 10.5

    // MARK: Shared box placement

    struct Placement {
        let frames: [String: CGRect]
        let size: CGSize
    }

    /// Back edges (cycle-closing) found by DFS, as indices into `edges`.
    /// Layering must ignore them or a cycle drifts nodes down without bound.
    static func backEdgeIndices(ids: [String], edges: [(String, String)]) -> Set<Int> {
        var adjacency: [String: [Int]] = [:]
        for (index, edge) in edges.enumerated() { adjacency[edge.0, default: []].append(index) }
        var color: [String: Int] = [:]   // 0 = white, 1 = grey (on stack), 2 = black
        var back = Set<Int>()
        func visit(_ id: String) {
            color[id] = 1
            for index in adjacency[id] ?? [] {
                let target = edges[index].1
                switch color[target] ?? 0 {
                case 1: back.insert(index)          // edge into an ancestor → back edge
                case 0: visit(target)
                default: break
                }
            }
            color[id] = 2
        }
        for id in ids where (color[id] ?? 0) == 0 { visit(id) }
        return back
    }

    /// Longest-path layering + barycenter ordering for arbitrary sized
    /// boxes, top-down. Shared by the class, ER, and state layouts. Cycles
    /// are made acyclic for layering by ignoring DFS back edges.
    static func layeredPlacement(
        ids: [String],
        sizes: [String: CGSize],
        edges allEdges: [(String, String)],
        layerGap: CGFloat,
        nodeGap: CGFloat,
        margin: CGFloat
    ) -> Placement {
        let backEdges = backEdgeIndices(ids: ids, edges: allEdges)
        let edges = allEdges.enumerated().filter { !backEdges.contains($0.offset) }.map(\.element)

        var layerOf: [String: Int] = [:]
        for id in ids { layerOf[id] = 0 }
        for _ in 0..<(ids.count + 1) {
            var changed = false
            for (from, to) in edges {
                guard let a = layerOf[from], let b = layerOf[to] else { continue }
                if b < a + 1 { layerOf[to] = a + 1; changed = true }
            }
            if !changed { break }
        }

        var layers: [[String]] = []
        let maxLayer = layerOf.values.max() ?? 0
        for index in 0...maxLayer {
            layers.append(ids.filter { layerOf[$0] == index })
        }
        layers.removeAll(where: \.isEmpty)

        var position: [String: Int] = [:]
        func recordPositions() {
            for layer in layers {
                for (i, id) in layer.enumerated() { position[id] = i }
            }
        }
        recordPositions()
        for _ in 0..<2 {
            for index in 1..<max(layers.count, 1) {
                layers[index].sort { a, b in
                    let pa = edges.filter { $0.1 == a }.compactMap { position[$0.0] }
                    let pb = edges.filter { $0.1 == b }.compactMap { position[$0.0] }
                    let ba = pa.isEmpty ? Double(position[a] ?? 0) : Double(pa.reduce(0, +)) / Double(pa.count)
                    let bb = pb.isEmpty ? Double(position[b] ?? 0) : Double(pb.reduce(0, +)) / Double(pb.count)
                    return ba < bb
                }
                recordPositions()
            }
        }

        var frames: [String: CGRect] = [:]
        var y = margin
        var crossExtent: CGFloat = 0
        var layerWidths: [CGFloat] = []
        for layer in layers {
            let total = layer.reduce(CGFloat(0)) { $0 + (sizes[$1]?.width ?? 0) }
                + CGFloat(max(layer.count - 1, 0)) * nodeGap
            layerWidths.append(total)
            crossExtent = max(crossExtent, total)
        }
        for (layerIndex, layer) in layers.enumerated() {
            let layerHeight = layer.map { sizes[$0]?.height ?? 0 }.max() ?? 0
            var x = margin + (crossExtent - layerWidths[layerIndex]) / 2
            for id in layer {
                let size = sizes[id] ?? .zero
                frames[id] = CGRect(x: x, y: y, width: size.width, height: size.height)
                x += size.width + nodeGap
            }
            y += layerHeight + layerGap
        }

        return Placement(
            frames: frames,
            size: CGSize(width: crossExtent + margin * 2, height: y - layerGap + margin)
        )
    }

    // MARK: Orthogonal routing for layered box diagrams (class, ER)

    enum BoxFace { case top, bottom, left, right }

    /// One routed edge: the orthogonal polyline plus the faces it attaches to.
    struct RoutedBoxEdge {
        let points: [CGPoint]
    }

    /// Routes edges between layered boxes as clean right-angled elbows with
    /// per-face fan-out: every edge leaving (or entering) the same face gets
    /// its own attachment slot, ordered by the opposite endpoint's cross
    /// coordinate so sibling lines fan out instead of crossing. Vertical
    /// neighbours attach top↔bottom; side-by-side boxes attach left↔right.
    /// Shared by the class and ER layouts so both read the same way.
    static func routeBoxEdges(
        frames: [CGRect],
        pairs: [(from: Int, to: Int)]
    ) -> [RoutedBoxEdge] {
        // Choose a face pair for each edge from the boxes' relative position.
        struct Plan { var fromFace: BoxFace; var toFace: BoxFace }
        var plans: [Plan] = []
        // Attachment requests bucketed per (box, face); each carries a sort key.
        struct Req { let edge: Int; let isStart: Bool; let sortKey: CGFloat }
        var buckets: [String: [Req]] = [:]
        func key(_ box: Int, _ face: BoxFace) -> String { "\(box)#\(face)" }

        for (i, pair) in pairs.enumerated() {
            let a = frames[pair.from], b = frames[pair.to]
            let fromFace: BoxFace, toFace: BoxFace
            if b.minY >= a.maxY {            // b clearly below a
                fromFace = .bottom; toFace = .top
            } else if b.maxY <= a.minY {     // b clearly above a
                fromFace = .top; toFace = .bottom
            } else if b.midX >= a.midX {     // side-by-side, b to the right
                fromFace = .right; toFace = .left
            } else {
                fromFace = .left; toFace = .right
            }
            plans.append(Plan(fromFace: fromFace, toFace: toFace))
            // Sort key = opposite box's coordinate on this face's cross axis.
            let fromKey = (fromFace == .top || fromFace == .bottom) ? b.midX : b.midY
            let toKey = (toFace == .top || toFace == .bottom) ? a.midX : a.midY
            buckets[key(pair.from, fromFace), default: []].append(Req(edge: i, isStart: true, sortKey: fromKey))
            buckets[key(pair.to, toFace), default: []].append(Req(edge: i, isStart: false, sortKey: toKey))
        }

        // Assign each edge its attach point on both faces.
        var starts = [CGPoint](repeating: .zero, count: pairs.count)
        var ends = [CGPoint](repeating: .zero, count: pairs.count)
        for (bucketKey, reqs) in buckets {
            let sorted = reqs.sorted { $0.sortKey < $1.sortKey }
            let n = sorted.count
            // Box + face back out of the key.
            let parts = bucketKey.split(separator: "#")
            let box = frames[Int(parts[0])!]
            let face: BoxFace
            switch parts[1] {
            case "top": face = .top
            case "bottom": face = .bottom
            case "left": face = .left
            default: face = .right
            }
            for (slot, req) in sorted.enumerated() {
                // Spread across the middle 70% of the face; one edge centres.
                let t = n == 1 ? 0.5 : 0.15 + 0.7 * CGFloat(slot) / CGFloat(n - 1)
                let point: CGPoint
                switch face {
                case .top:    point = CGPoint(x: box.minX + box.width * t, y: box.minY)
                case .bottom: point = CGPoint(x: box.minX + box.width * t, y: box.maxY)
                case .left:   point = CGPoint(x: box.minX, y: box.minY + box.height * t)
                case .right:  point = CGPoint(x: box.maxX, y: box.minY + box.height * t)
                }
                if req.isStart { starts[req.edge] = point } else { ends[req.edge] = point }
            }
        }

        // Build the elbow polyline for each edge from its two attach points.
        var routes: [RoutedBoxEdge] = []
        for (i, plan) in plans.enumerated() {
            let s = starts[i], e = ends[i]
            let vertical = (plan.fromFace == .top || plan.fromFace == .bottom)
            var points: [CGPoint]
            if vertical {
                if abs(s.x - e.x) < 0.5 {
                    points = [s, e]
                } else {
                    let midY = (s.y + e.y) / 2
                    points = [s, CGPoint(x: s.x, y: midY), CGPoint(x: e.x, y: midY), e]
                }
            } else {
                if abs(s.y - e.y) < 0.5 {
                    points = [s, e]
                } else {
                    let midX = (s.x + e.x) / 2
                    points = [s, CGPoint(x: midX, y: s.y), CGPoint(x: midX, y: e.y), e]
                }
            }
            routes.append(RoutedBoxEdge(points: points))
        }
        return routes
    }

    /// Intersection of the rect border with the segment from its center
    /// toward `point` — edges attach to borders, not centers.
    static func borderPoint(of rect: CGRect, toward point: CGPoint) -> CGPoint {
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let dx = point.x - center.x
        let dy = point.y - center.y
        guard dx != 0 || dy != 0 else { return center }
        let scaleX = dx != 0 ? (rect.width / 2) / abs(dx) : CGFloat.greatestFiniteMagnitude
        let scaleY = dy != 0 ? (rect.height / 2) / abs(dy) : CGFloat.greatestFiniteMagnitude
        let scale = min(scaleX, scaleY)
        return CGPoint(x: center.x + dx * scale, y: center.y + dy * scale)
    }
}
