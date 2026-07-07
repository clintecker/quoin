import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif

/// Geometry for a C4 diagram: elements as uniform-width labelled boxes placed
/// in a simple relationship-layered grid, with straight labelled arrows
/// between them. People carry a small drawn "head" (the renderer adds it above
/// the box top). Pure geometry — the renderer only draws.
public struct C4Layout: Sendable {
    public struct Box: Sendable {
        public let frame: CGRect
        /// e.g. «Person», «External System», «Container».
        public let stereotype: String
        /// Bold title, word-wrapped to the box width.
        public let titleLines: [String]
        /// Technology tag + description, word-wrapped.
        public let detailLines: [String]
        public let isPerson: Bool
        public let external: Bool
        public let colorIndex: Int
    }

    public struct Edge: Sendable {
        public let from: CGPoint
        public let to: CGPoint
        public let label: String?
    }

    public let size: CGSize
    public let title: String?
    public let boxes: [Box]
    public let edges: [Edge]
}

extension DiagramLayoutEngine {

    public static func layout(_ diagram: C4Diagram, measure: DiagramTextMeasurer) -> C4Layout {
        let margin: CGFloat = 16
        let titleHeight: CGFloat = diagram.title == nil ? 0 : 24
        let boxWidth: CGFloat = 176
        let pad: CGFloat = 10
        let textWidth = boxWidth - pad * 2
        let stereoH: CGFloat = 13
        let titleGap: CGFloat = 3
        let titleLineH: CGFloat = 16
        let detailLineH: CGFloat = 13
        let hGap: CGFloat = 26
        let vGap: CGFloat = 40          // room for arrows + a person's head
        let maxCols = 6

        // Greedy word-wrap capped at `maxLines`; the last kept line absorbs the
        // remainder so nothing is silently dropped.
        func wrap(_ text: String, fontSize: Double, maxLines: Int) -> [String] {
            guard maxLines > 0 else { return [] }
            let words = text.split(separator: " ").map(String.init)
            guard !words.isEmpty else { return [] }
            var lines: [String] = []
            var current = ""
            for word in words {
                let candidate = current.isEmpty ? word : current + " " + word
                if current.isEmpty || measure(candidate, fontSize).width <= textWidth {
                    current = candidate
                } else {
                    lines.append(current)
                    current = word
                    if lines.count == maxLines - 1 { break }
                }
            }
            if !current.isEmpty { lines.append(current) }
            return Array(lines.prefix(maxLines))
        }

        func stereotype(_ e: C4Diagram.Element) -> String {
            let base: String
            switch e.kind {
            case .person: base = "Person"
            case .system: base = "System"
            case .container: base = "Container"
            case .component: base = "Component"
            }
            return "\u{00AB}\(e.external ? "External " : "")\(base)\u{00BB}"
        }

        func colorIndex(_ e: C4Diagram.Element) -> Int {
            switch e.kind {
            case .person: return 0
            case .system: return 1
            case .container: return 2
            case .component: return 3
            }
        }

        // Per-element content + measured height.
        struct Content {
            let stereotype: String
            let titleLines: [String]
            let detailLines: [String]
            let isPerson: Bool
            let external: Bool
            let colorIndex: Int
            let height: CGFloat
        }

        let contents: [Content] = diagram.elements.map { e in
            let titleLines = wrap(e.label, fontSize: nodeFontSize, maxLines: 2)
            var details: [String] = []
            if let tech = e.technology, !tech.isEmpty { details.append("[\(tech)]") }
            if let d = e.descr, !d.isEmpty {
                details += wrap(d, fontSize: labelFontSize, maxLines: max(0, 3 - details.count))
            }
            let titleCount = max(titleLines.count, 1)
            let height = pad + stereoH + titleGap + CGFloat(titleCount) * titleLineH
                + (details.isEmpty ? 0 : 4 + CGFloat(details.count) * detailLineH) + pad
            return Content(
                stereotype: stereotype(e),
                titleLines: titleLines.isEmpty ? [e.label] : titleLines,
                detailLines: details,
                isPerson: e.kind == .person,
                external: e.external,
                colorIndex: colorIndex(e),
                height: height
            )
        }

        let aliasIndex = Dictionary(diagram.elements.enumerated().map { ($1.alias, $0) },
                                    uniquingKeysWith: { a, _ in a })
        let n = diagram.elements.count

        // Relationship layering: longest-path from sources, capped so cycles
        // can't run the layer count away.
        var adjacency: [(Int, Int)] = []
        for r in diagram.relations {
            guard let f = aliasIndex[r.from], let t = aliasIndex[r.to], f != t else { continue }
            adjacency.append((f, t))
        }
        var layer = [Int](repeating: 0, count: n)
        for _ in 0..<max(n, 1) {
            var changed = false
            for (f, t) in adjacency where layer[t] < layer[f] + 1 && layer[f] + 1 <= n {
                layer[t] = layer[f] + 1
                changed = true
            }
            if !changed { break }
        }

        // Group element indices by layer (appearance order within a layer),
        // then split oversized layers into chunks so no visual row overflows.
        let maxLayer = layer.max() ?? 0
        var visualRows: [[Int]] = []
        for l in 0...maxLayer {
            let inLayer = (0..<n).filter { layer[$0] == l }
            guard !inLayer.isEmpty else { continue }
            var i = 0
            while i < inLayer.count {
                visualRows.append(Array(inLayer[i..<min(i + maxCols, inLayer.count)]))
                i += maxCols
            }
        }
        if visualRows.isEmpty { visualRows = [Array(0..<n)] }

        let widestCols = visualRows.map(\.count).max() ?? 1
        let canvasWidth = max(220,
            margin * 2 + CGFloat(widestCols) * boxWidth + CGFloat(widestCols - 1) * hGap)

        // Place boxes row by row, each row centered horizontally, top-aligned
        // within the row's tallest box.
        var frames = [CGRect](repeating: .zero, count: n)
        var y = margin + titleHeight + 12       // +12: headroom for people in row 0
        for row in visualRows {
            let rowHeight = row.map { contents[$0].height }.max() ?? 0
            let rowWidth = CGFloat(row.count) * boxWidth + CGFloat(row.count - 1) * hGap
            var x = (canvasWidth - rowWidth) / 2
            for idx in row {
                frames[idx] = CGRect(x: x, y: y, width: boxWidth, height: contents[idx].height)
                x += boxWidth + hGap
            }
            y += rowHeight + vGap
        }
        let canvasHeight = y - vGap + margin

        let boxes: [C4Layout.Box] = (0..<n).map { i in
            let c = contents[i]
            return C4Layout.Box(
                frame: frames[i],
                stereotype: c.stereotype,
                titleLines: c.titleLines,
                detailLines: c.detailLines,
                isPerson: c.isPerson,
                external: c.external,
                colorIndex: c.colorIndex
            )
        }

        // Straight arrows between box borders (line from center to center,
        // clipped to each rectangle's edge).
        func borderPoint(_ rect: CGRect, toward target: CGPoint) -> CGPoint {
            let c = CGPoint(x: rect.midX, y: rect.midY)
            let dx = target.x - c.x, dy = target.y - c.y
            if dx == 0 && dy == 0 { return c }
            let halfW = rect.width / 2, halfH = rect.height / 2
            let scaleX = dx == 0 ? CGFloat.greatestFiniteMagnitude : halfW / abs(dx)
            let scaleY = dy == 0 ? CGFloat.greatestFiniteMagnitude : halfH / abs(dy)
            let scale = min(scaleX, scaleY)
            return CGPoint(x: c.x + dx * scale, y: c.y + dy * scale)
        }

        var edges: [C4Layout.Edge] = []
        for r in diagram.relations {
            guard let f = aliasIndex[r.from], let t = aliasIndex[r.to], f != t else { continue }
            let fc = CGPoint(x: frames[f].midX, y: frames[f].midY)
            let tc = CGPoint(x: frames[t].midX, y: frames[t].midY)
            let text = r.technology.map { r.label.isEmpty ? "[\($0)]" : "\(r.label) [\($0)]" } ?? r.label
            edges.append(C4Layout.Edge(
                from: borderPoint(frames[f], toward: tc),
                to: borderPoint(frames[t], toward: fc),
                label: text.isEmpty ? nil : text
            ))
        }

        let width = min(max(canvasWidth, 1), 3999)
        let height = min(max(canvasHeight, 1), 3999)
        return C4Layout(size: CGSize(width: width, height: height),
                        title: diagram.title, boxes: boxes, edges: edges)
    }
}
