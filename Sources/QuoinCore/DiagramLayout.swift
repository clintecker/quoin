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
        public let label: String?
        public let dashed: Bool
        public let hasArrow: Bool
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
        public let fromCard: ERDiagram.Cardinality
        public let toCard: ERDiagram.Cardinality
        public let label: String
        public let identifying: Bool
    }

    public let size: CGSize
    public let boxes: [Box]
    public let edges: [Edge]
}

// MARK: - Engine

public enum DiagramLayoutEngine {

    public static let nodeFontSize: Double = 12
    public static let labelFontSize: Double = 10.5

    // MARK: Flowchart (layered / Sugiyama-style)

    public static func layout(_ chart: Flowchart, measure: DiagramTextMeasurer) -> FlowchartLayout {
        let horizontal = chart.direction == .leftRight || chart.direction == .rightLeft

        // 1. Longest-path layering (cycle-safe via relaxation cap).
        var layerOf: [String: Int] = [:]
        for node in chart.nodes { layerOf[node.id] = 0 }
        let maxPasses = chart.nodes.count + 1
        for _ in 0..<maxPasses {
            var changed = false
            for edge in chart.edges {
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

        let contentMain = mainOffset - layerGap + margin
        let contentCross = crossExtent + margin * 2
        let size = horizontal
            ? CGSize(width: contentMain, height: contentCross)
            : CGSize(width: contentCross, height: contentMain)

        // 5. Edges: border-to-border straight segments.
        var placedEdges: [FlowchartLayout.PlacedEdge] = []
        for edge in chart.edges {
            guard let from = frames[edge.from], let to = frames[edge.to] else { continue }
            let start: CGPoint
            let end: CGPoint
            if horizontal {
                start = CGPoint(x: from.maxX, y: from.midY)
                end = CGPoint(x: to.minX, y: to.midY)
            } else {
                start = CGPoint(x: from.midX, y: from.maxY)
                end = CGPoint(x: to.midX, y: to.minY)
            }
            placedEdges.append(FlowchartLayout.PlacedEdge(
                start: start, end: end, label: edge.label,
                dashed: edge.dashed, hasArrow: edge.hasArrow
            ))
        }

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

        let edges = diagram.relations.compactMap { relation -> ClassLayout.Edge? in
            guard let from = placement.frames[relation.from],
                  let to = placement.frames[relation.to] else { return nil }
            return ClassLayout.Edge(
                start: borderPoint(of: from, toward: CGPoint(x: to.midX, y: to.midY)),
                end: borderPoint(of: to, toward: CGPoint(x: from.midX, y: from.midY)),
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

        let edges = diagram.relations.compactMap { relation -> ERLayout.Edge? in
            guard let from = placement.frames[relation.from],
                  let to = placement.frames[relation.to] else { return nil }
            return ERLayout.Edge(
                start: borderPoint(of: from, toward: CGPoint(x: to.midX, y: to.midY)),
                end: borderPoint(of: to, toward: CGPoint(x: from.midX, y: from.midY)),
                fromCard: relation.fromCard,
                toCard: relation.toCard,
                label: relation.label,
                identifying: relation.identifying
            )
        }

        return ERLayout(size: placement.size, boxes: boxes, edges: edges)
    }

    // MARK: Shared box placement

    struct Placement {
        let frames: [String: CGRect]
        let size: CGSize
    }

    /// Longest-path layering + barycenter ordering for arbitrary sized
    /// boxes, top-down. Shared by the class and ER layouts.
    static func layeredPlacement(
        ids: [String],
        sizes: [String: CGSize],
        edges: [(String, String)],
        layerGap: CGFloat,
        nodeGap: CGFloat,
        margin: CGFloat
    ) -> Placement {
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
