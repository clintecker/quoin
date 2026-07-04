import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif

/// Flowchart (layered / Sugiyama-style), sequence, and pie layout engines.
/// Split from DiagramLayout.swift for navigability; the shared placement and
/// routing primitives live there.
extension DiagramLayoutEngine {

    // MARK: Flowchart (layered / Sugiyama-style)

    private static let flowchartMargin: CGFloat = 12
    private static let flowchartLayerGap: CGFloat = 44
    private static let flowchartNodeGap: CGFloat = 26
    /// Cross-axis breadth a dummy node reserves — a narrow channel a long edge
    /// runs through, between real nodes.
    private static let dummyBreadth: CGFloat = 16

    public static func layout(_ chart: Flowchart, measure: DiagramTextMeasurer) -> FlowchartLayout {
        let horizontal = chart.direction == .leftRight || chart.direction == .rightLeft

        let ids = chart.nodes.map(\.id)
        let allEdges = chart.edges.map { ($0.from, $0.to) }

        // 1. Break cycles, then assign layers on the acyclic forward edges.
        let backEdges = backEdgeIndices(ids: ids, edges: allEdges)
        let forwardEdges = chart.edges.enumerated()
            .filter { !backEdges.contains($0.offset) }
            .map { ($0.element.from, $0.element.to) }
        let layerOf = assignLayers(ids: ids, edges: forwardEdges)
        let layerCount = (layerOf.values.max() ?? 0) + 1

        // 2. Insert dummy nodes for every edge spanning more than one layer
        // (forward or back). Dummies join their layer and reserve channel space
        // in ordering + placement, so a long edge routes *between* the nodes it
        // crosses rather than under them (Sugiyama/dagre-style routing). Each
        // edge's waypoint chain [u, dummies…, v] drives its route.
        var layers: [[String]] = Array(repeating: [], count: layerCount)
        for id in ids { layers[layerOf[id]!].append(id) }
        var sizes = flowchartNodeSizes(chart.nodes, measure: measure)
        var chains: [[String]] = []
        var segmentEdges: [(String, String)] = []
        for (index, edge) in chart.edges.enumerated() {
            guard let lu = layerOf[edge.from], let lv = layerOf[edge.to] else { chains.append([]); continue }
            let lo = min(lu, lv), hi = max(lu, lv)
            if hi - lo <= 1 {
                chains.append([edge.from, edge.to])
                segmentEdges.append((edge.from, edge.to))
                continue
            }
            var midByLayer: [(layer: Int, id: String)] = []
            for layer in (lo + 1)...(hi - 1) {
                let dummy = "\u{a7}\(index).\(layer)"
                layers[layer].append(dummy)
                sizes[dummy] = CGSize(width: dummyBreadth, height: 1)
                midByLayer.append((layer, dummy))
            }
            let mids = (lu < lv ? midByLayer : midByLayer.reversed()).map(\.id)
            let chain = [edge.from] + mids + [edge.to]
            chains.append(chain)
            for k in 0..<(chain.count - 1) { segmentEdges.append((chain[k], chain[k + 1])) }
        }

        // 3. Order every layer (real + dummy) by barycenter; 4. assign
        // coordinates (dummies take a narrow channel between real nodes).
        let ordered = barycenterOrder(layers: layers, edges: segmentEdges)
        let placement = placeFlowchartFrames(layers: ordered, sizes: sizes, horizontal: horizontal)

        // 5. Route each edge through its chain's waypoints.
        let (placedEdges, crossLimit) = routeChains(
            chart: chart, chains: chains, frames: placement.frames,
            horizontal: horizontal, crossExtent: placement.crossExtent
        )

        // 6. Place edge labels clear of node boxes and each other.
        let labeledEdges = placeEdgeLabels(
            placedEdges, nodeFrames: chart.nodes.compactMap { placement.frames[$0.id] }, measure: measure
        )

        let contentCross = crossLimit + flowchartMargin
        var size = horizontal
            ? CGSize(width: placement.mainContentEnd, height: contentCross)
            : CGSize(width: contentCross, height: placement.mainContentEnd)
        // Grow the canvas for any label nudged past the content box.
        for edge in labeledEdges {
            guard let lp = edge.labelPoint, let label = edge.label, !label.isEmpty else { continue }
            let sz = measure(label, labelFontSize)
            size.width = max(size.width, lp.x + sz.width / 2 + flowchartMargin)
            size.height = max(size.height, lp.y + sz.height / 2 + flowchartMargin)
        }

        let placedNodes = chart.nodes.compactMap { node -> FlowchartLayout.PlacedNode? in
            guard let frame = placement.frames[node.id] else { return nil }
            return FlowchartLayout.PlacedNode(id: node.id, label: node.label, shape: node.shape, frame: frame)
        }
        return FlowchartLayout(size: size, nodes: placedNodes, edges: labeledEdges)
    }

