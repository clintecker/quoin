import Foundation

/// Parsed Mermaid diagrams — phase D1 of the native engine: flowcharts,
/// sequence diagrams, and pie charts. Anything else returns nil and the
/// renderer keeps the styled-source fallback.
public enum MermaidDiagram: Hashable, Sendable {
    case flowchart(Flowchart)
    case sequence(SequenceDiagram)
    case pie(PieChart)
}

// MARK: - Models

public struct Flowchart: Hashable, Sendable {
    public enum Direction: String, Sendable {
        case topDown = "TD"
        case leftRight = "LR"
        case bottomTop = "BT"
        case rightLeft = "RL"
    }

    public enum NodeShape: Hashable, Sendable {
        case rectangle      // A[Label]
        case rounded        // A(Label)
        case stadium        // A([Label])
        case diamond        // A{Label}
        case circle         // A((Label))
    }

    public struct Node: Hashable, Sendable, Identifiable {
        public let id: String
        public var label: String
        public var shape: NodeShape
    }

    public struct Edge: Hashable, Sendable {
        public let from: String
        public let to: String
        public var label: String?
        public var dashed: Bool
        public var hasArrow: Bool
    }

    public var direction: Direction
    public var nodes: [Node]
    public var edges: [Edge]
}

public struct SequenceDiagram: Hashable, Sendable {
    public struct Participant: Hashable, Sendable, Identifiable {
        public let id: String
        public var label: String
    }

    public struct Message: Hashable, Sendable {
        public let from: String
        public let to: String
        public var text: String
        public var dashed: Bool
    }

    public var participants: [Participant]
    public var messages: [Message]
}

public struct PieChart: Hashable, Sendable {
    public struct Slice: Hashable, Sendable {
        public let label: String
        public let value: Double
    }

    public var title: String?
    public var slices: [Slice]
}

// MARK: - Parser

public enum MermaidParser {

    /// Parses D1 diagram types; nil for unsupported types or unparseable
    /// input (the caller falls back to styled source).
    public static func parse(_ source: String) -> MermaidDiagram? {
        let lines = source
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("%%") }
        guard let header = lines.first else { return nil }

