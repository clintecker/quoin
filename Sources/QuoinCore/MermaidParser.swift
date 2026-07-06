import Foundation

/// Parsed Mermaid diagrams: flowcharts, sequence diagrams, pie charts
/// (D1), plus state, class, and ER diagrams (D2). State diagrams reuse the
/// flowchart model — they are nodes and labeled transitions with two extra
/// shapes. Anything else returns nil and the renderer keeps the
/// styled-source fallback.
public enum MermaidDiagram: Hashable, Sendable {
    case flowchart(Flowchart)
    case sequence(SequenceDiagram)
    case pie(PieChart)
    case classDiagram(ClassDiagram)
    case er(ERDiagram)
    case state(StateDiagram)
    case gantt(GanttChart)
    case timeline(Timeline)
    case mindmap(Mindmap)
    case journey(UserJourney)
    case quadrant(QuadrantChart)
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
        case cylinder       // A[(Label)] — database
        case stateStart     // state diagram [*] as a source: filled dot
        case stateEnd       // state diagram [*] as a target: ringed dot
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

/// A state machine with nested composite states. Distinct from Flowchart so
/// composites can carry their own sub-diagram (with their own `[*]` entry /
/// exit), and so choice / fork / join get first-class shapes.
public struct StateDiagram: Hashable, Sendable {
    public indirect enum Kind: Hashable, Sendable {
        case simple                 // rounded state box
        case start                  // `[*]` used as a transition source
        case end                    // `[*]` used as a transition target
        case choice                 // <<choice>>: small diamond
        case fork                   // <<fork>>: bar
        case join                   // <<join>>: bar
        case composite(StateDiagram) // `state X { … }`
    }

    public struct Node: Hashable, Sendable, Identifiable {
        public let id: String
        public var label: String
        public var kind: Kind
    }

    public struct Edge: Hashable, Sendable {
        public let from: String
        public let to: String
        public var label: String?
    }

    public var direction: Flowchart.Direction
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

public struct ClassDiagram: Hashable, Sendable {
    public struct Class: Hashable, Sendable, Identifiable {
        public var id: String { name }
        public let name: String
        public var attributes: [String]
        public var methods: [String]
    }

    /// The marker draws at the `to` end of the relation; parse-time
    /// normalization flips reversed arrows so this always holds.
    public enum RelationKind: Hashable, Sendable {
        case inheritance    // hollow triangle
        case realization    // hollow triangle, dashed line
        case composition    // filled diamond
        case aggregation    // hollow diamond
        case association    // open arrowhead
        case dependency     // open arrowhead, dashed line
        case link           // plain line

        public var dashed: Bool { self == .realization || self == .dependency }
    }

    public struct Relation: Hashable, Sendable {
        public let from: String
        public let to: String
        public var kind: RelationKind
        public var label: String?
    }

    public var classes: [Class]
    public var relations: [Relation]
}

public struct ERDiagram: Hashable, Sendable {
    public enum Cardinality: Hashable, Sendable {
        case one            // ||
        case zeroOrOne      // |o / o|
        case oneOrMore      // |{ / }|
        case zeroOrMore     // o{ / }o
    }

    public struct Attribute: Hashable, Sendable {
        public let type: String
        public let name: String
    }

    public struct Entity: Hashable, Sendable, Identifiable {
        public var id: String { name }
        public let name: String
        public var attributes: [Attribute]
    }

    public struct Relation: Hashable, Sendable {
        public let from: String
        public let to: String
        public var fromCard: Cardinality
        public var toCard: Cardinality
        public var label: String
        /// Non-identifying relationships (`..`) draw dashed.
        public var identifying: Bool
    }

    public var entities: [Entity]
    public var relations: [Relation]
}

public struct PieChart: Hashable, Sendable {
    public struct Slice: Hashable, Sendable {
        public let label: String
        public let value: Double
    }

    public var title: String?
    public var slices: [Slice]
}

/// A Gantt chart: sections of time-boxed tasks. Each task's start and length
/// are resolved to a numeric **day timeline** at parse time — from an explicit
/// `dateFormat` date, an `after <id>` dependency, or an implicit "starts when
/// the previous task ends" — so the layout engine only maps days to pixels.
/// The earliest task sits at day 0. Directives that don't affect bar geometry
/// (`axisFormat`, `excludes`, `todayMarker`) are accepted and ignored; only
/// the ISO `YYYY-MM-DD` date format is understood.
public struct GanttChart: Hashable, Sendable {
    public enum Status: String, Hashable, Sendable {
        case normal, active, done, critical
    }

    public struct Task: Hashable, Sendable, Identifiable {
        public let id: String
        public var label: String
        public var section: String
        /// Offset from the project start, in days (earliest task = 0).
        public var start: Double
        /// Duration in days; 0 for a milestone.
        public var length: Double
        public var isMilestone: Bool
        public var status: Status