    /// Chooses each labeled edge's anchor so labels don't overprint node boxes
    /// or one another. Scores candidate points (segment midpoints, plus small
    /// sideways nudges) by how much they overlap node frames and already-placed
    /// labels, and keeps the cheapest — so a label slides into a clear gap or
    /// off to the side instead of landing on a box's text.
    private static func placeEdgeLabels(
        _ edges: [FlowchartLayout.PlacedEdge],
        nodeFrames: [CGRect],
        measure: DiagramTextMeasurer
    ) -> [FlowchartLayout.PlacedEdge] {
        let obstacles = nodeFrames.map { $0.insetBy(dx: -3, dy: -3) }
        var labelRects: [CGRect] = []
        var result: [FlowchartLayout.PlacedEdge] = []

        for edge in edges {
            guard let label = edge.label, !label.isEmpty, edge.points.count >= 2 else {
                result.append(edge); continue
            }
            let sz = measure(label, labelFontSize)
            let w = sz.width + 6, h = sz.height + 2

            var candidates: [CGPoint] = []
            for i in 0..<(edge.points.count - 1) {
                let a = edge.points[i], b = edge.points[i + 1]
                candidates.append(CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2))
            }
            let nudges: [CGFloat] = [0, w / 2 + 5, -(w / 2 + 5), w + 9, -(w + 9)]

            var best = candidates[0]
            var bestScore = CGFloat.greatestFiniteMagnitude
            for (index, c) in candidates.enumerated() {
                for dx in nudges {
                    let rect = CGRect(x: c.x + dx - w / 2, y: c.y - h / 2, width: w, height: h)
                    var score: CGFloat = 0
                    for o in obstacles { score += overlapArea(rect, o) * 4 }   // node overlap: costly
                    for l in labelRects { score += overlapArea(rect, l) * 2 }  // label overlap
                    score += abs(dx) * 0.15                                    // prefer on the line
                    if rect.minX < flowchartMargin || rect.minY < flowchartMargin { score += 1_000 }
                    // Prefer a middle segment (more likely to sit in a clear gap).
                    score += abs(CGFloat(index) - CGFloat(candidates.count - 1) / 2) * 0.5
                    if score < bestScore { bestScore = score; best = CGPoint(x: c.x + dx, y: c.y) }
                }
            }
            labelRects.append(CGRect(x: best.x - w / 2, y: best.y - h / 2, width: w, height: h))
            result.append(FlowchartLayout.PlacedEdge(
                start: edge.start, end: edge.end, points: edge.points,
                label: edge.label, dashed: edge.dashed, hasArrow: edge.hasArrow, labelPoint: best
            ))
        }
        return result
    }

    /// Area of the intersection of two rects (0 when disjoint).
    private static func overlapArea(_ a: CGRect, _ b: CGRect) -> CGFloat {
        let ix = max(0, min(a.maxX, b.maxX) - max(a.minX, b.minX))
        let iy = max(0, min(a.maxY, b.maxY) - max(a.minY, b.minY))
        return ix * iy
    }

    /// Node box sizes from their labels, with per-shape adjustments
    /// (diamonds widen, circles square up, state terminals are fixed dots).
    private static func flowchartNodeSizes(
        _ nodes: [Flowchart.Node],
        measure: DiagramTextMeasurer
    ) -> [String: CGSize] {
        let paddingX: CGFloat = 14
        let paddingY: CGFloat = 9
        var sizes: [String: CGSize] = [:]
        for node in nodes {
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
            case .cylinder:
                size.height += 12   // room for the top/bottom ellipse caps
            default:
                break
            }
            if node.shape != .stateStart && node.shape != .stateEnd {
                size.width = max(size.width, 56)
            }
            sizes[node.id] = size
        }
        return sizes
    }

    /// Places the ordered layers along the main axis (down for TD, across for
    /// LR), centering each layer on the cross axis. `mainContentEnd` is the
    /// final main-axis dimension (trailing layer gap trimmed, margin added);
    /// `crossExtent` is the widest layer, before back-edge lanes extend it.
    private static func placeFlowchartFrames(
        layers: [[String]],
        sizes: [String: CGSize],
        horizontal: Bool
    ) -> (frames: [String: CGRect], mainContentEnd: CGFloat, crossExtent: CGFloat) {
        let layerGap = flowchartLayerGap
        let nodeGap = flowchartNodeGap
        let margin = flowchartMargin

        var frames: [String: CGRect] = [:]
        var mainOffset = margin
        var crossExtent: CGFloat = 0

        var layerCrossSizes: [CGFloat] = []
        for layer in layers {
            let total = layer.reduce(CGFloat(0)) { sum, id in
                sum + (horizontal ? sizes[id]!.height : sizes[id]!.width)
            } + CGFloat(max(layer.count - 1, 0)) * nodeGap
            layerCrossSizes.append(total)
            crossExtent = max(crossExtent, total)
        }

        for (layerIndex, layer) in layers.enumerated() {
            let mainSize = layer.map { horizontal ? sizes[$0]!.width : sizes[$0]!.height }.max() ?? 0
            var crossOffset = margin + (crossExtent - layerCrossSizes[layerIndex]) / 2
            for id in layer {
                let size = sizes[id]!
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
                frames[id] = frame
            }
            mainOffset += mainSize + layerGap
        }

        return (frames, mainOffset - layerGap + margin, crossExtent)
    }

    /// Routes each edge as a polyline. Forward edges attach at points
    /// distributed across each node's face — fanned out by the other
    /// endpoint's cross position so sibling edges never share a stub — and
    /// projected onto the node's actual outline (diamonds/circles) so they
    /// don't float off a bounding-box corner. Back edges (cycles) route around
    /// the node band in a private lane so they never overwrite the forward
    /// flow; that lane can push the cross dimension out, so the grown
    /// `crossLimit` is returned alongside the edges.
    /// Routes every edge through its dummy-node waypoint chain. The exit/enter
    /// faces and direction come from the chain's geometry, so forward edges
    /// leave the bottom and enter the top while back edges go the other way;
    /// intermediate dummy centers become the bend points. Because the dummies
    /// reserved channel space in placement, the resulting polyline runs
    /// between the nodes it crosses rather than under them.
    private static func routeChains(
        chart: Flowchart,
        chains: [[String]],
        frames: [String: CGRect],
        horizontal: Bool,
        crossExtent: CGFloat
    ) -> (edges: [FlowchartLayout.PlacedEdge], crossLimit: CGFloat) {
        let shapeOf = Dictionary(uniqueKeysWithValues: chart.nodes.map { ($0.id, $0.shape) })

        // Projects a cross coordinate onto a node's outline on the chosen face.
        func attach(_ id: String, cross: CGFloat, rightOrBottom: Bool) -> CGPoint {
            let f = frames[id]!
            let shape = shapeOf[id] ?? .rectangle
            if horizontal {
                let y = min(max(cross, f.minY), f.maxY)
                let hh = max(f.height / 2, 0.001)
                var x = rightOrBottom ? f.maxX : f.minX
                switch shape {
                case .diamond:
                    let dx = (f.width / 2) * (1 - min(abs(y - f.midY) / hh, 1))
                    x = rightOrBottom ? f.midX + dx : f.midX - dx
                case .circle, .stateStart, .stateEnd:
                    let dx = (f.width / 2) * sqrt(max(0, 1 - pow((y - f.midY) / hh, 2)))
                    x = rightOrBottom ? f.midX + dx : f.midX - dx
                default: break
                }
                return CGPoint(x: x, y: y)
            } else {
                let x = min(max(cross, f.minX), f.maxX)
                let hw = max(f.width / 2, 0.001)
                var y = rightOrBottom ? f.maxY : f.minY
                switch shape {
                case .diamond:
                    let dy = (f.height / 2) * (1 - min(abs(x - f.midX) / hw, 1))
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
        var crossLimit = flowchartMargin + crossExtent
        for f in frames.values { crossLimit = max(crossLimit, horizontal ? f.maxY : f.maxX) }

        for (index, edge) in chart.edges.enumerated() {
            let chain = index < chains.count ? chains[index] : []
            guard chain.count >= 2,
                  let fromFrame = frames[chain[0]], let toFrame = frames[chain[chain.count - 1]] else {
                let p = CGPoint.zero
                placedEdges.append(FlowchartLayout.PlacedEdge(
                    start: p, end: p, points: [p, p],
                    label: edge.label, dashed: edge.dashed, hasArrow: edge.hasArrow))
                continue
            }
            let dummyCenters = chain[1..<(chain.count - 1)].compactMap { id -> CGPoint? in
                frames[id].map { CGPoint(x: $0.midX, y: $0.midY) }
            }
            let firstNext = dummyCenters.first ?? CGPoint(x: toFrame.midX, y: toFrame.midY)
            let lastPrev = dummyCenters.last ?? CGPoint(x: fromFrame.midX, y: fromFrame.midY)
            let exitBottomRight = horizontal ? (firstNext.x >= fromFrame.midX) : (firstNext.y >= fromFrame.midY)
            let enterBottomRight = horizontal ? (lastPrev.x > toFrame.midX) : (lastPrev.y > toFrame.midY)
            let start = attach(chain[0], cross: horizontal ? firstNext.y : firstNext.x, rightOrBottom: exitBottomRight)
            let end = attach(chain[chain.count - 1], cross: horizontal ? lastPrev.y : lastPrev.x, rightOrBottom: enterBottomRight)

            let points = routePolyline([start] + dummyCenters + [end], horizontal: horizontal)
            for p in points { crossLimit = max(crossLimit, horizontal ? p.y : p.x) }
            placedEdges.append(FlowchartLayout.PlacedEdge(
                start: start, end: end, points: points,
                label: edge.label, dashed: edge.dashed, hasArrow: edge.hasArrow))
        }
        return (placedEdges, crossLimit)
    }

    /// Connects waypoints with an orthogonal polyline. For a top-down chart the
    /// vertical runs sit at each waypoint's x (the reserved dummy channels) and
    /// the horizontal jogs happen at the midpoint between consecutive waypoints
    /// — i.e. in the gaps between layers, never across a node's row. Collinear
    /// runs are merged so straight edges stay two-point.
    private static func routePolyline(_ waypoints: [CGPoint], horizontal: Bool) -> [CGPoint] {
        guard waypoints.count >= 2 else { return waypoints }
        var pts: [CGPoint] = [waypoints[0]]
        for i in 0..<(waypoints.count - 1) {
            let a = waypoints[i], b = waypoints[i + 1]
            if horizontal {
                if abs(a.y - b.y) > 0.5 {
                    let midX = (a.x + b.x) / 2
                    pts.append(CGPoint(x: midX, y: a.y))
                    pts.append(CGPoint(x: midX, y: b.y))
                }
            } else if abs(a.x - b.x) > 0.5 {
                let midY = (a.y + b.y) / 2
                pts.append(CGPoint(x: a.x, y: midY))
                pts.append(CGPoint(x: b.x, y: midY))
            }
        }
        pts.append(waypoints[waypoints.count - 1])
        return simplifyCollinear(pts)
    }

    /// Drops points that lie on a straight run with their neighbours, and exact
    /// duplicates, so a polyline carries only its real bends.
    private static func simplifyCollinear(_ pts: [CGPoint]) -> [CGPoint] {
        guard pts.count > 2 else { return pts }
        var out: [CGPoint] = [pts[0]]
        for i in 1..<(pts.count - 1) {
            let a = out.last!, b = pts[i], c = pts[i + 1]
            if abs(a.x - b.x) < 0.5, abs(a.y - b.y) < 0.5 { continue }         // duplicate
            let straightH = abs(a.y - b.y) < 0.5 && abs(b.y - c.y) < 0.5
            let straightV = abs(a.x - b.x) < 0.5 && abs(b.x - c.x) < 0.5
            if straightH || straightV { continue }                            // collinear
            out.append(b)
        }
        out.append(pts[pts.count - 1])
        return out
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
