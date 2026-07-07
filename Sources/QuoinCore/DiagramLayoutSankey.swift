import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif

extension DiagramLayoutEngine {

    /// Lays out a Sankey flow diagram left-to-right. Nodes are assigned to
    /// columns by longest-path depth from the sources; each node's bar height
    /// is proportional to its total flow (max of in/out). Links become bands
    /// whose thickness equals their value, stacked down each node's edges.
    /// Pure geometry — the renderer only fills bands, bars, and labels.
    public static func layout(_ d: SankeyDiagram, measure: DiagramTextMeasurer) -> SankeyLayout {
        let margin: CGFloat = 16
        let thickness: CGFloat = 16
        let columnSpacing: CGFloat = 150
        let nodeGap: CGFloat = 12
        let labelSize: Double = 11
        let labelPad: CGFloat = 6
        let minBarHeight: CGFloat = 6

        let names = d.nodes
        let n = names.count
        guard n > 0 else {
            return SankeyLayout(size: CGSize(width: 120, height: 80), nodes: [], links: [])
        }
        let index = Dictionary(uniqueKeysWithValues: names.enumerated().map { ($1, $0) })

        // Flow totals and predecessor lists.
        var inValue = [Double](repeating: 0, count: n)
        var outValue = [Double](repeating: 0, count: n)
        var incoming: [[Int]] = Array(repeating: [], count: n)
        for link in d.links {
            guard let s = index[link.source], let t = index[link.target] else { continue }
            outValue[s] += link.value
            inValue[t] += link.value
            incoming[t].append(s)
        }
        let nodeValue = (0..<n).map { max(inValue[$0], outValue[$0], 0.0001) }

        // Longest-path depth from sources, with a cycle guard.
        var depthMemo = [Int?](repeating: nil, count: n)
        var visiting = [Bool](repeating: false, count: n)
        func depth(_ i: Int) -> Int {
            if let cached = depthMemo[i] { return cached }
            if visiting[i] { return 0 }
            visiting[i] = true
            var best = 0
            for p in incoming[i] { best = max(best, depth(p) + 1) }
            visiting[i] = false
            depthMemo[i] = best
            return best
        }
        let depths = (0..<n).map { depth($0) }
        let maxDepth = depths.max() ?? 0

        // Group node indices by column, preserving first-appearance order.
        var columns: [[Int]] = Array(repeating: [], count: maxDepth + 1)
        for i in 0..<n { columns[depths[i]].append(i) }

        // Choose a value→pixel scale so the busiest column fits a target height.
        let targetHeight: CGFloat = 360
        var maxColValue = 0.0001
        for col in columns { maxColValue = max(maxColValue, col.reduce(0) { $0 + nodeValue[$1] }) }
        let maxColCount = columns.map(\.count).max() ?? 1
        var scale = (targetHeight - CGFloat(max(maxColCount - 1, 0)) * nodeGap) / CGFloat(maxColValue)
        scale = min(max(scale, 3), 60)

        func barHeight(_ i: Int) -> CGFloat { max(CGFloat(nodeValue[i]) * scale, minBarHeight) }

        // Column pixel heights and the tallest (content) height.
        let colHeights: [CGFloat] = columns.map { col in
            guard !col.isEmpty else { return 0 }
            return CGFloat(col.count - 1) * nodeGap + col.reduce(CGFloat(0)) { $0 + barHeight($1) }
        }
        let contentHeight = max(colHeights.max() ?? thickness, thickness)

        // Horizontal room for outboard labels.
        func maxLabelWidth(_ col: [Int]) -> CGFloat {
            col.reduce(CGFloat(0)) { max($0, measure(names[$1], labelSize).width) }
        }
        let leftRoom = maxLabelWidth(columns.first ?? []) + labelPad
        let rightRoom = maxLabelWidth(columns.last ?? []) + labelPad
        let originX = margin + leftRoom
        let topOffset = margin

        // Place node bars: each column centered vertically, stacked downward.
        var rects = [CGRect](repeating: .zero, count: n)
        for (c, col) in columns.enumerated() {
            let colX = originX + CGFloat(c) * columnSpacing
            var y = topOffset + (contentHeight - colHeights[c]) / 2
            for i in col {
                let h = barHeight(i)
                rects[i] = CGRect(x: colX, y: y, width: thickness, height: h)
                y += h + nodeGap
            }
        }

        // Bands: stack outgoing on each source's right edge, incoming on each
        // target's left edge, in link declaration order.
        var outOffset = [CGFloat](repeating: 0, count: n)
        var inOffset = [CGFloat](repeating: 0, count: n)
        var links: [SankeyLayout.Link] = []
        for link in d.links {
            guard let s = index[link.source], let t = index[link.target] else { continue }
            let w = CGFloat(link.value) * scale
            let sTop = rects[s].minY + outOffset[s]
            let tTop = rects[t].minY + inOffset[t]
            outOffset[s] += w
            inOffset[t] += w
            links.append(SankeyLayout.Link(
                sourceTop: CGPoint(x: rects[s].maxX, y: sTop),
                sourceBottom: CGPoint(x: rects[s].maxX, y: sTop + w),
                targetTop: CGPoint(x: rects[t].minX, y: tTop),
                targetBottom: CGPoint(x: rects[t].minX, y: tTop + w),
                colorIndex: s
            ))
        }

        // Node bars + their labels (leftmost column labels sit left, others
        // right, just outboard of the bar and centered on it).
        var nodes: [SankeyLayout.Node] = []
        for i in 0..<n {
            let r = rects[i]
            let labelWidth = measure(names[i], labelSize).width
            let labelCenter: CGPoint
            if depths[i] == 0 {
                labelCenter = CGPoint(x: r.minX - labelPad - labelWidth / 2, y: r.midY)
            } else {
                labelCenter = CGPoint(x: r.maxX + labelPad + labelWidth / 2, y: r.midY)
            }
            nodes.append(SankeyLayout.Node(
                label: names[i], rect: r, colorIndex: i, labelCenter: labelCenter
            ))
        }

        let rawWidth = originX + CGFloat(maxDepth) * columnSpacing + thickness + rightRoom + margin
        let rawHeight = topOffset + contentHeight + margin
        let size = CGSize(
            width: min(max(rawWidth, 80), 3800),
            height: min(max(rawHeight, 60), 3800)
        )
        return SankeyLayout(size: size, nodes: nodes, links: links)
    }
}

public struct SankeyLayout: Sendable {
    public struct Node: Sendable {
        public let label: String
        public let rect: CGRect
        public let colorIndex: Int
        public let labelCenter: CGPoint
    }

    /// A flow band; the renderer fills the region between the two cubic edges.
    public struct Link: Sendable {
        public let sourceTop: CGPoint
        public let sourceBottom: CGPoint
        public let targetTop: CGPoint
        public let targetBottom: CGPoint
        public let colorIndex: Int
    }

    public let size: CGSize
    public let nodes: [Node]
    public let links: [Link]
}