        public init(id: String, label: String, section: String, start: Double,
                    length: Double, isMilestone: Bool, status: Status) {
            self.id = id
            self.label = label
            self.section = section
            self.start = start
            self.length = length
            self.isMilestone = isMilestone
            self.status = status
        }

        /// Day offset of the task's end (start + length).
        public var end: Double { start + length }
    }

    public var title: String?
    public var tasks: [Task]
    /// Section names in first-appearance order.
    public var sections: [String]
}

/// A Mermaid `timeline`: an ordered list of time periods, each carrying a
/// handful of events, optionally grouped into named sections. Rendered as a
/// vertical spine (fits a document's column better than the horizontal
/// original).
public struct Timeline: Hashable, Sendable {
    public struct Period: Hashable, Sendable {
        public let label: String
        /// Owning section, or "" when the period precedes any `section`.
        public let section: String
        public let events: [String]

        public init(label: String, section: String, events: [String]) {
            self.label = label
            self.section = section
            self.events = events
        }
    }

    public var title: String?
    public var periods: [Period]
    /// Section names in first-appearance order (for stable tinting).
    public var sections: [String]

    public init(title: String?, periods: [Period], sections: [String]) {
        self.title = title
        self.periods = periods
        self.sections = sections
    }
}

/// A Mermaid `mindmap`: a single-rooted tree whose hierarchy comes from
/// indentation. Node shape decorations (`((circle))`, `[square]`, …) are
/// stripped to their label text. `[MindmapNode]` provides the recursion.
public struct Mindmap: Hashable, Sendable {
    public var root: MindmapNode
    public init(root: MindmapNode) { self.root = root }
}

public struct MindmapNode: Hashable, Sendable {
    public let label: String
    public let children: [MindmapNode]
    public init(label: String, children: [MindmapNode] = []) {
        self.label = label
        self.children = children
    }
}

/// A Mermaid `journey` (user journey): titled sections of tasks, each task
/// carrying a 1–5 satisfaction score and the actors involved.
public struct UserJourney: Hashable, Sendable {
    public struct Task: Hashable, Sendable {
        public let label: String
        /// Satisfaction, clamped to 1…5.
        public let score: Int
        public let actors: [String]
        public let section: String

        public init(label: String, score: Int, actors: [String], section: String) {
            self.label = label
            self.score = score
            self.actors = actors
            self.section = section
        }
    }

    public var title: String?
    public var tasks: [Task]
    /// Section names in first-appearance order.
    public var sections: [String]

    public init(title: String?, tasks: [Task], sections: [String]) {
        self.title = title
        self.tasks = tasks
        self.sections = sections
    }
}

/// A Mermaid `quadrantChart`: labelled points plotted in a 2×2 matrix with
/// axis-end labels and per-quadrant names. Coordinates are 0…1 (x: left→right,
/// y: bottom→top). Quadrant order matches Mermaid: 1 top-right, 2 top-left,
/// 3 bottom-left, 4 bottom-right.
public struct QuadrantChart: Hashable, Sendable {
    public struct Point: Hashable, Sendable {
        public let label: String
        public let x: Double
        public let y: Double
        public init(label: String, x: Double, y: Double) {
            self.label = label
            self.x = x
            self.y = y
        }
    }

    public var title: String?
    public var xAxisLeft: String?
    public var xAxisRight: String?
    public var yAxisBottom: String?
    public var yAxisTop: String?
    /// Quadrant names [q1, q2, q3, q4]; any may be nil.
    public var quadrants: [String?]
    public var points: [Point]

    public init(title: String?, xAxisLeft: String?, xAxisRight: String?,
                yAxisBottom: String?, yAxisTop: String?, quadrants: [String?], points: [Point]) {
        self.title = title
        self.xAxisLeft = xAxisLeft
        self.xAxisRight = xAxisRight
        self.yAxisBottom = yAxisBottom
        self.yAxisTop = yAxisTop
        self.quadrants = quadrants
        self.points = points
    }
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
        if header.hasPrefix("stateDiagram") {
            return parseState(body: Array(lines.dropFirst())).map { .state($0) }
        }
        if header.hasPrefix("classDiagram") {
            return parseClass(body: Array(lines.dropFirst())).map { .classDiagram($0) }
        }
        if header.hasPrefix("erDiagram") {
            return parseER(body: Array(lines.dropFirst())).map { .er($0) }
        }
        if header.hasPrefix("gantt") {
            return parseGantt(body: Array(lines.dropFirst())).map { .gantt($0) }
        }
        if header.hasPrefix("timeline") {
            return parseTimeline(body: Array(lines.dropFirst())).map { .timeline($0) }
        }
        if header.hasPrefix("mindmap") {
            // Indentation is significant, so re-read the raw (untrimmed) source.
            return parseMindmap(source: source).map { .mindmap($0) }
        }
        if header.hasPrefix("journey") {
            return parseJourney(body: Array(lines.dropFirst())).map { .journey($0) }
        }
        if header.hasPrefix("quadrantChart") {
            return parseQuadrant(body: Array(lines.dropFirst())).map { .quadrant($0) }
        }
        return nil
    }

