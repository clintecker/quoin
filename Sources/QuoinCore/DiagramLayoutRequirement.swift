import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif

/// Geometry for a requirement diagram: labelled boxes (requirements show their
/// stereotype, name, id, wrapped text, risk, and verify method; elements show
/// their type and doc reference) placed in a simple grid, with straight
/// verb-labelled connectors between related boxes. Pure geometry — the renderer
/// only draws.
public struct RequirementLayout: Sendable {

    public struct Box: Sendable {
        public let frame: CGRect
        /// Stereotype line, e.g. "«requirement»" or "«element»".
        public let stereotype: String
        public let name: String
        /// Pre-wrapped detail rows drawn under the name separator.
        public let detailLines: [String]
        public let isElement: Bool
        public let colorIndex: Int
    }

    public struct Edge: Sendable {
        public let from: CGPoint
        public let to: CGPoint
        public let label: String
    }

    public let size: CGSize
    public let boxes: [Box]
    public let edges: [Edge]
}

extension DiagramLayoutEngine {

    public static func layout(_ diagram: RequirementDiagram, measure: DiagramTextMeasurer) -> RequirementLayout {
        let margin: CGFloat = 16
        let boxWidth: CGFloat = 204
        let hGap: CGFloat = 40
        let vGap: CGFloat = 44
        let padding: CGFloat = 11
        let stereoH: CGFloat = 14
        let nameH: CGFloat = 20
        let sepGap: CGFloat = 8
        let lineH: CGFloat = 15
        let textWidth = boxWidth - padding * 2

        // Greedy word-wrap of a detail value, capped at `maxLines`.
        func wrap(_ text: String, maxLines: Int) -> [String] {
            let words = text.split(separator: " ").map(String.init)
            guard !words.isEmpty else { return [] }
            var lines: [String] = []
            var current = ""
            for word in words {
                let candidate = current.isEmpty ? word : current + " " + word
                if current.isEmpty || measure(candidate, labelFontSize).width <= textWidth {
                    current = candidate
                } else {
                    lines.append(current)
                    current = word
                    if lines.count == maxLines - 1 { break }
                }
            }
            if !current.isEmpty { lines.append(current) }
            return lines
        }

        // Build the drawable content (stereotype/name/detail rows) for every
        // requirement and element, in a stable order (requirements first).
        struct Content {
            let name: String
            let stereotype: String
            let details: [String]
            let isElement: Bool
            let colorIndex: Int
        }
        var contents: [Content] = []

        for req in diagram.requirements {
            var details: [String] = []
            if let id = req.id { details.append("id: \(id)") }
            if let text = req.text { details.append(contentsOf: wrap(text, maxLines: 3)) }
            if let risk = req.risk { details.append("risk: \(risk)") }
            if let verify = req.verifyMethod { details.append("verify: \(verify)") }
            let colorIndex = [RequirementDiagram.Kind.requirement, .functional, .performance,
                              .interface, .physical, .designConstraint]
                .firstIndex(of: req.kind) ?? 0
            contents.append(Content(name: req.name, stereotype: "«\(req.kind.rawValue)»",
                                    details: details, isElement: false, colorIndex: colorIndex))
        }
        for element in diagram.elements {
            var details: [String] = []
            if let type = element.type { details.append("type: \(type)") }
            if let docRef = element.docRef { details.append(contentsOf: wrap("ref: \(docRef)", maxLines: 2)) }
            contents.append(Content(name: element.name, stereotype: "«element»",
                                    details: details, isElement: true, colorIndex: 7))
        }

        func boxHeight(_ detailCount: Int) -> CGFloat {
            padding + stereoH + nameH + sepGap + CGFloat(detailCount) * lineH + padding
        }

        // Grid: at most three columns, wrapping in content order.
        let count = contents.count
        let columns = max(1, count <= 1 ? 1 : (count <= 4 ? 2 : 3))

        var boxes: [RequirementLayout.Box] = []
        var frameByName: [String: CGRect] = [:]
        var y = margin
        var row = 0
        while row * columns < count {
            let start = row * columns
            let end = min(start + columns, count)
            let rowHeight = (start..<end).map { boxHeight(contents[$0].details.count) }.max() ?? 0
            for i in start..<end {
                let col = i - start
                let x = margin + CGFloat(col) * (boxWidth + hGap)
                let frame = CGRect(x: x, y: y, width: boxWidth, height: rowHeight)
                let c = contents[i]
                boxes.append(RequirementLayout.Box(
                    frame: frame, stereotype: c.stereotype, name: c.name,
                    detailLines: c.details, isElement: c.isElement, colorIndex: c.colorIndex))
                frameByName[c.name] = frame
            }
            y += rowHeight + vGap
            row += 1
        }

        // Where a straight center-to-center segment exits `rect`.
        func exitPoint(from rect: CGRect, toward target: CGPoint) -> CGPoint {
            let c = CGPoint(x: rect.midX, y: rect.midY)
            let dx = target.x - c.x, dy = target.y - c.y
            if dx == 0 && dy == 0 { return c }
            let halfW = rect.width / 2, halfH = rect.height / 2
            let scale: CGFloat = abs(dx) * halfH > abs(dy) * halfW
                ? halfW / abs(dx)
                : halfH / abs(dy)
            return CGPoint(x: c.x + dx * scale, y: c.y + dy * scale)
        }

        var edges: [RequirementLayout.Edge] = []
        for relation in diagram.relations {
            guard let sourceFrame = frameByName[relation.source],
                  let destFrame = frameByName[relation.dest] else { continue }
            let sourceCenter = CGPoint(x: sourceFrame.midX, y: sourceFrame.midY)
            let destCenter = CGPoint(x: destFrame.midX, y: destFrame.midY)
            edges.append(RequirementLayout.Edge(
                from: exitPoint(from: sourceFrame, toward: destCenter),
                to: exitPoint(from: destFrame, toward: sourceCenter),
                label: relation.kind.rawValue))
        }

        let usedColumns = min(columns, max(count, 1))
        let width = margin + CGFloat(usedColumns) * boxWidth + CGFloat(usedColumns - 1) * hGap + margin
        let height = max(y - vGap + margin, margin * 2 + 1)
        return RequirementLayout(
            size: CGSize(width: min(width, 3990), height: min(height, 3990)),
            boxes: boxes,
            edges: edges)
    }
}
