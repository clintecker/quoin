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
    private static let flowchartLayerGap: CGFloat = 56
    private static let flowchartNodeGap: CGFloat = 26
    /// Cross-axis breadth a dummy node reserves — a narrow channel a long edge
    /// runs through, between real nodes.
    private static let dummyBreadth: CGFloat = 16
    /// Minimum separation between two edges fanned onto the same node face —
    /// 2×corner-radius (5) + arrowhead half-width (~7) + clearance.
    private static let flowchartPortSep: CGFloat = 20
    /// Track spacing for concurrent edge jogs crossing the same layer gap.
    private static let flowchartJogTrack: CGFloat = 10

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
        var dummies: Set<String> = []
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
                dummies.insert(dummy)
                midByLayer.append((layer, dummy))
            }
            let mids = (lu < lv ? midByLayer : midByLayer.reversed()).map(\.id)
            let chain = [edge.from] + mids + [edge.to]
            chains.append(chain)
            for k in 0..<(chain.count - 1) { segmentEdges.append((chain[k], chain[k + 1])) }
        }

        // 3. Order every layer (real + dummy) by barycenter; 4. assign cross
        // coordinates with Brandes–Köpf so chains and dummy channels align into
        // straight runs (the cross axis is x for TD, y for LR).
        let ordered = barycenterOrder(layers: layers, edges: segmentEdges)
        var crossBreadth: [String: CGFloat] = [:]
        for layer in ordered {
            for id in layer { crossBreadth[id] = horizontal ? (sizes[id]?.height ?? 0) : (sizes[id]?.width ?? 0) }
        }
        let crossCenter = brandesKoepfX(
            layers: ordered, segments: segmentEdges, breadth: crossBreadth,
            dummies: dummies, minGap: flowchartNodeGap)
        let placement = placeFlowchartFrames(
            layers: ordered, sizes: sizes, crossCenter: crossCenter, horizontal: horizontal)

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
    /// LR), using the Brandes–Köpf `crossCenter` for each node's cross-axis
    /// position (normalized so the leftmost/topmost edge sits at the margin).
    /// `mainContentEnd` is the final main-axis dimension (trailing layer gap
    /// trimmed, margin added); `crossExtent` is the full cross span.
    private static func placeFlowchartFrames(
        layers: [[String]],
        sizes: [String: CGSize],
        crossCenter: [String: CGFloat],
        horizontal: Bool
    ) -> (frames: [String: CGRect], mainContentEnd: CGFloat, crossExtent: CGFloat) {
        let layerGap = flowchartLayerGap
        let margin = flowchartMargin

        // Normalize BK's relative coordinates so the min cross edge = margin.
        func breadth(_ id: String) -> CGFloat { horizontal ? sizes[id]!.height : sizes[id]!.width }
        var minCross = CGFloat.greatestFiniteMagnitude
        var maxCross = -CGFloat.greatestFiniteMagnitude
        for layer in layers {
            for id in layer {
                let c = crossCenter[id] ?? 0
                minCross = min(minCross, c - breadth(id) / 2)
                maxCross = max(maxCross, c + breadth(id) / 2)
            }
        }
        let shift = margin - (minCross.isFinite ? minCross : 0)
        let crossExtent = maxCross > minCross ? maxCross - minCross : 0

        var frames: [String: CGRect] = [:]
        var mainOffset = margin
        for layer in layers {
            let mainSize = layer.map { horizontal ? sizes[$0]!.width : sizes[$0]!.height }.max() ?? 0
            for id in layer {
                let size = sizes[id]!
                let center = (crossCenter[id] ?? 0) + shift
                if horizontal {
                    frames[id] = CGRect(
                        x: mainOffset + (mainSize - size.width) / 2,
                        y: center - size.height / 2,
                        width: size.width, height: size.height
                    )
                } else {
                    frames[id] = CGRect(
                        x: center - size.width / 2,
                        y: mainOffset + (mainSize - size.height) / 2,
                        width: size.width, height: size.height
                    )
                }
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
        // `isSource` marks the edge's tail (the node it leaves) vs. its head.
        // Decisions are handled by `diamondPort`, never here.
        func attach(_ id: String, cross: CGFloat, rightOrBottom: Bool, isSource: Bool) -> CGPoint {
            let f = frames[id]!
            let shape = shapeOf[id] ?? .rectangle
            if horizontal {
                // Keep the attach point off the very corners of a box so an edge
                // whose channel runs past the box edge is pulled onto the face
                // rather than pinned to a corner.
                let inset = min(f.height * 0.22, f.height / 2)
                let y = min(max(cross, f.minY + inset), f.maxY - inset)
                let hh = max(f.height / 2, 0.001)
                var x = rightOrBottom ? f.maxX : f.minX
                switch shape {
                case .circle, .stateStart, .stateEnd:
                    let dx = (f.width / 2) * sqrt(max(0, 1 - pow((y - f.midY) / hh, 2)))
                    x = rightOrBottom ? f.midX + dx : f.midX - dx
                default: break
                }
                return CGPoint(x: x, y: y)
            } else {
                let inset = min(f.width * 0.22, f.width / 2)
                let x = min(max(cross, f.minX + inset), f.maxX - inset)
                let hw = max(f.width / 2, 0.001)
                var y = rightOrBottom ? f.maxY : f.minY
                switch shape {
                case .circle, .stateStart, .stateEnd:
                    let dy = (f.height / 2) * sqrt(max(0, 1 - pow((x - f.midX) / hw, 2)))
                    y = rightOrBottom ? f.midY + dy : f.midY - dy
                default: break
                }
                return CGPoint(x: x, y: y)
            }
        }

        // A decision attaches at the vertex facing its neighbor and leaves/enters
        // heading straight out of that point — the flowchart convention.
        //
        // An *incoming* edge enters on the main-axis face (top for TD, left for
        // LR; the opposite for a back edge), so flow arrives "into the top" and
        // the alignment jog happens in the layer gap — this reserves the side
        // vertices for the branches. An *outgoing* branch whose neighbor sits
        // clearly to a side (beyond ~15% of the half-width) leaves from the
        // west/east vertex with a short stub carrying it out before vertical
        // routing resumes; otherwise it leaves the south/north vertex.
        func diamondPort(_ f: CGRect, toward next: CGPoint, isSource: Bool) -> (vertex: CGPoint, stub: CGPoint?) {
            if !isSource {
                return horizontal
                    ? (CGPoint(x: next.x <= f.midX ? f.minX : f.maxX, y: f.midY), nil)
                    : (CGPoint(x: f.midX, y: next.y <= f.midY ? f.minY : f.maxY), nil)
            }
            if horizontal {
                let eps = f.height * 0.15
                let dy = next.y - f.midY
                if dy < -eps {
                    let v = CGPoint(x: f.midX, y: f.minY)
                    return (v, next.y < v.y - 1 ? CGPoint(x: v.x, y: next.y) : nil)
                } else if dy > eps {
                    let v = CGPoint(x: f.midX, y: f.maxY)
                    return (v, next.y > v.y + 1 ? CGPoint(x: v.x, y: next.y) : nil)
                }
                return (CGPoint(x: next.x >= f.midX ? f.maxX : f.minX, y: f.midY), nil)
            } else {
                let eps = f.width * 0.15
                let dx = next.x - f.midX
                if dx < -eps {
                    let v = CGPoint(x: f.minX, y: f.midY)
                    return (v, next.x < v.x - 1 ? CGPoint(x: next.x, y: v.y) : nil)
                } else if dx > eps {
                    let v = CGPoint(x: f.maxX, y: f.midY)
                    return (v, next.x > v.x + 1 ? CGPoint(x: next.x, y: v.y) : nil)
                }
                return (CGPoint(x: f.midX, y: next.y >= f.midY ? f.maxY : f.minY), nil)
            }
        }

        // The cross coordinate at which an edge descends out of its source — a
        // decision's vertex/stub, or a plain box's face port clamped toward the
        // next waypoint. Used to line the target port up with the actual run.
        func sourceExitCross(srcDiamond: Bool, from f: CGRect, toward next: CGPoint) -> CGFloat {
            if srcDiamond {
                let (v, stub) = diamondPort(f, toward: next, isSource: true)
                let p = stub ?? v
                return horizontal ? p.y : p.x
            }
            if horizontal {
                let inset = min(f.height * 0.22, f.height / 2)
                return min(max(next.y, f.minY + inset), f.maxY - inset)
            }
            let inset = min(f.width * 0.22, f.width / 2)
            return min(max(next.x, f.minX + inset), f.maxX - inset)
        }

        // Per-edge geometry, computed once so a port-distribution pass can run
        // between geometry and routing.
        struct EdgeGeo {
            var valid = false
            var chain: [String] = []
            var dummyCenters: [CGPoint] = []
            var fromFrame = CGRect.zero
            var toFrame = CGRect.zero
            var firstNext = CGPoint.zero
            var lastPrev = CGPoint.zero
            var srcDiamond = false
            var dstDiamond = false
            var exitBottom = false
            var enterBottom = false
        }
        var geos = [EdgeGeo](repeating: EdgeGeo(), count: chart.edges.count)

        // A face port request: which edge-end wants to attach to a node face,
        // and the cross coordinate it would naturally take (its channel).
        var buckets: [String: [(edge: Int, isSource: Bool, wanted: CGFloat)]] = [:]
        func faceKey(_ node: String, bottom: Bool) -> String { "\(node)|\(bottom)" }

        for index in chart.edges.indices {
            let chain = index < chains.count ? chains[index] : []
            guard chain.count >= 2,
                  let ff = frames[chain[0]], let tf = frames[chain[chain.count - 1]] else { continue }
            var g = EdgeGeo()
            g.valid = true; g.chain = chain; g.fromFrame = ff; g.toFrame = tf
            g.dummyCenters = chain[1..<(chain.count - 1)].compactMap { id in
                frames[id].map { CGPoint(x: $0.midX, y: $0.midY) }
            }
            g.firstNext = g.dummyCenters.first ?? CGPoint(x: tf.midX, y: tf.midY)
            g.lastPrev = g.dummyCenters.last ?? CGPoint(x: ff.midX, y: ff.midY)
            g.exitBottom = horizontal ? (g.firstNext.x >= ff.midX) : (g.firstNext.y >= ff.midY)
            g.enterBottom = horizontal ? (g.lastPrev.x > tf.midX) : (g.lastPrev.y > tf.midY)
            g.srcDiamond = shapeOf[chain[0]] == .diamond
            g.dstDiamond = shapeOf[chain[chain.count - 1]] == .diamond
            geos[index] = g
            if !g.srcDiamond {
                buckets[faceKey(chain[0], bottom: g.exitBottom), default: []]
                    .append((index, true, horizontal ? g.firstNext.y : g.firstNext.x))
            }
            if !g.dstDiamond {
                // The target port wants to sit where the edge actually descends,
                // not under the source's centre. For a routed (dummy) edge that
                // is the last dummy's channel; for an adjacent edge it's where
                // the source exits — so the two ends line up into a straight run
                // or a single clean bend instead of an S back to the source x.
                let wanted: CGFloat
                if g.dummyCenters.isEmpty {
                    wanted = sourceExitCross(srcDiamond: g.srcDiamond, from: ff, toward: g.firstNext)
                } else {
                    wanted = horizontal ? g.lastPrev.y : g.lastPrev.x
                }
                buckets[faceKey(chain[chain.count - 1], bottom: g.enterBottom), default: []]
                    .append((index, false, wanted))
            }
        }

        // Place each face port at the coordinate it actually wants (its channel
        // / the direction of its far endpoint), then push neighbours apart only
        // enough to keep a minimum separation. A lone edge keeps its channel and
        // stays straight; two edges that want opposite sides stay on opposite
        // sides — evenly centering them made a node's incoming edge and its
        // outgoing back edge squish together and curl into a tuning-fork.
        var portCross: [String: CGFloat] = [:]   // "edge|isSource" -> cross
        func portKey(_ edge: Int, _ isSource: Bool) -> String { "\(edge)|\(isSource)" }
        for (key, ports) in buckets {
            let node = String(key.split(separator: "|")[0])
            let f = frames[node]!
            let (lo, hi): (CGFloat, CGFloat) = horizontal
                ? (f.minY + min(f.height * 0.22, f.height / 2), f.maxY - min(f.height * 0.22, f.height / 2))
                : (f.minX + min(f.width * 0.22, f.width / 2), f.maxX - min(f.width * 0.22, f.width / 2))
            let sorted = ports.sorted { $0.wanted < $1.wanted }
            let minSep = min(flowchartPortSep, (hi - lo) / CGFloat(max(sorted.count, 1)))
            var pos = sorted.map { min(max($0.wanted, lo), hi) }
            for i in 1..<max(pos.count, 1) where pos[i] < pos[i - 1] + minSep {
                pos[i] = pos[i - 1] + minSep
            }
            if let last = pos.last, last > hi {   // block overflowed; slide it left
                let shift = last - hi
                for i in pos.indices { pos[i] -= shift }
                for i in 1..<max(pos.count, 1) where pos[i] < pos[i - 1] + minSep {
                    pos[i] = pos[i - 1] + minSep
                }
            }
            for (i, p) in sorted.enumerated() { portCross[portKey(p.edge, p.isSource)] = pos[i] }
        }

        // Give each edge entering the same target a distinct jog track, ordered
        // by its approach position, so their bend corners don't nest into one
        // another (the "double corner" where two edges turn into one box).
        var jogBias = [CGFloat](repeating: 0, count: chart.edges.count)
        var targetGroups: [String: [Int]] = [:]
        for index in chart.edges.indices where geos[index].valid {
            targetGroups[geos[index].chain[geos[index].chain.count - 1], default: []].append(index)
        }
        for idxs in targetGroups.values where idxs.count > 1 {
            let ordered = idxs.sorted {
                (horizontal ? geos[$0].lastPrev.y : geos[$0].lastPrev.x)
                    < (horizontal ? geos[$1].lastPrev.y : geos[$1].lastPrev.x)
            }
            let n = ordered.count
            for (rank, idx) in ordered.enumerated() {
                jogBias[idx] = (CGFloat(rank) - CGFloat(n - 1) / 2) * flowchartJogTrack
            }
        }

        var routes = [[CGPoint]](repeating: [], count: chart.edges.count)
        for index in chart.edges.indices {
            let g = geos[index]
            guard g.valid else { continue }

            // Head (leaves the source) and tail (enters the target). A decision
            // uses vertex ports; every other shape uses its distributed face port.
            let head: [CGPoint]
            if g.srcDiamond {
                let (v, stub) = diamondPort(g.fromFrame, toward: g.firstNext, isSource: true)
                head = stub.map { [v, $0] } ?? [v]
            } else {
                let cross = portCross[portKey(index, true)] ?? (horizontal ? g.firstNext.y : g.firstNext.x)
                head = [attach(g.chain[0], cross: cross, rightOrBottom: g.exitBottom, isSource: true)]
            }
            let tail: [CGPoint]
            if g.dstDiamond {
                let (v, stub) = diamondPort(g.toFrame, toward: g.lastPrev, isSource: false)
                tail = stub.map { [$0, v] } ?? [v]
            } else {
                let cross = portCross[portKey(index, false)] ?? (horizontal ? g.lastPrev.y : g.lastPrev.x)
                tail = [attach(g.chain[g.chain.count - 1], cross: cross, rightOrBottom: g.enterBottom, isSource: false)]
            }

            routes[index] = routePolyline(head + g.dummyCenters + tail, horizontal: horizontal, jogBias: jogBias[index])
        }

        // Separate coincident main-axis runs: two different edges whose runs
        // share a track (an incoming edge's descent and a back edge's channel
        // land on one node column) read as a single doubled line. Nudge the
        // movable run — one whose ends are interior bends, not anchored to a
        // box — aside to restore the minimum separation.
        separateRuns(&routes, horizontal: horizontal, minSep: flowchartPortSep)

        var placedEdges: [FlowchartLayout.PlacedEdge] = []
        var crossLimit = flowchartMargin + crossExtent
        for f in frames.values { crossLimit = max(crossLimit, horizontal ? f.maxY : f.maxX) }
        for (index, edge) in chart.edges.enumerated() {
            let pts = routes[index]
            guard pts.count >= 2 else {
                let p = CGPoint.zero
                placedEdges.append(FlowchartLayout.PlacedEdge(
                    start: p, end: p, points: [p, p],
                    label: edge.label, dashed: edge.dashed, hasArrow: edge.hasArrow))
                continue
            }
            for p in pts { crossLimit = max(crossLimit, horizontal ? p.y : p.x) }
            placedEdges.append(FlowchartLayout.PlacedEdge(
                start: pts.first!, end: pts.last!, points: pts,
                label: edge.label, dashed: edge.dashed, hasArrow: edge.hasArrow))
        }
        return (placedEdges, crossLimit)
    }

    /// Connects waypoints with an orthogonal polyline. For a top-down chart the
    /// vertical runs sit at each waypoint's x (the reserved dummy channels) and
    /// the horizontal jogs happen between consecutive waypoints — i.e. in the
    /// gaps between layers, never across a node's row. `jogBias` shifts each jog
    /// off the gap midpoint (clamped to stay in the gap) so concurrent edges
    /// crossing the same gap can take distinct tracks and their bend corners
    /// don't nest. Collinear runs are merged so straight edges stay two-point.
    static func routePolyline(_ waypoints: [CGPoint], horizontal: Bool, jogBias: CGFloat = 0) -> [CGPoint] {
        guard waypoints.count >= 2 else { return waypoints }
        var pts: [CGPoint] = [waypoints[0]]
        for i in 0..<(waypoints.count - 1) {
            let a = waypoints[i], b = waypoints[i + 1]
            if horizontal {
                if abs(a.y - b.y) > 0.5 {
                    let jx = min(max((a.x + b.x) / 2 + jogBias, min(a.x, b.x)), max(a.x, b.x))
                    pts.append(CGPoint(x: jx, y: a.y))
                    pts.append(CGPoint(x: jx, y: b.y))
                }
            } else if abs(a.x - b.x) > 0.5 {
                let midY = (a.y + b.y) / 2
                let jy = min(max(midY + jogBias, min(a.y, b.y)), max(a.y, b.y))
                pts.append(CGPoint(x: a.x, y: jy))
                pts.append(CGPoint(x: b.x, y: jy))
            }
        }
        pts.append(waypoints[waypoints.count - 1])
        return simplifyCollinear(pts)
    }

    /// Pushes apart main-axis runs (vertical for TD, horizontal for LR) that
    /// belong to different edges yet share a track — the same cross coordinate
    /// with an overlapping extent — so two edges don't render as one doubled
    /// line. Only a *movable* run is nudged: one whose two endpoints are both
    /// interior bends, so shifting its cross coordinate is absorbed by the
    /// connecting cross-axis segments without detaching an endpoint from a box.
    /// A few relaxation passes let a nudge that creates a fresh clash settle.
    static func separateRuns(_ routes: inout [[CGPoint]], horizontal: Bool, minSep: CGFloat) {
        let tol: CGFloat = 4
        func cross(_ p: CGPoint) -> CGFloat { horizontal ? p.y : p.x }
        func main(_ p: CGPoint) -> CGFloat { horizontal ? p.x : p.y }
        // Is segment (a,b) a main-axis run? (constant cross, changing main.)
        func isRun(_ a: CGPoint, _ b: CGPoint) -> Bool {
            abs(cross(a) - cross(b)) < 0.5 && abs(main(a) - main(b)) > tol
        }
        for _ in 0..<4 {
            // Collect runs: (edge, segment index, cross, mainLo, mainHi, movable).
            var runs: [(e: Int, i: Int, c: CGFloat, lo: CGFloat, hi: CGFloat, movable: Bool)] = []
            for (e, pts) in routes.enumerated() where pts.count >= 2 {
                for i in 0..<(pts.count - 1) where isRun(pts[i], pts[i + 1]) {
                    let movable = i > 0 && i + 1 < pts.count - 1
                    runs.append((e, i, cross(pts[i]),
                                 min(main(pts[i]), main(pts[i + 1])),
                                 max(main(pts[i]), main(pts[i + 1])), movable))
                }
            }
            var moved = false
            for a in 0..<runs.count {
                for b in (a + 1)..<runs.count where runs[a].e != runs[b].e {
                    let ra = runs[a], rb = runs[b]
                    guard abs(ra.c - rb.c) < tol else { continue }          // same track
                    guard min(ra.hi, rb.hi) - max(ra.lo, rb.lo) > tol else { continue } // overlap
                    let t = ra.movable ? a : (rb.movable ? b : -1)
                    guard t >= 0 else { continue }
                    let other = (t == a ? rb : ra)
                    let s = runs[t]
                    let dir: CGFloat = s.c >= other.c ? 1 : -1              // push away
                    let shift = dir * minSep - (s.c - other.c)
                    routes[s.e][s.i] = offsetCross(routes[s.e][s.i], by: shift, horizontal: horizontal)
                    routes[s.e][s.i + 1] = offsetCross(routes[s.e][s.i + 1], by: shift, horizontal: horizontal)
                    runs[t].c += shift
                    moved = true
                }
            }
            if !moved { break }
        }
        for e in routes.indices { routes[e] = simplifyCollinear(routes[e]) }
    }

    private static func offsetCross(_ p: CGPoint, by d: CGFloat, horizontal: Bool) -> CGPoint {
        horizontal ? CGPoint(x: p.x, y: p.y + d) : CGPoint(x: p.x + d, y: p.y)
    }

    /// Drops points that lie on a straight run with their neighbours, and exact
    /// duplicates, so a polyline carries only its real bends.
    static func simplifyCollinear(_ pts: [CGPoint]) -> [CGPoint] {
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

        // The title is centred horizontally on the disk's centre (the renderer
        // draws it there). A long title is far wider than the disk, so unless
        // the disk is padded away from the left edge its left half spills off
        // canvas. Reserve enough left padding that the whole title clears x = 0,
        // and widen the canvas so its right half is bounded too. The width is
        // estimated as the larger of the measured glyph run and the scene
        // lowering's estimatedLabelSize heuristic, so both the render and the
        // geometry check fit.
        let titleWidth: CGFloat = pie.title.map { title in
            max(measure(title, 12.5).width, DiagramScene.estimatedLabelSize(title).width)
        } ?? 0
        let leftPad = max(margin, titleWidth / 2 - radius + margin)
        let centerX = leftPad + radius
        let legendX = centerX + radius + 28

        let contentRight = legendX + legendWidth + margin
        let titleRight = centerX + titleWidth / 2 + margin
        let width = max(contentRight, titleRight)
        let height = margin + titleHeight + max(radius * 2, legendHeight) + margin
        return PieLayout(
            size: CGSize(width: width, height: height),
            center: CGPoint(x: centerX, y: margin + titleHeight + radius),
            radius: radius,
            title: pie.title,
            slices: slices,
            legendOrigin: CGPoint(
                x: legendX,
                y: margin + titleHeight + max(0, (radius * 2 - legendHeight) / 2)
            )
        )
    }

}