    // MARK: Quadrant

    static func parseQuadrant(body: [String]) -> QuadrantChart? {
        var title: String?
        var xLeft: String?, xRight: String?, yBottom: String?, yTop: String?
        var quadrants: [String?] = [nil, nil, nil, nil]
        var points: [QuadrantChart.Point] = []

        // Splits `Low --> High` into (Low, High); a label with no arrow is the
        // low/left/bottom end alone.
        func axisEnds(_ spec: String) -> (String?, String?) {
            if let range = spec.range(of: "-->") {
                let lo = spec[..<range.lowerBound].trimmingCharacters(in: .whitespaces)
                let hi = spec[range.upperBound...].trimmingCharacters(in: .whitespaces)
                return (lo.isEmpty ? nil : lo, hi.isEmpty ? nil : hi)
            }
            let single = spec.trimmingCharacters(in: .whitespaces)
            return (single.isEmpty ? nil : single, nil)
        }

        for line in body {
            if line.hasPrefix("title ") {
                title = String(line.dropFirst("title ".count)).trimmingCharacters(in: .whitespaces)
            } else if line.hasPrefix("x-axis ") {
                (xLeft, xRight) = axisEnds(String(line.dropFirst("x-axis ".count)))
            } else if line.hasPrefix("y-axis ") {
                (yBottom, yTop) = axisEnds(String(line.dropFirst("y-axis ".count)))
            } else if line.hasPrefix("quadrant-"),
                      let digit = line.dropFirst("quadrant-".count).first,
                      let index = Int(String(digit)), (1...4).contains(index) {
                let name = line.drop { $0 != " " }.trimmingCharacters(in: .whitespaces)
                quadrants[index - 1] = name.isEmpty ? nil : name
            } else if let point = parseQuadrantPoint(line) {
                points.append(point)
            }
        }

        guard !points.isEmpty else { return nil }
        return QuadrantChart(title: title, xAxisLeft: xLeft, xAxisRight: xRight,
                             yAxisBottom: yBottom, yAxisTop: yTop, quadrants: quadrants, points: points)
    }

    /// Parses `"Label": [x, y]` (x, y in 0…1). Returns nil if malformed.
    private static func parseQuadrantPoint(_ line: String) -> QuadrantChart.Point? {
        guard let colon = line.firstIndex(of: ":"),
              let open = line.firstIndex(of: "["),
              let close = line.lastIndex(of: "]"), open < close else { return nil }
        let label = line[..<colon].trimmingCharacters(in: CharacterSet(charactersIn: " \"'"))
        guard !label.isEmpty else { return nil }
        let coords = line[line.index(after: open)..<close]
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
        guard coords.count == 2, let x = Double(coords[0]), let y = Double(coords[1]) else { return nil }
        return QuadrantChart.Point(label: label, x: min(max(x, 0), 1), y: min(max(y, 0), 1))
    }

    // MARK: Journey

    static func parseJourney(body: [String]) -> UserJourney? {
        var title: String?
        var currentSection = ""
        var sections: [String] = []
        var tasks: [UserJourney.Task] = []

        for line in body {
            if line.hasPrefix("title ") {
                title = String(line.dropFirst("title ".count)).trimmingCharacters(in: .whitespaces)
                continue
            }
            if line.hasPrefix("section ") {
                currentSection = String(line.dropFirst("section ".count)).trimmingCharacters(in: .whitespaces)
                if !currentSection.isEmpty, !sections.contains(currentSection) {
                    sections.append(currentSection)
                }
                continue
            }
            // `Task name: <score>: Actor1, Actor2`. Score and actors optional.
            let parts = line.split(separator: ":", omittingEmptySubsequences: false)
                .map { $0.trimmingCharacters(in: .whitespaces) }
            guard let label = parts.first, !label.isEmpty, parts.count >= 2 else { continue }
            let score = min(max(Int(parts[1]) ?? 3, 1), 5)
            let actors = parts.count >= 3
                ? parts[2].split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
                : []
            tasks.append(UserJourney.Task(label: label, score: score, actors: actors, section: currentSection))
        }

        guard !tasks.isEmpty else { return nil }
        return UserJourney(title: title, tasks: tasks, sections: sections)
    }

