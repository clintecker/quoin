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

    // MARK: Flowchart (layered / Sugiyama-style)

    public static func layout(_ chart: Flowchart, measure: DiagramTextMeasurer) -> FlowchartLayout {
        let horizontal = chart.direction == .leftRight || chart.direction == .rightLeft

        // 1. Longest-path layering. Back edges (cycles — a state machine's
        // "retry" loop) are excluded so they don't push their target deeper;
        // they still draw, just against the flow.
        var adjacency: [String: [Int]] = [:]
        for (index, edge) in chart.edges.enumerated() {
            adjacency[edge.from, default: []].append(index)
        }
        var backEdges = Set<Int>()
        var visited = Set<String>()
        var onStack = Set<String>()
        func markBackEdges(from id: String) {
            visited.insert(id)
            onStack.insert(id)
            for index in adjacency[id] ?? [] {
                let target = chart.edges[index].to
                if onStack.contains(target) {
                    backEdges.insert(index)
                } else if !visited.contains(target) {
                    markBackEdges(from: target)
                }
            }
            onStack.remove(id)
        }
        for node in chart.nodes where !visited.contains(node.id) {
            markBackEdges(from: node.id)
        }

        var layerOf: [String: Int] = [:]
        for node in chart.nodes { layerOf[node.id] = 0 }
        let maxPasses = chart.nodes.count + 1
        for _ in 0..<maxPasses {
            var changed = false
            for (index, edge) in chart.edges.enumerated() where !backEdges.contains(index) {
                guard let from = layerOf[edge.from], let to = layerOf[edge.to] else { continue }
                if to < from + 1 {
                    layerOf[edge.to] = from + 1
                    changed = true
                }
            }
            if !changed { break }
        }

        var layers: [[Flowchart.Node]] = []
        let maxLayer = layerOf.values.max() ?? 0
        for index in 0...maxLayer {
            layers.append(chart.nodes.filter { layerOf[$0.id] == index })
        }
        layers.removeAll(where: \.isEmpty)

        // 2. Reduce crossings: two barycenter sweeps over predecessors.
        var position: [String: Int] = [:]
        func recordPositions() {
            for layer in layers {
                for (i, node) in layer.enumerated() { position[node.id] = i }
            }
        }
        recordPositions()
        for _ in 0..<2 {
            for index in 1..<max(layers.count, 1) {
                layers[index].sort { a, b in
                    barycenter(of: a.id, edges: chart.edges, position: position)
                        < barycenter(of: b.id, edges: chart.edges, position: position)
                }
                recordPositions()
            }
        }

        // 3. Node sizes from labels.
        let paddingX: CGFloat = 14
        let paddingY: CGFloat = 9
        var sizes: [String: CGSize] = [:]
        for node in chart.nodes {
            let text = measure(node.label, nodeFontSize)
            var size = CGSize(width: text.width + paddingX * 2, height: text.height + paddingY * 2)
            switch node.shape {
            case .diamond:
                size = CGSize(width: size.width * 1.3, height: size.height * 1.5)
            case .circle:
                let d = max(size.width, size.height)
                size = CGSize(width: d, height: d)
            case .stateStart:
                size = CGSize(width: 14, height: 14)
            case .stateEnd:
                size = CGSize(width: 18, height: 18)
            default:
                break
            }
            if node.shape != .stateStart && node.shape != .stateEnd {
                size.width = max(size.width, 56)
            }
            sizes[node.id] = size
        }

        // 4. Coordinates: layers along the main axis, centered on the cross axis.
        let layerGap: CGFloat = 44
        let nodeGap: CGFloat = 26
        let margin: CGFloat = 12

        var frames: [String: CGRect] = [:]
        var mainOffset = margin
        var crossExtent: CGFloat = 0

        var layerCrossSizes: [CGFloat] = []
        for layer in layers {
            let total = layer.reduce(CGFloat(0)) { sum, node in
                sum + (horizontal ? sizes[node.id]!.height : sizes[node.id]!.width)
            } + CGFloat(max(layer.count - 1, 0)) * nodeGap
            layerCrossSizes.append(total)
            crossExtent = max(crossExtent, total)
        }

        for (layerIndex, layer) in layers.enumerated() {
            let mainSize = layer.map { horizontal ? sizes[$0.id]!.width : sizes[$0.id]!.height }.max() ?? 0
            var crossOffset = margin + (crossExtent - layerCrossSizes[layerIndex]) / 2
            for node in layer {
                let size = sizes[node.id]!
                let frame: CGRect
                if horizontal {
                    frame = CGRect(
                        x: mainOffset + (mainSize - size.width) / 2,
                        y: crossOffset,
                        width: size.width, height: size.height
                    )
                    crossOffset += size.height + nodeGap
                } else {
                    frame = CGRect(
                        x: crossOffset,
                        y: mainOffset + (mainSize - size.height) / 2,
                        width: size.width, height: size.height
                    )
                    crossOffset += size.width + nodeGap
                }
                frames[node.id] = frame
            }
            mainOffset += mainSize + layerGap
        }

        // 5. Edges. Forward edges attach at points distributed across each
        // node's face — fanned out by the other endpoint's cross position so
        // sibling edges never share a stub — and projected onto the node's
        // actual outline (diamonds/circles) so they don't float off a
        // bounding-box corner. Back edges (cycles) route around the node band
        // in a private lane so they never overwrite the forward flow.
        let shapeOf = Dictionary(uniqueKeysWithValues: chart.nodes.map { ($0.id, $0.shape) })

        func crossCenter(_ id: String) -> CGFloat {
            horizontal ? frames[id]!.midY : frames[id]!.midX
        }
        var forwardOut: [String: [Int]] = [:]
        var forwardIn: [String: [Int]] = [:]
        for (index, edge) in chart.edges.enumerated() where !backEdges.contains(index) {
            guard frames[edge.from] != nil, frames[edge.to] != nil else { continue }
            forwardOut[edge.from, default: []].append(index)
            forwardIn[edge.to, default: []].append(index)
        }
        for (node, indices) in forwardOut {
            forwardOut[node] = indices.sorted { crossCenter(chart.edges[$0].to) < crossCenter(chart.edges[$1].to) }
        }
        for (node, indices) in forwardIn {
            forwardIn[node] = indices.sorted { crossCenter(chart.edges[$0].from) < crossCenter(chart.edges[$1].from) }
        }
        // Cross-axis coordinate where edge `index` sits on `nodeID`'s face:
        // one edge → centered; N edges → spread across the middle 64%.
        func faceCross(_ nodeID: String, group: [Int]?, index: Int) -> CGFloat {
            let frame = frames[nodeID]!
            let lo = horizontal ? frame.minY : frame.minX
            let span = horizontal ? frame.height : frame.width
            guard let group, group.count > 1, let pos = group.firstIndex(of: index) else {
                return horizontal ? frame.midY : frame.midX
            }
            let inset = span * 0.18
            return lo + inset + (span - inset * 2) * CGFloat(pos) / CGFloat(group.count - 1)
        }
        // Projects a face-cross coordinate onto the node's outline.
        func attachPoint(_ id: String, cross: CGFloat, rightOrBottom: Bool) -> CGPoint {
            let f = frames[id]!
            let shape = shapeOf[id] ?? .rectangle
            if horizontal {
                let y = min(max(cross, f.minY), f.maxY)
                let hw = f.width / 2, hh = max(f.height / 2, 0.001)
                var x = rightOrBottom ? f.maxX : f.minX
                switch shape {
                case .diamond:
                    let dx = hw * (1 - min(abs(y - f.midY) / hh, 1))
                    x = rightOrBottom ? f.midX + dx : f.midX - dx
                case .circle, .stateStart, .stateEnd:
                    let dx = (f.width / 2) * sqrt(max(0, 1 - pow((y - f.midY) / hh, 2)))
                    x = rightOrBottom ? f.midX + dx : f.midX - dx
                default: break
                }
                return CGPoint(x: x, y: y)
            } else {
                let x = min(max(cross, f.minX), f.maxX)
                let hw = max(f.width / 2, 0.001), hh = f.height / 2
                var y = rightOrBottom ? f.maxY : f.minY
                switch shape {
                case .diamond:
                    let dy = hh * (1 - min(abs(x - f.midX) / hw, 1))
                    y = rightOrBottom ? f.midY + dy : f.midY - dy
                case .circle, .stateStart, .stateEnd:
                    let dy = (f.height / 2) * sqrt(max(0, 1 - pow((x - f.midX) / hw, 2)))
                    y = rightOrBottom ? f.midY + dy : f.midY - dy
                default: break
                }
                return CGPoint(x: x, y: y)
            }
        }

        var placedEdges: [FlowchartLayout.PlacedEdge] = []
        let bandMaxCross = frames.values.map { horizontal ? $0.maxY : $0.maxX }.max() ?? 0
        var crossLimit = margin + crossExtent
        var backLane = 0

        for (index, edge) in chart.edges.enumerated() {
            guard let from = frames[edge.from], let to = frames[edge.to] else { continue }
            let start: CGPoint
            let end: CGPoint
            let points: [CGPoint]

            if backEdges.contains(index) {
                // Loop out past the band's far cross edge in a private lane.
                let lane = bandMaxCross + 16 + CGFloat(backLane) * 12
                backLane += 1
                crossLimit = max(crossLimit, lane)
                if horizontal {
                    start = CGPoint(x: from.midX, y: from.maxY)
                    end = CGPoint(x: to.midX, y: to.maxY)
                    points = [start, CGPoint(x: from.midX, y: lane), CGPoint(x: to.midX, y: lane), end]
                } else {
                    start = CGPoint(x: from.maxX, y: from.midY)
                    end = CGPoint(x: to.maxX, y: to.midY)
                    points = [start, CGPoint(x: lane, y: from.midY), CGPoint(x: lane, y: to.midY), end]
                }
            } else {
                let outCross = faceCross(edge.from, group: forwardOut[edge.from], index: index)
                let inCross = faceCross(edge.to, group: forwardIn[edge.to], index: index)
                start = attachPoint(edge.from, cross: outCross, rightOrBottom: true)
                end = attachPoint(edge.to, cross: inCross, rightOrBottom: false)
                let jog = horizontal ? abs(start.y - end.y) : abs(start.x - end.x)
                if jog > 0.5 {
                    if horizontal {
                        let midX = (start.x + end.x) / 2
                        points = [start, CGPoint(x: midX, y: start.y), CGPoint(x: midX, y: end.y), end]
                    } else {
                        let midY = (start.y + end.y) / 2
                        points = [start, CGPoint(x: start.x, y: midY), CGPoint(x: end.x, y: midY), end]
                    }
                } else {
                    points = [start, end]
                }
            }
            placedEdges.append(FlowchartLayout.PlacedEdge(
                start: start, end: end, points: points, label: edge.label,
                dashed: edge.dashed, hasArrow: edge.hasArrow
            ))
        }

        let contentMain = mainOffset - layerGap + margin
        let contentCross = crossLimit + margin
        let size = horizontal
            ? CGSize(width: contentMain, height: contentCross)
            : CGSize(width: contentCross, height: contentMain)

        let placedNodes = chart.nodes.compactMap { node -> FlowchartLayout.PlacedNode? in
            guard let frame = frames[node.id] else { return nil }
            return FlowchartLayout.PlacedNode(id: node.id, label: node.label, shape: node.shape, frame: frame)
        }
        return FlowchartLayout(size: size, nodes: placedNodes, edges: placedEdges)
    }

    private static func barycenter(of id: String, edges: [Flowchart.Edge], position: [String: Int]) -> Double {
        let predecessors = edges.filter { $0.to == id }.compactMap { position[$0.from] }
        guard !predecessors.isEmpty else { return Double(position[id] ?? 0) }
        return Double(predecessors.reduce(0, +)) / Double(predecessors.count)
    }

    // MARK: Sequence

    public static func layout(_ diagram: SequenceDiagram, measure: DiagramTextMeasurer) -> SequenceLayout {
        let margin: CGFloat = 12
        let headPaddingX: CGFloat = 14
        let headHeight: CGFloat = 30
        let rowHeight: CGFloat = 34
        let minColumn: CGFloat = 110

        // Column widths driven by head labels and message texts.
        var columnWidth: [CGFloat] = diagram.participants.map { participant in
            max(measure(participant.label, nodeFontSize).width + headPaddingX * 2, minColumn)
        }
        var indexOf: [String: Int] = [:]
        for (i, participant) in diagram.participants.enumerated() { indexOf[participant.id] = i }
        for message in diagram.messages {
            guard let a = indexOf[message.from], let b = indexOf[message.to], abs(a - b) == 1 else { continue }
            let needed = measure(message.text, labelFontSize).width + 24
            let lo = min(a, b)
            columnWidth[lo] = max(columnWidth[lo], needed)
        }

        var heads: [SequenceLayout.Head] = []
        var x = margin
        for (i, participant) in diagram.participants.enumerated() {
            let width = columnWidth[i]
            heads.append(SequenceLayout.Head(
                label: participant.label,
                frame: CGRect(x: x, y: margin, width: width, height: headHeight)
            ))
            x += width + 24
        }

        let arrowsTop = margin + headHeight + 18
        var arrows: [SequenceLayout.Arrow] = []
        for (row, message) in diagram.messages.enumerated() {
            guard let a = indexOf[message.from], let b = indexOf[message.to] else { continue }
            let isSelf = a == b
            arrows.append(SequenceLayout.Arrow(
                fromX: heads[a].lifelineX,
                toX: isSelf ? heads[a].lifelineX + 34 : heads[b].lifelineX,
                y: arrowsTop + CGFloat(row) * rowHeight,
                text: message.text,
                dashed: message.dashed,
                isSelfMessage: isSelf
            ))
        }

        let bottom = arrowsTop + CGFloat(max(diagram.messages.count, 1)) * rowHeight
        // Self-message labels sit to the right of the loop; widen the canvas
        // so a self-message on the last lifeline doesn't clip its label.
        var width = x - 24 + margin
        for arrow in arrows where arrow.isSelfMessage && !arrow.text.isEmpty {
            let labelRight = arrow.toX + 8 + measure(arrow.text, labelFontSize).width
            width = max(width, labelRight + margin)
        }
        return SequenceLayout(
            size: CGSize(width: width, height: bottom + margin),
            heads: heads,
            lifelineBottom: bottom,
            arrows: arrows
        )
    }

    // MARK: Pie

    public static func layout(_ pie: PieChart, measure: DiagramTextMeasurer) -> PieLayout {
        let margin: CGFloat = 14
        let radius: CGFloat = 76
        let titleHeight: CGFloat = pie.title == nil ? 0 : 26

        let total = pie.slices.reduce(0) { $0 + $1.value }
        var slices: [PieLayout.Slice] = []
        var angle = -Double.pi / 2
        for (index, slice) in pie.slices.enumerated() {
            let fraction = total > 0 ? slice.value / total : 0
            let sweep = fraction * 2 * .pi
            slices.append(PieLayout.Slice(
                label: slice.label,
                value: slice.value,
                fraction: fraction,
                startAngle: angle,
                endAngle: angle + sweep,
                colorIndex: index
            ))
            angle += sweep
        }

        let legendWidth = pie.slices
            .map { measure("\($0.label) (0000)", labelFontSize).width + 22 }
            .max() ?? 80
        let legendHeight = CGFloat(pie.slices.count) * 20

        let width = margin + radius * 2 + 28 + legendWidth + margin
        let height = margin + titleHeight + max(radius * 2, legendHeight) + margin
        return PieLayout(
            size: CGSize(width: width, height: height),
            center: CGPoint(x: margin + radius, y: margin + titleHeight + radius),
            radius: radius,
            title: pie.title,
            slices: slices,
            legendOrigin: CGPoint(
                x: margin + radius * 2 + 28,
                y: margin + titleHeight + max(0, (radius * 2 - legendHeight) / 2)
            )
        )
    }

    // MARK: Class

    static let compartmentNameHeight: CGFloat = 26
    static let compartmentRowHeight: CGFloat = 17
    static let compartmentPadX: CGFloat = 12

    public static func layout(_ diagram: ClassDiagram, measure: DiagramTextMeasurer) -> ClassLayout {
        // Layer by the relation graph so hierarchies read top-down: for
        // inheritance/realization the parsed edge points child → parent;
        // flip those so parents sit above their children.
        let layeringEdges: [(String, String)] = diagram.relations.map { relation in
            switch relation.kind {
            case .inheritance, .realization: return (relation.to, relation.from)
            default: return (relation.from, relation.to)
            }
        }

        var boxSizes: [String: CGSize] = [:]
        for cls in diagram.classes {
            let members = cls.attributes + cls.methods
            var width = measure(cls.name, nodeFontSize).width + compartmentPadX * 2 + 8
            for member in members {
                width = max(width, measure(member, labelFontSize).width + compartmentPadX * 2)
            }
            var height = compartmentNameHeight
            if !cls.attributes.isEmpty { height += 5 + CGFloat(cls.attributes.count) * compartmentRowHeight }
            if !cls.methods.isEmpty { height += 5 + CGFloat(cls.methods.count) * compartmentRowHeight }
            if members.isEmpty { height += 6 } // a sliver of empty body
            boxSizes[cls.name] = CGSize(width: max(width, 96), height: height)
        }

        let placement = layeredPlacement(
            ids: diagram.classes.map(\.name),
            sizes: boxSizes,
            edges: layeringEdges,
            layerGap: 52, nodeGap: 30, margin: 14
        )

        let boxes = diagram.classes.compactMap { cls -> ClassLayout.Box? in
            guard let frame = placement.frames[cls.name] else { return nil }
            return ClassLayout.Box(
                name: cls.name, attributes: cls.attributes, methods: cls.methods,
                frame: frame, nameHeight: compartmentNameHeight, rowHeight: compartmentRowHeight
            )
        }

        // Route relations as orthogonal elbows with per-face fan-out, sharing
        // the layered-box router with the ER diagram.
        let valid = diagram.relations.filter {
            placement.frames[$0.from] != nil && placement.frames[$0.to] != nil
        }
        var frameList: [CGRect] = []
        var frameIndex: [String: Int] = [:]
        for cls in diagram.classes {
            guard let frame = placement.frames[cls.name] else { continue }
            frameIndex[cls.name] = frameList.count
            frameList.append(frame)
        }
        let pairs = valid.map { (from: frameIndex[$0.from]!, to: frameIndex[$0.to]!) }
        let routes = routeBoxEdges(frames: frameList, pairs: pairs)
        let edges = zip(valid, routes).map { relation, route in
            ClassLayout.Edge(
                start: route.points.first!,
                end: route.points.last!,
                points: route.points,
                kind: relation.kind,
                label: relation.label
            )
        }

        return ClassLayout(size: placement.size, boxes: boxes, edges: edges)
    }

    // MARK: ER

    public static func layout(_ diagram: ERDiagram, measure: DiagramTextMeasurer) -> ERLayout {
        var boxSizes: [String: CGSize] = [:]
        for entity in diagram.entities {
            var width = measure(entity.name, nodeFontSize).width + compartmentPadX * 2 + 8
            for attribute in entity.attributes {
                let row = "\(attribute.type)  \(attribute.name)"
                width = max(width, measure(row, labelFontSize).width + compartmentPadX * 2)
            }
            var height = compartmentNameHeight
            if !entity.attributes.isEmpty {
                height += 5 + CGFloat(entity.attributes.count) * compartmentRowHeight
            }
            boxSizes[entity.name] = CGSize(width: max(width, 96), height: height)
        }

        let placement = layeredPlacement(
            ids: diagram.entities.map(\.name),
            sizes: boxSizes,
            edges: diagram.relations.map { ($0.from, $0.to) },
            layerGap: 64, nodeGap: 34, margin: 14
        )

        let boxes = diagram.entities.compactMap { entity -> ERLayout.Box? in
            guard let frame = placement.frames[entity.name] else { return nil }
            return ERLayout.Box(
                name: entity.name, attributes: entity.attributes,
                frame: frame, nameHeight: compartmentNameHeight, rowHeight: compartmentRowHeight
            )
        }

        let valid = diagram.relations.filter {
            placement.frames[$0.from] != nil && placement.frames[$0.to] != nil
        }
        var frameList: [CGRect] = []
        var frameIndex: [String: Int] = [:]
        for entity in diagram.entities {
            guard let frame = placement.frames[entity.name] else { continue }
            frameIndex[entity.name] = frameList.count
            frameList.append(frame)
        }
        let pairs = valid.map { (from: frameIndex[$0.from]!, to: frameIndex[$0.to]!) }
        let routes = routeBoxEdges(frames: frameList, pairs: pairs)
        let edges = zip(valid, routes).map { relation, route in
            ERLayout.Edge(
                start: route.points.first!,
                end: route.points.last!,
                points: route.points,
                fromCard: relation.fromCard,
                toCard: relation.toCard,
                label: relation.label,
                identifying: relation.identifying
            )
        }

        return ERLayout(size: placement.size, boxes: boxes, edges: edges)
    }

    // MARK: State

    static let stateTitleHeight: CGFloat = 22
    static let stateInset: CGFloat = 14

    public static func layout(_ diagram: StateDiagram, measure: DiagramTextMeasurer) -> StateLayout {
        let result = layoutStateScope(diagram, depth: 0, measure: measure)
        return StateLayout(
            size: result.size, nodes: result.nodes,
            containers: result.containers, edges: result.edges
        )
    }

    private struct StateScopeResult {
        var nodes: [StateLayout.Node]
        var containers: [StateLayout.Container]
        var edges: [StateLayout.Edge]
        var size: CGSize
    }

    /// Lays out one state scope, recursing into composites first so each one
    /// becomes a fixed-size box in its parent's layout. Interior placements
    /// are offset into the composite's frame, so the whole thing is flattened
    /// into absolute coordinates for the renderer.
    private static func layoutStateScope(
        _ diagram: StateDiagram, depth: Int, measure: DiagramTextMeasurer
    ) -> StateScopeResult {
        var sizes: [String: CGSize] = [:]
        var childResults: [String: StateScopeResult] = [:]

        for node in diagram.nodes {
            switch node.kind {
            case .composite(let sub):
                let child = layoutStateScope(sub, depth: depth + 1, measure: measure)
                childResults[node.id] = child
                let titleWidth = measure(node.label, nodeFontSize).width + 28
                let width = max(child.size.width + stateInset * 2, titleWidth, 96)
                let height = child.size.height + stateInset * 2 + stateTitleHeight
                sizes[node.id] = CGSize(width: width, height: height)
            case .start:
                sizes[node.id] = CGSize(width: 14, height: 14)
            case .end:
                sizes[node.id] = CGSize(width: 18, height: 18)
            case .choice:
                sizes[node.id] = CGSize(width: 26, height: 26)
            case .fork, .join:
                sizes[node.id] = CGSize(width: 64, height: 10)
            case .simple:
                let text = measure(node.label, nodeFontSize)
                sizes[node.id] = CGSize(width: max(text.width + 28, 56), height: text.height + 18)
            }
        }

        let placement = layeredPlacement(
            ids: diagram.nodes.map(\.id),
            sizes: sizes,
            edges: diagram.edges.map { ($0.from, $0.to) },
            layerGap: 40, nodeGap: 26, margin: 6
        )

        var outNodes: [StateLayout.Node] = []
        var outContainers: [StateLayout.Container] = []
        var outEdges: [StateLayout.Edge] = []

        func mapKind(_ kind: StateDiagram.Kind) -> StateLayout.NodeKind {
            switch kind {
            case .simple, .composite: return .simple
            case .start: return .start
            case .end: return .end
            case .choice: return .choice
            case .fork: return .fork
            case .join: return .join
            }
        }

        for node in diagram.nodes {
            guard let frame = placement.frames[node.id] else { continue }
            if case .composite = node.kind, let child = childResults[node.id] {
                outContainers.append(StateLayout.Container(
                    label: node.label, frame: frame,
                    titleHeight: stateTitleHeight, depth: depth
                ))
                let dx = frame.minX + stateInset
                let dy = frame.minY + stateTitleHeight + stateInset
                for n in child.nodes {
                    outNodes.append(StateLayout.Node(
                        id: n.id, label: n.label, kind: n.kind,
                        frame: n.frame.offsetBy(dx: dx, dy: dy)
                    ))
                }
                for c in child.containers {
                    outContainers.append(StateLayout.Container(
                        label: c.label, frame: c.frame.offsetBy(dx: dx, dy: dy),
                        titleHeight: c.titleHeight, depth: c.depth
                    ))
                }
                for e in child.edges {
                    outEdges.append(StateLayout.Edge(
                        start: CGPoint(x: e.start.x + dx, y: e.start.y + dy),
                        end: CGPoint(x: e.end.x + dx, y: e.end.y + dy),
                        points: e.points.map { CGPoint(x: $0.x + dx, y: $0.y + dy) },
                        label: e.label
                    ))
                }
            } else {
                outNodes.append(StateLayout.Node(
                    id: node.id, label: node.label,
                    kind: mapKind(node.kind), frame: frame
                ))
            }
        }

        // Route this scope's own transitions with the shared fan-out router.
        var frameList: [CGRect] = []
        var frameIndex: [String: Int] = [:]
        for node in diagram.nodes {
            guard let frame = placement.frames[node.id] else { continue }
            frameIndex[node.id] = frameList.count
            frameList.append(frame)
        }
        let valid = diagram.edges.filter { frameIndex[$0.from] != nil && frameIndex[$0.to] != nil }
        let pairs = valid.map { (from: frameIndex[$0.from]!, to: frameIndex[$0.to]!) }
        let routes = routeBoxEdges(frames: frameList, pairs: pairs)
        for (edge, route) in zip(valid, routes) {
            outEdges.append(StateLayout.Edge(
                start: route.points.first!, end: route.points.last!,
                points: route.points, label: edge.label
            ))
        }

        return StateScopeResult(
            nodes: outNodes, containers: outContainers,
            edges: outEdges, size: placement.size
        )
    }

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