        if header.hasPrefix("graph") || header.hasPrefix("flowchart") {
            return parseFlowchart(header: header, body: Array(lines.dropFirst()))
                .map { .flowchart($0) }
        }
        if header.hasPrefix("sequenceDiagram") {
            return parseSequence(body: Array(lines.dropFirst())).map { .sequence($0) }
        }
        if header.hasPrefix("pie") {
            return parsePie(header: header, body: Array(lines.dropFirst())).map { .pie($0) }
        }
        return nil
    }

    // MARK: Flowchart

    static func parseFlowchart(header: String, body: [String]) -> Flowchart? {
        let parts = header.split(separator: " ")
        let direction = parts.count > 1
            ? Flowchart.Direction(rawValue: String(parts[1]).uppercased()) ?? .topDown
            : .topDown

        var nodes: [String: Flowchart.Node] = [:]
        var order: [String] = []
        var edges: [Flowchart.Edge] = []

        func note(_ node: Flowchart.Node) {
            if let existing = nodes[node.id] {
                // A later declaration with an explicit label wins over a bare id.
                if node.label != node.id || existing.label == existing.id {
                    if node.label != node.id { nodes[node.id] = node }
                }
            } else {
                nodes[node.id] = node
                order.append(node.id)
            }
        }

        for line in body {
            if line.hasPrefix("subgraph") || line == "end" { continue } // v1: flatten
            if line.hasPrefix("classDef") || line.hasPrefix("class ") || line.hasPrefix("style") { continue }

            // Split on edge connectors, keeping the connector kind.
            // Supported: --> , --- , -.-> , ==> , with optional |label|.
            if let edge = parseEdgeLine(line) {
                note(edge.fromNode)
                note(edge.toNode)
                edges.append(edge.edge)
                continue
            }

            // Standalone node declaration.
            if let node = parseNodeToken(Substring(line)) {
                note(node)
            }
        }

        guard !nodes.isEmpty else { return nil }
        return Flowchart(
            direction: direction,
            nodes: order.compactMap { nodes[$0] },
            edges: edges
        )
    }

    private struct ParsedEdge {
        let fromNode: Flowchart.Node
        let toNode: Flowchart.Node
        let edge: Flowchart.Edge
    }

    private static func parseEdgeLine(_ line: String) -> ParsedEdge? {
        // Find the connector.
        let connectors: [(token: String, dashed: Bool, arrow: Bool)] = [
            ("-.->", true, true), ("==>", false, true), ("-->", false, true),
            ("-.-", true, false), ("---", false, false),
        ]
        for connector in connectors {
            guard let range = line.range(of: connector.token) else { continue }
            let left = String(line[line.startIndex..<range.lowerBound])
            var right = String(line[range.upperBound...])

            // Optional |label| immediately after the connector.
            var label: String?
            let trimmedRight = right.trimmingCharacters(in: .whitespaces)
            if trimmedRight.hasPrefix("|"), let close = trimmedRight.dropFirst().firstIndex(of: "|") {
                label = String(trimmedRight[trimmedRight.index(after: trimmedRight.startIndex)..<close])
                right = String(trimmedRight[trimmedRight.index(after: close)...])
            }

            guard let fromNode = parseNodeToken(Substring(left)),
                  let toNode = parseNodeToken(Substring(right))
            else { return nil }

            return ParsedEdge(
                fromNode: fromNode,
                toNode: toNode,
                edge: Flowchart.Edge(
                    from: fromNode.id,
                    to: toNode.id,
                    label: label,
                    dashed: connector.dashed,
                    hasArrow: connector.arrow
                )
            )
        }
        return nil
    }

    /// Parses `id`, `id[Label]`, `id(Label)`, `id([Label])`, `id{Label}`,
    /// `id((Label))`.
    static func parseNodeToken(_ token: Substring) -> Flowchart.Node? {
        let trimmed = token.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }

        var id = ""
        var index = trimmed.startIndex
        while index < trimmed.endIndex,
              trimmed[index].isLetter || trimmed[index].isNumber || trimmed[index] == "_" {
            id.append(trimmed[index])
            index = trimmed.index(after: index)
        }
        guard !id.isEmpty else { return nil }
        let rest = String(trimmed[index...])

        func stripped(_ open: String, _ close: String) -> String? {
            guard rest.hasPrefix(open), rest.hasSuffix(close),
                  rest.count >= open.count + close.count else { return nil }
            return String(rest.dropFirst(open.count).dropLast(close.count))
                .trimmingCharacters(in: .whitespaces)
                .trimmingCharacters(in: CharacterSet(charactersIn: "\""))
        }

        if rest.isEmpty {
            return Flowchart.Node(id: id, label: id, shape: .rectangle)
        }
        if let label = stripped("((", "))") {
            return Flowchart.Node(id: id, label: label, shape: .circle)
        }
        if let label = stripped("([", "])") {
            return Flowchart.Node(id: id, label: label, shape: .stadium)
        }
        if let label = stripped("[", "]") {
            return Flowchart.Node(id: id, label: label, shape: .rectangle)
        }
        if let label = stripped("(", ")") {
            return Flowchart.Node(id: id, label: label, shape: .rounded)
        }
        if let label = stripped("{", "}") {
            return Flowchart.Node(id: id, label: label, shape: .diamond)
        }
        return nil
    }

    // MARK: Sequence

    static func parseSequence(body: [String]) -> SequenceDiagram? {
        var participants: [String: SequenceDiagram.Participant] = [:]
        var order: [String] = []
        var messages: [SequenceDiagram.Message] = []

        func note(_ id: String, label: String? = nil) {
            if participants[id] == nil {
                participants[id] = SequenceDiagram.Participant(id: id, label: label ?? id)
                order.append(id)
            } else if let label {
                participants[id] = SequenceDiagram.Participant(id: id, label: label)
            }
        }

        for line in body {
            if line.hasPrefix("participant") || line.hasPrefix("actor") {
                let declaration = line
                    .replacingOccurrences(of: "participant ", with: "")
                    .replacingOccurrences(of: "actor ", with: "")
                if let asRange = declaration.range(of: " as ") {
                    let id = String(declaration[..<asRange.lowerBound]).trimmingCharacters(in: .whitespaces)
                    let label = String(declaration[asRange.upperBound...]).trimmingCharacters(in: .whitespaces)
                    note(id, label: label)
                } else {
                    note(declaration.trimmingCharacters(in: .whitespaces))
                }
                continue
            }
            if line.hasPrefix("note") || line.hasPrefix("Note") || line.hasPrefix("loop")
                || line.hasPrefix("alt") || line.hasPrefix("else") || line.hasPrefix("end")
                || line.hasPrefix("activate") || line.hasPrefix("deactivate") {
                continue // v1: skip annotations
            }

            // Messages: A->>B: text · A-->>B: text · A->B: text · A-->B: text
            for (token, dashed) in [("-->>", true), ("->>", false), ("-->", true), ("->", false)] {
                guard let range = line.range(of: token) else { continue }
                let from = String(line[..<range.lowerBound]).trimmingCharacters(in: .whitespaces)
                let remainder = String(line[range.upperBound...])
                let pieces = remainder.split(separator: ":", maxSplits: 1)
                let to = pieces.first.map { String($0).trimmingCharacters(in: .whitespaces) } ?? ""
                let text = pieces.count > 1 ? String(pieces[1]).trimmingCharacters(in: .whitespaces) : ""
                guard !from.isEmpty, !to.isEmpty else { break }
                note(from)
                note(to)
                messages.append(SequenceDiagram.Message(from: from, to: to, text: text, dashed: dashed))
                break
            }
        }

        guard !participants.isEmpty else { return nil }
        return SequenceDiagram(
            participants: order.compactMap { participants[$0] },
            messages: messages
        )
    }

    // MARK: Pie

    static func parsePie(header: String, body: [String]) -> PieChart? {
        var title: String?
        var lines = body

        // Title can ride the header line or the next line.
        if let range = header.range(of: "title ") {
            title = String(header[range.upperBound...]).trimmingCharacters(in: .whitespaces)
        } else if let first = lines.first, first.hasPrefix("title ") {
            title = String(first.dropFirst("title ".count)).trimmingCharacters(in: .whitespaces)
            lines.removeFirst()
        }

        var slices: [PieChart.Slice] = []
        for line in lines {
            // "Label" : 42.5
            guard let colon = line.lastIndex(of: ":") else { continue }
            let rawLabel = String(line[..<colon]).trimmingCharacters(in: .whitespaces)
            let label = rawLabel.trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            let valueText = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            guard !label.isEmpty, let value = Double(valueText), value >= 0 else { continue }
            slices.append(PieChart.Slice(label: label, value: value))
        }
        guard !slices.isEmpty else { return nil }
        return PieChart(title: title, slices: slices)
    }
}