    // MARK: Mindmap

    static func parseMindmap(source: String) -> Mindmap? {
        // Collect (indentation, label) for every content line after the header,
        // preserving leading whitespace (which trimmed `lines` has discarded).
        var started = false
        var entries: [(indent: Int, label: String)] = []
        for line in source.split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if !started {
                if trimmed.hasPrefix("mindmap") { started = true }
                continue
            }
            // Skip blanks, comments, and `::icon()` / `:::class` decorations.
            if trimmed.isEmpty || trimmed.hasPrefix("%%") || trimmed.hasPrefix(":") { continue }
            let indent = line.prefix { $0 == " " || $0 == "\t" }
                .reduce(0) { $0 + ($1 == "\t" ? 2 : 1) }
            entries.append((indent, mindmapLabel(trimmed)))
        }
        guard let first = entries.first else { return nil }

        // Build the tree by indentation. A mutable class gives the needed
        // reference semantics while wiring parents to children; convert to the
        // immutable value tree at the end. The root (index 0) is never popped,
        // so a stray under-indented line attaches to it rather than orphaning.
        final class MutableNode {
            let label: String
            var children: [MutableNode] = []
            init(_ label: String) { self.label = label }
        }
        let root = MutableNode(first.label)
        var stack: [(indent: Int, node: MutableNode)] = [(first.indent, root)]
        for entry in entries.dropFirst() {
            while stack.count > 1, let top = stack.last, top.indent >= entry.indent {
                stack.removeLast()
            }
            let node = MutableNode(entry.label)
            stack.last?.node.children.append(node)
            stack.append((entry.indent, node))
        }

        func freeze(_ node: MutableNode) -> MindmapNode {
            MindmapNode(label: node.label, children: node.children.map(freeze))
        }
        return Mindmap(root: freeze(root))
    }

    /// Strips a Mermaid mindmap node's shape wrapper to its label text:
    /// `root((Markdown))` → `Markdown`, `id[Square]` → `Square`. Plain text is
    /// returned unchanged. Reversed cloud/bang shapes degrade to best effort.
    static func mindmapLabel(_ raw: String) -> String {
        let openers: Set<Character> = ["(", "[", "{"]
        let closers: Set<Character> = [")", "]", "}"]
        guard let open = raw.firstIndex(where: { openers.contains($0) }),
              let close = raw.lastIndex(where: { closers.contains($0) }),
              close > open else {
            return raw
        }
        let inner = raw[raw.index(after: open)..<close]
            .trimmingCharacters(in: CharacterSet(charactersIn: "()[]{}"))
            .trimmingCharacters(in: .whitespaces)
        return inner.isEmpty ? raw : inner
    }

    // MARK: Timeline

