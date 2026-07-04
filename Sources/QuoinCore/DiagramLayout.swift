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
        /// Where to center the label — chosen by the layout to avoid boxes and
        /// other labels. nil for an unlabeled edge; the renderer falls back to
        /// the route midpoint if it is somehow absent.
        public let labelPoint: CGPoint?

        public init(start: CGPoint, end: CGPoint, points: [CGPoint]? = nil,
                    label: String?, dashed: Bool, hasArrow: Bool, labelPoint: CGPoint? = nil) {
            self.start = start
            self.end = end
            self.points = points ?? [start, end]
            self.label = label
            self.dashed = dashed
            self.hasArrow = hasArrow
            self.labelPoint = labelPoint
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

public struct GanttLayout: Sendable {
    public struct Bar: Sendable {
        public let label: String
        /// The bar rectangle, or the milestone diamond's bounding box.
        public let frame: CGRect
        /// Right edge of the label gutter at the row's vertical center; the
        /// renderer right-aligns the task label to this point.
        public let labelPoint: CGPoint
        public let isMilestone: Bool
        public let status: GanttChart.Status
    }

    public struct SectionBand: Sendable {
        public let name: String
        /// Full-width tint band spanning the section's consecutive rows.
        public let frame: CGRect
        public let colorIndex: Int
    }

    public struct Tick: Sendable {
        public let x: CGFloat
        public let label: String   // day index
        public let top: CGFloat
        public let bottom: CGFloat
    }

    public let size: CGSize
    public let title: String?
    /// X where the bar area begins (right of the task-label gutter).
    public let labelGutter: CGFloat
    public let bars: [Bar]
    public let sections: [SectionBand]
    public let ticks: [Tick]
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

    /// Longest-path layer assignment: every node starts at layer 0 and each
    /// edge pushes its target at least one layer below its source. `edges`
    /// must be acyclic (cycle back edges removed) so it terminates. Split out
    /// of `orderedLayers` so the flowchart can insert dummy nodes for
    /// multi-layer edges between assignment and ordering.
    static func assignLayers(ids: [String], edges: [(String, String)]) -> [String: Int] {
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
        return layerOf
    }

    /// Barycenter crossing-minimization: repeatedly reorder each layer by the
    /// mean position of each node's predecessors. Empty layers are dropped.
    static func barycenterOrder(
        layers: [[String]], edges: [(String, String)], sweeps: Int = 2
    ) -> [[String]] {
        var layers = layers
        layers.removeAll(where: \.isEmpty)

        // Predecessors precomputed once so the sort comparator is O(1), not
        // an O(E) filter per comparison.
        var predecessors: [String: [String]] = [:]
        for (from, to) in edges { predecessors[to, default: []].append(from) }
        var position: [String: Int] = [:]
        func recordPositions() {
            for layer in layers {
                for (i, id) in layer.enumerated() { position[id] = i }
            }
        }
        func barycenter(_ id: String) -> Double {
            let ps = (predecessors[id] ?? []).compactMap { position[$0] }
            return ps.isEmpty ? Double(position[id] ?? 0)
                              : Double(ps.reduce(0, +)) / Double(ps.count)
        }
        recordPositions()
        for _ in 0..<sweeps {
            for index in 1..<max(layers.count, 1) {
                layers[index].sort { barycenter($0) < barycenter($1) }
                recordPositions()
            }
        }
        return layers
    }

    /// Layered top-down layout with **dummy-node edge routing**, shared by the
    /// class, ER, and state diagrams (the Sugiyama approach the flowchart uses).
    /// Layers come from `layeringEdges` (already oriented by the caller — e.g.
    /// class inheritance flipped so parents sit above children); every routing
    /// edge that spans more than one layer gets dummy nodes in the intervening
    /// layers, so it reserves a channel and runs *between* boxes instead of
    /// elbowing around them. Returns the real-box frames, the canvas size, and
    /// one orthogonal polyline per `routingEdges` entry, in order.
    static func layeredRoutes(
        ids: [String],
        sizes: [String: CGSize],
        layeringEdges: [(String, String)],
        routingEdges: [(from: String, to: String)],
        layerGap: CGFloat,
        nodeGap: CGFloat,
        margin: CGFloat
    ) -> (frames: [String: CGRect], size: CGSize, routes: [[CGPoint]]) {
        let layerBack = backEdgeIndices(ids: ids, edges: layeringEdges)
        let forward = layeringEdges.enumerated().filter { !layerBack.contains($0.offset) }.map(\.element)
        let layerOf = assignLayers(ids: ids, edges: forward)
        let layerCount = (layerOf.values.max() ?? 0) + 1

        // Dummy nodes for every routing edge spanning more than one layer.
        var layers: [[String]] = Array(repeating: [], count: layerCount)
        for id in ids where layerOf[id] != nil { layers[layerOf[id]!].append(id) }
        var allSizes = sizes
        var chains: [[String]] = []
        var segmentEdges: [(String, String)] = []
        for (index, edge) in routingEdges.enumerated() {
            guard let lu = layerOf[edge.from], let lv = layerOf[edge.to] else { chains.append([]); continue }
            let lo = min(lu, lv), hi = max(lu, lv)
            if hi - lo <= 1 {
                chains.append([edge.from, edge.to])
                segmentEdges.append((edge.from, edge.to))
                continue
            }
            var midByLayer: [(layer: Int, id: String)] = []
            for layer in (lo + 1)...(hi - 1) {
                let dummy = "\u{a7}b\(index).\(layer)"
                layers[layer].append(dummy)
                allSizes[dummy] = CGSize(width: 16, height: 1)
                midByLayer.append((layer, dummy))
            }
            let mids = (lu < lv ? midByLayer : midByLayer.reversed()).map(\.id)
            let chain = [edge.from] + mids + [edge.to]
            chains.append(chain)
            for k in 0..<(chain.count - 1) { segmentEdges.append((chain[k], chain[k + 1])) }
        }

        // Order + place (top-down).
        let ordered = barycenterOrder(layers: layers, edges: segmentEdges)
        var frames: [String: CGRect] = [:]
        var y = margin
        var crossExtent: CGFloat = 0
        var layerWidths: [CGFloat] = []
        for layer in ordered {
            let total = layer.reduce(CGFloat(0)) { $0 + (allSizes[$1]?.width ?? 0) }
                + CGFloat(max(layer.count - 1, 0)) * nodeGap
            layerWidths.append(total)
            crossExtent = max(crossExtent, total)
        }
        for (layerIndex, layer) in ordered.enumerated() {
            let layerHeight = layer.map { allSizes[$0]?.height ?? 0 }.max() ?? 0
            var x = margin + (crossExtent - layerWidths[layerIndex]) / 2
            for id in layer {
                let size = allSizes[id] ?? .zero
                frames[id] = CGRect(x: x, y: y, width: size.width, height: size.height)
                x += size.width + nodeGap
            }
            y += layerHeight + layerGap
        }

        // Route each edge through its chain waypoints.
        var routes: [[CGPoint]] = []
        var maxX = crossExtent + margin
        for chain in chains {
            guard chain.count >= 2, let fromFrame = frames[chain[0]], let toFrame = frames[chain[chain.count - 1]] else {
                routes.append([.zero, .zero]); continue
            }
            // Same layer → route the short way through side faces.
            if abs(fromFrame.midY - toFrame.midY) < 1 {
                let right = toFrame.midX >= fromFrame.midX
                let start = CGPoint(x: right ? fromFrame.maxX : fromFrame.minX, y: fromFrame.midY)
                let end = CGPoint(x: right ? toFrame.minX : toFrame.maxX, y: toFrame.midY)
                routes.append([start, end])
                continue
            }
            let dummyCenters = chain[1..<(chain.count - 1)].compactMap { frames[$0].map { CGPoint(x: $0.midX, y: $0.midY) } }
            // Straight column: when the two boxes' x-ranges overlap and there
            // are no dummies to route around, attach both ends at one shared x
            // so the edge is a single straight segment — no tiny S-hook from a
            // near-alignment offset.
            let overlapLo = max(fromFrame.minX, toFrame.minX) + 4
            let overlapHi = min(fromFrame.maxX, toFrame.maxX) - 4
            if dummyCenters.isEmpty, overlapLo <= overlapHi {
                let x = min(max((fromFrame.midX + toFrame.midX) / 2, overlapLo), overlapHi)
                let down = toFrame.midY >= fromFrame.midY
                let start = CGPoint(x: x, y: down ? fromFrame.maxY : fromFrame.minY)
                let end = CGPoint(x: x, y: down ? toFrame.minY : toFrame.maxY)
                for p in [start, end] { maxX = max(maxX, p.x) }
                routes.append([start, end])
                continue
            }
            let firstNext = dummyCenters.first ?? CGPoint(x: toFrame.midX, y: toFrame.midY)
            let lastPrev = dummyCenters.last ?? CGPoint(x: fromFrame.midX, y: fromFrame.midY)
            func attach(_ f: CGRect, towardX: CGFloat, bottom: Bool) -> CGPoint {
                CGPoint(x: min(max(towardX, f.minX + 4), f.maxX - 4), y: bottom ? f.maxY : f.minY)
            }
            let start = attach(fromFrame, towardX: firstNext.x, bottom: firstNext.y >= fromFrame.midY)
            let end = attach(toFrame, towardX: lastPrev.x, bottom: lastPrev.y > toFrame.midY)
            let points = routePolyline([start] + dummyCenters + [end], horizontal: false)
            for p in points { maxX = max(maxX, p.x) }
            routes.append(points)
        }

        let size = CGSize(width: max(crossExtent, maxX - margin) + margin * 2, height: y - layerGap + margin)
        return (frames, size, routes)
    }
}
