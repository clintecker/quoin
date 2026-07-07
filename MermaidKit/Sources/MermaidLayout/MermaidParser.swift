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
    case packet(PacketDiagram)
    case xychart(XYChart)
    case kanban(KanbanBoard)
    case radar(RadarChart)
    case treemap(Treemap)
    case gitGraph(GitGraph)
    case sankey(SankeyDiagram)
    case requirement(RequirementDiagram)
    case zenuml(ZenUML)
    case c4(C4Diagram)
    case architecture(ArchitectureDiagram)
    case block(BlockDiagram)
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
        if header.hasPrefix("packet") {
            return parsePacket(body: Array(lines.dropFirst())).map { .packet($0) }
        }
        if header.hasPrefix("xychart") {
            return parseXYChart(body: Array(lines.dropFirst())).map { .xychart($0) }
        }
        if header.hasPrefix("kanban") {
            // Indentation is significant, so re-read the raw (untrimmed) source.
            return parseKanban(source: source).map { .kanban($0) }
        }
        if header.hasPrefix("radar") {
            return parseRadar(body: Array(lines.dropFirst())).map { .radar($0) }
        }
        if header.hasPrefix("treemap") {
            // Indentation is significant, so re-read the raw (untrimmed) source.
            return parseTreemap(source: source).map { .treemap($0) }
        }
        if header.hasPrefix("gitGraph") {
            return parseGitGraph(body: Array(lines.dropFirst())).map { .gitGraph($0) }
        }
        if header.hasPrefix("sankey") {
            return parseSankey(body: Array(lines.dropFirst())).map { .sankey($0) }
        }
        if header.hasPrefix("requirementDiagram") {
            return parseRequirement(body: Array(lines.dropFirst())).map { .requirement($0) }
        }
        if header.hasPrefix("zenuml") {
            return parseZenUML(body: Array(lines.dropFirst())).map { .zenuml($0) }
        }
        if header.hasPrefix("C4") {
            return parseC4(body: Array(lines.dropFirst())).map { .c4($0) }
        }
        if header.hasPrefix("architecture") {
            return parseArchitecture(body: Array(lines.dropFirst())).map { .architecture($0) }
        }
        if header.hasPrefix("block-beta") {
            return parseBlock(body: Array(lines.dropFirst())).map { .block($0) }
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

}