    static func parseTimeline(body: [String]) -> Timeline? {
        var title: String?
        var currentSection = ""
        var sections: [String] = []
        var periods: [Timeline.Period] = []

        // Appends events to the most recent period (Mermaid's continuation
        // syntax, where a line starting with ":" carries more events for the
        // period above it).
        func appendEvents(_ events: [String]) {
            guard let last = periods.popLast() else { return }
            periods.append(Timeline.Period(
                label: last.label, section: last.section, events: last.events + events))
        }

        for line in body {
            if line.hasPrefix("title ") {
                title = String(line.dropFirst("title ".count)).trimmingCharacters(in: .whitespaces)
                continue
            }
            if line.hasPrefix("section ") {
                currentSection = String(line.dropFirst("section ".count)).trimmingCharacters(in: .whitespaces)
                if !currentSection.isEmpty, !sections.contains(currentSection) {
                    sections.append(currentSection)
                }
                continue
            }
            // `<period> : <event> : <event> …`. The first colon-token is the
            // time period; the rest are its events.
            let parts = line.split(separator: ":", omittingEmptySubsequences: false)
                .map { $0.trimmingCharacters(in: .whitespaces) }

            // A line starting with ":" continues the previous period.
            if line.hasPrefix(":") {
                appendEvents(parts.filter { !$0.isEmpty })
                continue
            }

            // Otherwise the first token is a new period's time label; a line
            // with no colon is a bare period with no events.
            guard let label = parts.first, !label.isEmpty else { continue }
            let events = parts.dropFirst().filter { !$0.isEmpty }
            periods.append(Timeline.Period(label: label, section: currentSection, events: Array(events)))
        }

        guard !periods.isEmpty else { return nil }
        return Timeline(title: title, periods: periods, sections: sections)
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
        if let label = stripped("[(", ")]") {
            return Flowchart.Node(id: id, label: label, shape: .cylinder)
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

    // MARK: State

    /// stateDiagram / stateDiagram-v2 → a nested StateDiagram. `state X { … }`
    /// blocks recurse into composites (each with its own `[*]` entry/exit);
    /// `<<choice>>` / `<<fork>>` / `<<join>>` annotations mark special shapes;
    /// transitions are arrows with an optional `: label`.
    static func parseState(body: [String]) -> StateDiagram? {
        // Composite parsing (and the layout that mirrors it) recurses once per
        // `state X {` nesting level. A linear pre-scan bounds that depth so
        // adversarial input can't overflow the stack — past the cap the block
        // degrades to the tidy styled-source card.
        var depth = 0, maxDepth = 0
        for line in body {
            if line.hasPrefix("state "), line.hasSuffix("{") { depth += 1; maxDepth = max(maxDepth, depth) }
            if line == "}" { depth = max(0, depth - 1) }
        }
        guard maxDepth <= 32 else { return nil }

        var index = 0
        var scopeCounter = 0
        let direction = detectStateDirection(body)

        // Recursively parses one brace scope, consuming lines until its
        // closing `}` (or end of input for the root). `scopeID` disambiguates
        // this scope's synthetic `[*]` terminals from every other scope's.
        func parseScope(scopeID: String) -> StateDiagram {
            var nodes: [String: StateDiagram.Node] = [:]
            var order: [String] = []
            var edges: [StateDiagram.Edge] = []
            var annotations: [String: StateDiagram.Kind] = [:]  // id → choice/fork/join

            func note(id: String, label: String, kind: StateDiagram.Kind) {
                if let existing = nodes[id] {
                    // Upgrade a bare reference to a labelled / composite node.
                    if existing.label == existing.id && (label != id || !isSimple(kind)) {
                        nodes[id] = StateDiagram.Node(id: id, label: label, kind: kind)
                    } else if isComposite(kind) {
                        nodes[id] = StateDiagram.Node(id: id, label: label, kind: kind)
                    }
                } else {
                    nodes[id] = StateDiagram.Node(id: id, label: label, kind: kind)
                    order.append(id)
                }
            }

            // Resolves a transition endpoint token to a node id, minting a
            // scope-local terminal for `[*]`.
            func endpoint(_ token: String, isSource: Bool) -> String? {
                let trimmed = token.trimmingCharacters(in: .whitespaces)
                guard !trimmed.isEmpty else { return nil }
                if trimmed == "[*]" {
                    let id = isSource ? "\(scopeID)__start" : "\(scopeID)__end"
                    note(id: id, label: "", kind: isSource ? .start : .end)
                    return id
                }
                guard trimmed.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" }) else { return nil }
                note(id: trimmed, label: trimmed, kind: .simple)
                return trimmed
            }

            while index < body.count {
                let line = body[index]
                index += 1

                if line == "}" { break }                       // close this scope
                if line.hasPrefix("direction") { continue }    // handled globally
                if line.hasPrefix("note") || line.hasPrefix("Note") { continue }

                // `state X { ` opens a composite — recurse.
                if line.hasPrefix("state "), line.hasSuffix("{") {
                    let inner = String(line.dropFirst("state ".count).dropLast())
                        .trimmingCharacters(in: .whitespaces)
                    let (id, label) = stateNameAndLabel(inner)
                    scopeCounter += 1
                    let child = parseScope(scopeID: "s\(scopeCounter)_")
                    nodes[id] = StateDiagram.Node(id: id, label: label, kind: .composite(child))
                    if !order.contains(id) { order.append(id) }
                    continue
                }

                // `state X <<choice>>` / `<<fork>>` / `<<join>>` annotations.
                if line.hasPrefix("state "), let annotationRange = line.range(of: "<<") {
                    let id = String(line[line.index(line.startIndex, offsetBy: "state ".count)..<annotationRange.lowerBound])
                        .trimmingCharacters(in: .whitespaces)
                    let annotation = line[annotationRange.lowerBound...]
                    let kind: StateDiagram.Kind? = annotation.contains("choice") ? .choice
                        : annotation.contains("fork") ? .fork
                        : annotation.contains("join") ? .join : nil
                    if let kind, !id.isEmpty {
                        annotations[id] = kind
                        note(id: id, label: id, kind: kind)
                    }
                    continue
                }

                // `state "Long description" as s2`
                if line.hasPrefix("state ") {
                    let declaration = String(line.dropFirst("state ".count))
                    if let asRange = declaration.range(of: " as ") {
                        let label = String(declaration[..<asRange.lowerBound])
                            .trimmingCharacters(in: .whitespaces)
                            .trimmingCharacters(in: CharacterSet(charactersIn: "\""))
                        let id = String(declaration[asRange.upperBound...]).trimmingCharacters(in: .whitespaces)
                        if !id.isEmpty { note(id: id, label: label, kind: .simple) }
                    } else {
                        let (id, label) = stateNameAndLabel(declaration.trimmingCharacters(in: .whitespaces))
                        if !id.isEmpty { note(id: id, label: label, kind: .simple) }
                    }
                    continue
                }

                if let arrowRange = line.range(of: "-->") {
                    let left = String(line[..<arrowRange.lowerBound])
                    var right = String(line[arrowRange.upperBound...])
                    var label: String?
                    if let colon = right.firstIndex(of: ":") {
                        label = String(right[right.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
                        right = String(right[..<colon])
                    }
                    guard let from = endpoint(left, isSource: true),
                          let to = endpoint(right, isSource: false) else { continue }
                    edges.append(StateDiagram.Edge(from: from, to: to, label: label))
                    continue
                }

                // Bare state id on its own line.
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if !trimmed.isEmpty, trimmed.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" }) {
                    note(id: trimmed, label: trimmed, kind: .simple)
                }
            }

            // Apply any annotations that arrived after a node was first seen.
            for (id, kind) in annotations where nodes[id] != nil {
                nodes[id] = StateDiagram.Node(id: id, label: nodes[id]!.label == id ? id : nodes[id]!.label, kind: kind)
            }

            return StateDiagram(
                direction: direction,
                nodes: order.compactMap { nodes[$0] },
                edges: edges
            )
        }

        let root = parseScope(scopeID: "root_")
        guard !root.nodes.isEmpty else { return nil }
        return root
    }

    private static func detectStateDirection(_ body: [String]) -> Flowchart.Direction {
        for line in body where line.hasPrefix("direction") {
            let value = line.dropFirst("direction".count).trimmingCharacters(in: .whitespaces)
            return Flowchart.Direction(rawValue: value.uppercased()) ?? .topDown
        }
        return .topDown
    }

    /// `Foo` → (Foo, Foo); `Foo : Nice Label` → (Foo, "Nice Label").
    private static func stateNameAndLabel(_ text: String) -> (String, String) {
        if let colon = text.firstIndex(of: ":") {
            let id = String(text[..<colon]).trimmingCharacters(in: .whitespaces)
            let label = String(text[text.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            return (id, label.isEmpty ? id : label)
        }
        let id = text.trimmingCharacters(in: .whitespaces)
        return (id, id)
    }

    private static func isSimple(_ kind: StateDiagram.Kind) -> Bool {
        if case .simple = kind { return true }
        return false
    }
    private static func isComposite(_ kind: StateDiagram.Kind) -> Bool {
        if case .composite = kind { return true }
        return false
    }

    // MARK: Class

    static func parseClass(body: [String]) -> ClassDiagram? {
        var classes: [String: ClassDiagram.Class] = [:]
        var order: [String] = []
        var relations: [ClassDiagram.Relation] = []
        var openClass: String? // inside `class X { … }`

        func note(_ name: String) {
            guard !name.isEmpty, classes[name] == nil else { return }
            classes[name] = ClassDiagram.Class(name: name, attributes: [], methods: [])
            order.append(name)
        }

        func addMember(_ raw: String, to name: String) {
            let member = raw.trimmingCharacters(in: .whitespaces)
            guard !member.isEmpty else { return }
            note(name)
            if member.contains("(") {
                classes[name]?.methods.append(member)
            } else {
                classes[name]?.attributes.append(member)
            }
        }

        // Mermaid multiplicity labels sit as a quoted token next to the
        // connector: `ClassA "1" *-- "many" ClassB`. Strip them so the
        // endpoint names still match the declared classes.
        func stripMultiplicity(_ text: String, trailing: Bool) -> String {
            let pattern = trailing ? #"\s*"[^"]*"$"# : #"^"[^"]*"\s*"#
            guard let range = text.range(of: pattern, options: .regularExpression) else { return text }
            let stripped = trailing ? text[..<range.lowerBound] : text[range.upperBound...]
            return stripped.trimmingCharacters(in: .whitespaces)
        }

        // Relation connectors, longest first. Reversed forms flip from/to
        // so the marker is always at the `to` end.
        let connectors: [(token: String, kind: ClassDiagram.RelationKind, reversed: Bool)] = [
            ("<|--", .inheritance, true), ("--|>", .inheritance, false),
            ("<|..", .realization, true), ("..|>", .realization, false),
            ("*--", .composition, true), ("--*", .composition, false),
            ("o--", .aggregation, true), ("--o", .aggregation, false),
            ("<--", .association, true), ("-->", .association, false),
            ("<..", .dependency, true), ("..>", .dependency, false),
            ("--", .link, false), ("..", .link, false),
        ]

        for line in body {
            if let current = openClass {
                if line == "}" { openClass = nil; continue }
                addMember(line, to: current)
                continue
            }
            if line.hasPrefix("class ") {
                var declaration = String(line.dropFirst("class ".count)).trimmingCharacters(in: .whitespaces)
                if declaration.hasSuffix("{") {
                    declaration = String(declaration.dropLast()).trimmingCharacters(in: .whitespaces)
                    openClass = declaration
                }
                note(declaration)
                continue
            }
            if line.hasPrefix("<<") || line.hasPrefix("note") { continue }

            // Member via colon shorthand: `Animal : +int age` — but only
            // when no relation connector is present on the line.
            if !connectors.contains(where: { line.contains($0.token) }),
               let colon = line.firstIndex(of: ":") {
                let name = String(line[..<colon]).trimmingCharacters(in: .whitespaces)
                if !name.isEmpty, name.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" }) {
                    addMember(String(line[line.index(after: colon)...]), to: name)
                }
                continue
            }

            for connector in connectors {
                guard let range = line.range(of: connector.token) else { continue }
                let left = stripMultiplicity(
                    String(line[..<range.lowerBound]).trimmingCharacters(in: .whitespaces),
                    trailing: true
                )
                var right = String(line[range.upperBound...])
                var label: String?
                if let colon = right.firstIndex(of: ":") {
                    label = String(right[right.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
                    right = String(right[..<colon])
                }
                let rightName = stripMultiplicity(right.trimmingCharacters(in: .whitespaces), trailing: false)
                guard !left.isEmpty, !rightName.isEmpty else { break }
                let from = connector.reversed ? rightName : left
                let to = connector.reversed ? left : rightName
                note(left)
                note(rightName)
                relations.append(ClassDiagram.Relation(from: from, to: to, kind: connector.kind, label: label))
                break
            }
        }

        guard !classes.isEmpty else { return nil }
        return ClassDiagram(classes: order.compactMap { classes[$0] }, relations: relations)
    }

    // MARK: ER

    static func parseER(body: [String]) -> ERDiagram? {
        var entities: [String: ERDiagram.Entity] = [:]
        var order: [String] = []
        var relations: [ERDiagram.Relation] = []
        var openEntity: String?

        func note(_ name: String) {
            guard !name.isEmpty, entities[name] == nil else { return }
            entities[name] = ERDiagram.Entity(name: name, attributes: [])
            order.append(name)
        }

        func cardinality(_ token: String) -> ERDiagram.Cardinality? {
            // Left-side tokens read outward (||, |o, }o, }|); right-side
            // tokens are mirrored (||, o|, o{, |{). Normalize both.
            switch token {
            case "||": return .one
            case "|o", "o|": return .zeroOrOne
            case "}|", "|{": return .oneOrMore
            case "}o", "o{": return .zeroOrMore
            default: return nil
            }
        }

        for line in body {
            if let current = openEntity {
                if line == "}" { openEntity = nil; continue }
                let parts = line.split(separator: " ", omittingEmptySubsequences: true)
                if parts.count >= 2 {
                    entities[current]?.attributes.append(
                        ERDiagram.Attribute(type: String(parts[0]), name: String(parts[1]))
                    )
                }
                continue
            }
            if line.hasSuffix("{"), !line.contains("--"), !line.contains("..") {
                let name = String(line.dropLast()).trimmingCharacters(in: .whitespaces)
                if !name.isEmpty {
                    note(name)
                    openEntity = name
                }
                continue
            }

            // A ||--o{ B : label   (also `..` for non-identifying)
            for separator in ["--", ".."] {
                guard let range = line.range(of: separator) else { continue }
                let left = String(line[..<range.lowerBound])
                var right = String(line[range.upperBound...])
                guard left.count >= 2, right.count >= 2 else { continue }
                let leftCardToken = String(left.suffix(2))
                let rightCardToken = String(right.prefix(2))
                guard let fromCard = cardinality(leftCardToken),
                      let toCard = cardinality(rightCardToken)
                else { continue }
                let from = String(left.dropLast(2)).trimmingCharacters(in: .whitespaces)
                right = String(right.dropFirst(2))
                var label = ""
                if let colon = right.firstIndex(of: ":") {
                    label = String(right[right.index(after: colon)...])
                        .trimmingCharacters(in: .whitespaces)
                        .trimmingCharacters(in: CharacterSet(charactersIn: "\""))
                    right = String(right[..<colon])
                }
                let to = right.trimmingCharacters(in: .whitespaces)
                guard !from.isEmpty, !to.isEmpty else { continue }
                note(from)
                note(to)
                relations.append(ERDiagram.Relation(
                    from: from, to: to,
                    fromCard: fromCard, toCard: toCard,
                    label: label, identifying: separator == "--"
                ))
                break
            }
        }

        guard !entities.isEmpty else { return nil }
        return ERDiagram(entities: order.compactMap { entities[$0] }, relations: relations)
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

    // MARK: Gantt

    static func parseGantt(body: [String]) -> GanttChart? {
        var title: String?
        var currentSection = ""
        var sections: [String] = []
        var tasks: [GanttChart.Task] = []
        var endByID: [String: Double] = [:]   // absolute end ordinal per task id
        var previousEnd: Double?               // absolute end of the previous task

        for (index, line) in body.enumerated() {
            // Directives (title / dateFormat / axisFormat / excludes / …).
            if line.hasPrefix("title ") {
                title = String(line.dropFirst("title ".count)).trimmingCharacters(in: .whitespaces)
                continue
            }
            if line.hasPrefix("section ") {
                currentSection = String(line.dropFirst("section ".count)).trimmingCharacters(in: .whitespaces)
                if !sections.contains(currentSection) { sections.append(currentSection) }
                continue
            }
            guard let colon = line.firstIndex(of: ":") else { continue } // non-task directive
            let label = String(line[..<colon]).trimmingCharacters(in: .whitespaces)
            let spec = String(line[line.index(after: colon)...])
            guard !label.isEmpty else { continue }

            // Comma-separated tokens: status tags, an optional id, a start
            // (date or `after …`), and a duration or end date — in any order.
            var status = GanttChart.Status.normal
            var isMilestone = false
            var id: String?
            var afterIDs: [String] = []
            var dates: [Double] = []
            var duration: Double?
            for token in spec.split(separator: ",").map({ $0.trimmingCharacters(in: .whitespaces) }) where !token.isEmpty {
                switch token.lowercased() {
                case "done": status = .done
                case "active": status = .active
                case "crit": status = .critical
                case "milestone": isMilestone = true
                default:
                    if token.lowercased().hasPrefix("after ") {
                        afterIDs = token.dropFirst("after ".count)
                            .split(separator: " ").map { String($0) }
                    } else if let ordinal = dayOrdinal(fromISODate: token) {
                        dates.append(ordinal)
                    } else if let days = durationInDays(token) {
                        duration = days
                    } else {
                        id = token   // a bare identifier
                    }
                }
            }

            // Resolve the absolute start ordinal.
            let start: Double
            if let first = dates.first {
                start = first
            } else if !afterIDs.isEmpty {
                start = afterIDs.compactMap { endByID[$0] }.max() ?? previousEnd ?? 0
            } else {
                start = previousEnd ?? 0
            }

            // Resolve the length in days.
            let length: Double
            if isMilestone {
                length = 0
            } else if dates.count >= 2 {
                length = max(0, dates[1] - start)  // start-date, end-date form
            } else {
                length = duration ?? 1
            }

            let taskID = id ?? "task\(index)"
            endByID[taskID] = start + length
            previousEnd = start + length
            tasks.append(GanttChart.Task(
                id: taskID, label: label, section: currentSection,
                start: start, length: length, isMilestone: isMilestone, status: status
            ))
        }

        guard !tasks.isEmpty else { return nil }

        // Normalize so the earliest task sits at day 0.
        let origin = tasks.map(\.start).min() ?? 0
        let normalized = tasks.map { task -> GanttChart.Task in
            var copy = task
            copy.start -= origin
            return copy
        }
        return GanttChart(title: title, tasks: normalized, sections: sections)
    }

    /// Julian Day Number for a proleptic-Gregorian `YYYY-MM-DD` string, or nil.
    /// Only day *differences* matter, so the absolute epoch is arbitrary; this
    /// is integer and timezone-free (works identically on Linux).
    static func dayOrdinal(fromISODate text: String) -> Double? {
        let parts = text.split(separator: "-")
        guard parts.count == 3,
              let year = Int(parts[0]), let month = Int(parts[1]), let day = Int(parts[2]),
              (1...12).contains(month), (1...31).contains(day), parts[0].count == 4
        else { return nil }
        let a = (14 - month) / 12
        let y = year + 4800 - a
        let m = month + 12 * a - 3
        let jdn = day + (153 * m + 2) / 5 + 365 * y + y / 4 - y / 100 + y / 400 - 32045
        return Double(jdn)
    }

    /// A Mermaid duration like `30d`, `2w`, `12h` in days, or nil. A bare
    /// number is treated as days.
    static func durationInDays(_ text: String) -> Double? {
        guard let unit = text.last else { return nil }
        if let bare = Double(text) { return bare }  // "30" → 30 days
        let value = Double(text.dropLast())
        guard let value, value >= 0 else { return nil }
        switch unit {
        case "d": return value
        case "w": return value * 7
        case "h": return value / 24
        case "m": return value / (24 * 60)   // minutes
        default: return nil
        }
    }
}
