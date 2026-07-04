import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif

/// Flowchart (layered / Sugiyama-style), sequence, and pie layout engines.
/// Split from DiagramLayout.swift for navigability; the shared placement and
/// routing primitives live there.
extension DiagramLayoutEngine {

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

}
