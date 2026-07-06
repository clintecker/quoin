import XCTest
@testable import QuoinCore

final class MermaidParserTests: XCTestCase {

    func testFlowchartNodesAndEdges() {
        let diagram = MermaidParser.parse("""
        graph TD
            A[Open file] --> B{Changed?}
            B -->|yes| C(Re-parse)
            B -->|no| D((Done))
            C -.-> D
        """)
        guard case .flowchart(let chart) = diagram else { return XCTFail("expected flowchart") }
        XCTAssertEqual(chart.direction, .topDown)
        XCTAssertEqual(chart.nodes.map(\.id), ["A", "B", "C", "D"])
        XCTAssertEqual(chart.nodes[0].label, "Open file")
        XCTAssertEqual(chart.nodes[1].shape, .diamond)
        XCTAssertEqual(chart.nodes[2].shape, .rounded)
        XCTAssertEqual(chart.nodes[3].shape, .circle)
        XCTAssertEqual(chart.edges.count, 4)
        XCTAssertEqual(chart.edges[1].label, "yes")
        XCTAssertTrue(chart.edges[3].dashed)
    }

    func testFlowchartCylinderShape() {
        // `A[(label)]` is a database cylinder, not a rectangle whose label is
        // the literal "(label)".
        let diagram = MermaidParser.parse("flowchart TD\n  A[(Store)] --> B[Done]")
        guard case .flowchart(let chart) = diagram else { return XCTFail("expected flowchart") }
        XCTAssertEqual(chart.nodes[0].shape, .cylinder)
        XCTAssertEqual(chart.nodes[0].label, "Store")
        XCTAssertEqual(chart.nodes[1].shape, .rectangle)
    }

    func testFlowchartLeftRight() {
        let diagram = MermaidParser.parse("flowchart LR\n  A --> B")
        guard case .flowchart(let chart) = diagram else { return XCTFail("expected flowchart") }
        XCTAssertEqual(chart.direction, .leftRight)
    }

    func testSequenceDiagram() {
        let diagram = MermaidParser.parse("""
        sequenceDiagram
            participant A as Alice
            participant B as Bob
            A->>B: Hello
            B-->>A: Hi back
        """)
        guard case .sequence(let seq) = diagram else { return XCTFail("expected sequence") }
        XCTAssertEqual(seq.participants.map(\.label), ["Alice", "Bob"])
        XCTAssertEqual(seq.messages.count, 2)
        XCTAssertEqual(seq.messages[0].text, "Hello")
        XCTAssertFalse(seq.messages[0].dashed)
        XCTAssertTrue(seq.messages[1].dashed)
    }

    func testSequenceImplicitParticipants() {
        let diagram = MermaidParser.parse("sequenceDiagram\n  Client->>Server: GET /")
        guard case .sequence(let seq) = diagram else { return XCTFail("expected sequence") }
        XCTAssertEqual(seq.participants.map(\.id), ["Client", "Server"])
    }

    func testPie() {
        let diagram = MermaidParser.parse("""
        pie title Languages
            "Swift" : 70
            "C" : 20
            "Other" : 10
        """)
        guard case .pie(let pie) = diagram else { return XCTFail("expected pie") }
        XCTAssertEqual(pie.title, "Languages")
        XCTAssertEqual(pie.slices.count, 3)
        XCTAssertEqual(pie.slices[0].label, "Swift")
        XCTAssertEqual(pie.slices[0].value, 70)
    }

    func testTimelineParsing() {
        let diagram = MermaidParser.parse("""
        timeline
            title Social History
            2002 : LinkedIn
            2004 : Facebook : Google
            section Modern
                2007 : iPhone
                2010 : Instagram
        """)
        guard case .timeline(let timeline) = diagram else { return XCTFail("expected timeline") }
        XCTAssertEqual(timeline.title, "Social History")
        XCTAssertEqual(timeline.periods.count, 4)
        XCTAssertEqual(timeline.periods[0].label, "2002")
        XCTAssertEqual(timeline.periods[0].events, ["LinkedIn"])
        // Multiple colon-separated events on one period.
        XCTAssertEqual(timeline.periods[1].events, ["Facebook", "Google"])
        // Section applies to periods declared after it, not before.
        XCTAssertEqual(timeline.periods[0].section, "")
        XCTAssertEqual(timeline.periods[2].section, "Modern")
        XCTAssertEqual(timeline.sections, ["Modern"])
    }

    func testTimelineContinuationLinesAddEvents() {
        // A line starting with ":" carries more events for the period above it.
        let diagram = MermaidParser.parse("""
        timeline
            2004 : Markdown introduced
                 : Plain-text authoring
            2014 : CommonMark begins
        """)
        guard case .timeline(let timeline) = diagram else { return XCTFail("expected timeline") }
        XCTAssertEqual(timeline.periods.count, 2)
        XCTAssertEqual(timeline.periods[0].events, ["Markdown introduced", "Plain-text authoring"])
        XCTAssertEqual(timeline.periods[1].events, ["CommonMark begins"])
    }

    func testTimelineWithoutPeriodsReturnsNil() {
        XCTAssertNil(MermaidParser.parse("timeline\n    title Empty"))
    }

    func testMindmapParsingByIndentation() {
        let diagram = MermaidParser.parse("""
        mindmap
          root((Markdown))
            Origins
              CommonMark
            Tools
              Quoin
              Obsidian
        """)
        guard case .mindmap(let mindmap) = diagram else { return XCTFail("expected mindmap") }
        // Shape wrapper stripped to label text.
        XCTAssertEqual(mindmap.root.label, "Markdown")
        XCTAssertEqual(mindmap.root.children.map(\.label), ["Origins", "Tools"])
        // Deeper indentation nests under the right parent.
        XCTAssertEqual(mindmap.root.children[0].children.map(\.label), ["CommonMark"])
        XCTAssertEqual(mindmap.root.children[1].children.map(\.label), ["Quoin", "Obsidian"])
    }

    func testMindmapShapeStripping() {
        XCTAssertEqual(MermaidParser.mindmapLabel("id[Square]"), "Square")
        XCTAssertEqual(MermaidParser.mindmapLabel("((Circle))"), "Circle")
        XCTAssertEqual(MermaidParser.mindmapLabel("{{Hexagon}}"), "Hexagon")
        XCTAssertEqual(MermaidParser.mindmapLabel("Plain text"), "Plain text")
    }

    func testMindmapEmptyReturnsNil() {
        XCTAssertNil(MermaidParser.parse("mindmap\n"))
    }

    func testJourneyParsing() {
        let diagram = MermaidParser.parse("""
        journey
            title My Day
            section Morning
              Wake up: 3: Me
              Coffee: 5: Me, Cat
            section Work
              Standup: 2: Team
        """)
        guard case .journey(let journey) = diagram else { return XCTFail("expected journey") }
        XCTAssertEqual(journey.title, "My Day")
        XCTAssertEqual(journey.tasks.count, 3)
        XCTAssertEqual(journey.tasks[0].label, "Wake up")
        XCTAssertEqual(journey.tasks[0].score, 3)
        XCTAssertEqual(journey.tasks[1].actors, ["Me", "Cat"])
        XCTAssertEqual(journey.tasks[2].section, "Work")
        XCTAssertEqual(journey.sections, ["Morning", "Work"])
    }

    func testJourneyClampsScoreAndHandlesMissingActors() {
        let diagram = MermaidParser.parse("""
        journey
          Overjoyed: 9: A
          Silent: 4
        """)
        guard case .journey(let journey) = diagram else { return XCTFail("expected journey") }
        XCTAssertEqual(journey.tasks[0].score, 5, "out-of-range score clamps to 5")
        XCTAssertEqual(journey.tasks[1].actors, [], "no actors is allowed")
    }

    func testQuadrantParsing() {
        let diagram = MermaidParser.parse("""
        quadrantChart
            title Risk Matrix
            x-axis Low complexity --> High complexity
            y-axis Low impact --> High impact
            quadrant-1 High leverage
            quadrant-3 Easy cleanup
            "Tables": [0.35, 0.70]
            "Mermaid": [0.74, 0.78]
        """)
        guard case .quadrant(let q) = diagram else { return XCTFail("expected quadrant") }
        XCTAssertEqual(q.title, "Risk Matrix")
        XCTAssertEqual(q.xAxisLeft, "Low complexity")
        XCTAssertEqual(q.xAxisRight, "High complexity")
        XCTAssertEqual(q.yAxisTop, "High impact")
        XCTAssertEqual(q.quadrants[0], "High leverage")     // q1
        XCTAssertNil(q.quadrants[1])                         // q2 unset
        XCTAssertEqual(q.quadrants[2], "Easy cleanup")      // q3
        XCTAssertEqual(q.points.count, 2)
        XCTAssertEqual(q.points[0].label, "Tables")
        XCTAssertEqual(q.points[0].x, 0.35, accuracy: 0.001)
        XCTAssertEqual(q.points[0].y, 0.70, accuracy: 0.001)
    }

    func testQuadrantClampsCoordinates() {
        let diagram = MermaidParser.parse("""
        quadrantChart
            "Over": [1.4, -0.2]
        """)
        guard case .quadrant(let q) = diagram else { return XCTFail("expected quadrant") }
        XCTAssertEqual(q.points[0].x, 1.0, accuracy: 0.001)
        XCTAssertEqual(q.points[0].y, 0.0, accuracy: 0.001)
    }

    func testUnsupportedTypeReturnsNil() {
        XCTAssertNil(MermaidParser.parse("gitGraph\n  commit"))
        XCTAssertNil(MermaidParser.parse("not mermaid at all"))
    }
}

final class DiagramLayoutTests: XCTestCase {

    /// Deterministic fake measurer: 7pt per character, height = fontSize + 4.
    private let measure: DiagramTextMeasurer = { text, fontSize in
        CGSize(width: Double(text.count) * 7, height: fontSize + 4)
    }

    func testFlowchartLayering() {
        guard case .flowchart(let chart)? = MermaidParser.parse("""
        graph TD
            A --> B
            A --> C
            B --> D
            C --> D
        """) else { return XCTFail("parse failed") }

        let layout = DiagramLayoutEngine.layout(chart, measure: measure)
        let frames = Dictionary(uniqueKeysWithValues: layout.nodes.map { ($0.id, $0.frame) })

        // A above B/C, which are above D (top-down layering).
        XCTAssertLessThan(frames["A"]!.maxY, frames["B"]!.minY)
        XCTAssertLessThan(frames["A"]!.maxY, frames["C"]!.minY)
        XCTAssertLessThan(frames["B"]!.maxY, frames["D"]!.minY)
        // B and C share a layer.
        XCTAssertEqual(frames["B"]!.minY, frames["C"]!.minY, accuracy: 0.5)
        // No overlaps within the layer.
        XCTAssertFalse(frames["B"]!.intersects(frames["C"]!))
        XCTAssertEqual(layout.edges.count, 4)
        XCTAssertTrue(layout.size.width > 0 && layout.size.height > 0)
    }

    func testFlowchartCycleDoesNotHang() {
        guard case .flowchart(let chart)? = MermaidParser.parse("graph TD\n A --> B\n B --> A") else {
            return XCTFail("parse failed")
        }
        let layout = DiagramLayoutEngine.layout(chart, measure: measure)
        XCTAssertEqual(layout.nodes.count, 2)
    }

    func testLeftRightUsesHorizontalAxis() {
        guard case .flowchart(let chart)? = MermaidParser.parse("graph LR\n A --> B") else {
            return XCTFail("parse failed")
        }
        let layout = DiagramLayoutEngine.layout(chart, measure: measure)
        let frames = Dictionary(uniqueKeysWithValues: layout.nodes.map { ($0.id, $0.frame) })
        XCTAssertLessThan(frames["A"]!.maxX, frames["B"]!.minX)
    }

    func testSequenceLayout() {
        guard case .sequence(let seq)? = MermaidParser.parse("""
        sequenceDiagram
            A->>B: ping
            B-->>A: pong
        """) else { return XCTFail("parse failed") }

        let layout = DiagramLayoutEngine.layout(seq, measure: measure)
        XCTAssertEqual(layout.heads.count, 2)
        XCTAssertEqual(layout.arrows.count, 2)
        // First arrow goes rightward, reply leftward.
        XCTAssertLessThan(layout.arrows[0].fromX, layout.arrows[0].toX)
        XCTAssertGreaterThan(layout.arrows[1].fromX, layout.arrows[1].toX)
        XCTAssertLessThan(layout.arrows[0].y, layout.arrows[1].y)
        XCTAssertGreaterThan(layout.lifelineBottom, layout.arrows[1].y)
    }

    func testSelfMessageBecomesLoop() {
        guard case .sequence(let seq)? = MermaidParser.parse("""
        sequenceDiagram
            A->>A: think
            A->>B: answer
        """) else { return XCTFail("parse failed") }
        let layout = DiagramLayoutEngine.layout(seq, measure: measure)
        XCTAssertTrue(layout.arrows[0].isSelfMessage)
        XCTAssertGreaterThan(layout.arrows[0].toX, layout.arrows[0].fromX)
        XCTAssertFalse(layout.arrows[1].isSelfMessage)
    }

    func testSelfMessageLabelOnLastLifelineWidensCanvas() {
        guard case .sequence(let seq)? = MermaidParser.parse("""
        sequenceDiagram
            A->>B: ask
            B->>B: a fairly long self-message label
        """) else { return XCTFail("parse failed") }
        let layout = DiagramLayoutEngine.layout(seq, measure: measure)
        let loop = layout.arrows[1]
        XCTAssertTrue(loop.isSelfMessage)
        // The label draws starting 8pt right of the loop; the canvas must
        // contain it, not clip it at the participant-derived width.
        let labelRight = loop.toX + 8 + measure(loop.text, 10.5).width
        XCTAssertGreaterThanOrEqual(layout.size.width, labelRight)
    }

    func testOffsetFlowchartEdgesRouteOrthogonally() {
        guard case .flowchart(let chart)? = MermaidParser.parse("""
        graph TD
            A --> B
            A --> C
        """) else { return XCTFail("parse failed") }
        let layout = DiagramLayoutEngine.layout(chart, measure: measure)
        // Both fan-out edges are horizontally offset, so each must route as
        // an axis-aligned polyline, not a diagonal.
        for edge in layout.edges where abs(edge.start.x - edge.end.x) > 0.5 {
            XCTAssertEqual(edge.points.count, 4)
            for (a, b) in zip(edge.points, edge.points.dropFirst()) {
                XCTAssertTrue(abs(a.x - b.x) < 0.001 || abs(a.y - b.y) < 0.001,
                              "segment \(a)→\(b) is not axis-aligned")
            }
        }
        XCTAssertTrue(layout.edges.contains { $0.points.count == 4 })
    }

    func testCycleBackEdgeDoesNotPushStateDeeper() {
        guard case .state(let diagram)? = MermaidParser.parse("""
        stateDiagram-v2
            [*] --> Idle
            Idle --> Loading: open
            Loading --> Idle: retry
        """) else { return XCTFail("parse failed") }
        let layout = DiagramLayoutEngine.layout(diagram, measure: measure)
        let idle = layout.nodes.first { $0.id == "Idle" }
        let loading = layout.nodes.first { $0.id == "Loading" }
        // The retry back-edge must not push Idle below Loading.
        XCTAssertNotNil(idle)
        XCTAssertNotNil(loading)
        XCTAssertLessThan(idle!.frame.minY, loading!.frame.minY)
    }

    func testStateDiagramParsesTerminalsLabelsAndEdges() {
        guard case .state(let diagram)? = MermaidParser.parse("""
        stateDiagram-v2
            direction LR
            [*] --> Idle
            Idle --> Loading: open
            Loading --> Ready
            Ready --> [*]
            state "Long name" as Loading
        """) else { return XCTFail("expected state diagram") }
        XCTAssertEqual(diagram.direction, .leftRight)
        XCTAssertEqual(diagram.nodes.first?.kind, .start)
        XCTAssertTrue(diagram.nodes.contains { $0.kind == .end })
        XCTAssertTrue(diagram.nodes.contains { $0.id == "Loading" && $0.label == "Long name" })
        XCTAssertEqual(diagram.edges.count, 4)
        XCTAssertEqual(diagram.edges[1].label, "open")
    }

    func testStateTerminalsGetFixedSizes() {
        guard case .state(let diagram)? = MermaidParser.parse("""
        stateDiagram
            [*] --> A
            A --> [*]
        """) else { return XCTFail("parse failed") }
        let layout = DiagramLayoutEngine.layout(diagram, measure: measure)
        let start = layout.nodes.first { $0.kind == .start }
        let end = layout.nodes.first { $0.kind == .end }
        XCTAssertEqual(start?.frame.width, 14)
        XCTAssertEqual(end?.frame.width, 18)
    }

    func testCompositeStateNestsChildrenAndSpecialShapes() {
        guard case .state(let diagram)? = MermaidParser.parse("""
        stateDiagram-v2
            [*] --> Work
            state Work {
                [*] --> Fork
                state Fork <<fork>>
                Fork --> A
                Fork --> B
                state Join <<join>>
                A --> Join
                B --> Join
                Join --> [*]
            }
            Work --> [*]
        """) else { return XCTFail("parse failed") }

        // Work carries its own sub-diagram with fork/join shapes and its own
        // scoped terminals (distinct from the outer [*]).
        let work = diagram.nodes.first { $0.id == "Work" }
        guard case .composite(let inner)? = work?.kind else { return XCTFail("Work should be composite") }
        XCTAssertTrue(inner.nodes.contains { $0.id == "Fork" && $0.kind == .fork })
        XCTAssertTrue(inner.nodes.contains { $0.id == "Join" && $0.kind == .join })

        let layout = DiagramLayoutEngine.layout(diagram, measure: measure)
        XCTAssertEqual(layout.containers.count, 1)
        let container = layout.containers[0]
        XCTAssertEqual(container.label, "Work")
        // The fork bar is laid out inside the Work container.
        guard let fork = layout.nodes.first(where: { $0.kind == .fork }) else { return XCTFail("no fork") }
        XCTAssertTrue(container.frame.contains(CGPoint(x: fork.frame.midX, y: fork.frame.midY)))
    }

    func testClassDiagramParsesMembersAndRelations() {
        guard case .classDiagram(let diagram)? = MermaidParser.parse("""
        classDiagram
            class Animal {
                +String name
                +eat()
            }
            Animal <|-- Dog
            Cat --|> Animal
            Dog *-- Bone
            Dog --> Food : eats
            Animal : +int age
        """) else { return XCTFail("expected class diagram") }

        let animal = diagram.classes.first { $0.name == "Animal" }
        XCTAssertEqual(animal?.attributes, ["+String name", "+int age"])
        XCTAssertEqual(animal?.methods, ["+eat()"])

        // `Animal <|-- Dog` normalizes to Dog → Animal with the triangle
        // at Animal; `Cat --|> Animal` is already in that direction.
        XCTAssertEqual(diagram.relations[0].from, "Dog")
        XCTAssertEqual(diagram.relations[0].to, "Animal")
        XCTAssertEqual(diagram.relations[0].kind, .inheritance)
        XCTAssertEqual(diagram.relations[1].from, "Cat")
        XCTAssertEqual(diagram.relations[1].kind, .inheritance)
        // `Dog *-- Bone`: Dog is composed of Bone; diamond at Dog.
        XCTAssertEqual(diagram.relations[2].from, "Bone")
        XCTAssertEqual(diagram.relations[2].to, "Dog")
        XCTAssertEqual(diagram.relations[2].kind, .composition)
        XCTAssertEqual(diagram.relations[3].kind, .association)
        XCTAssertEqual(diagram.relations[3].label, "eats")
    }

    func testClassRelationStripsMultiplicityLabels() {
        guard case .classDiagram(let diagram)? = MermaidParser.parse("""
        classDiagram
            class Whole
            class Part
            Whole "1" *-- "many" Part : contains
        """) else { return XCTFail("expected class diagram") }
        // Endpoints resolve to the declared classes, not phantom names that
        // still carry the quoted multiplicities.
        XCTAssertEqual(diagram.classes.map(\.name).sorted(), ["Part", "Whole"])
        XCTAssertEqual(diagram.relations.count, 1)
        // `*--` normalizes so the diamond (marker end) is at the whole.
        XCTAssertEqual(diagram.relations[0].to, "Whole")
        XCTAssertEqual(diagram.relations[0].from, "Part")
        XCTAssertEqual(diagram.relations[0].kind, .composition)
        XCTAssertEqual(diagram.relations[0].label, "contains")
    }

    func testClassLayoutPutsParentAboveChild() {
        guard case .classDiagram(let diagram)? = MermaidParser.parse("""
        classDiagram
            Animal <|-- Dog
        """) else { return XCTFail("parse failed") }
        let layout = DiagramLayoutEngine.layout(diagram, measure: measure)
        let animal = layout.boxes.first { $0.name == "Animal" }
        let dog = layout.boxes.first { $0.name == "Dog" }
        XCTAssertNotNil(animal)
        XCTAssertNotNil(dog)
        XCTAssertLessThan(animal!.frame.maxY, dog!.frame.minY)
        // Marker end of the edge is at the parent (Animal) border.
        XCTAssertEqual(layout.edges.first?.end.y ?? -1, animal!.frame.maxY, accuracy: 0.5)
    }

    func testClassEdgesRouteOrthogonallyWithFanOut() {
        guard case .classDiagram(let diagram)? = MermaidParser.parse("""
        classDiagram
            Animal <|-- Dog
            Animal <|-- Cat
        """) else { return XCTFail("parse failed") }
        let layout = DiagramLayoutEngine.layout(diagram, measure: measure)
        XCTAssertEqual(layout.edges.count, 2)

        // Every segment is axis-aligned — orthogonal elbows, no diagonals.
        for edge in layout.edges {
            XCTAssertGreaterThanOrEqual(edge.points.count, 2)
            XCTAssertEqual(edge.points.first!.x, edge.start.x, accuracy: 0.01)
            XCTAssertEqual(edge.points.last!.x, edge.end.x, accuracy: 0.01)
            for i in 1..<edge.points.count {
                let a = edge.points[i - 1], b = edge.points[i]
                XCTAssertTrue(abs(a.x - b.x) < 0.5 || abs(a.y - b.y) < 0.5,
                              "segment \(a)->\(b) is diagonal")
            }
        }

        // Both inheritance edges land on Animal's bottom face, fanned out to
        // distinct attach points so the two lines never overlap.
        let ends = layout.edges.map(\.end)
        XCTAssertEqual(ends[0].y, ends[1].y, accuracy: 0.5)
        XCTAssertNotEqual(ends[0].x, ends[1].x)
    }

    func testERDiagramParsesCardinalitiesAndAttributes() {
        guard case .er(let diagram)? = MermaidParser.parse("""
        erDiagram
            CUSTOMER ||--o{ ORDER : places
            ORDER ||--|{ LINE_ITEM : contains
            CUSTOMER {
                string name
                string custNumber
            }
        """) else { return XCTFail("expected ER diagram") }

        XCTAssertEqual(diagram.entities.map(\.name), ["CUSTOMER", "ORDER", "LINE_ITEM"])
        let customer = diagram.entities[0]
        XCTAssertEqual(customer.attributes.count, 2)
        XCTAssertEqual(customer.attributes[0].type, "string")
        XCTAssertEqual(customer.attributes[0].name, "name")

        XCTAssertEqual(diagram.relations[0].fromCard, .one)
        XCTAssertEqual(diagram.relations[0].toCard, .zeroOrMore)
        XCTAssertEqual(diagram.relations[0].label, "places")
        XCTAssertTrue(diagram.relations[0].identifying)
        XCTAssertEqual(diagram.relations[1].toCard, .oneOrMore)
    }

    func testERLayoutProducesBoxesAndEdges() {
        guard case .er(let diagram)? = MermaidParser.parse("""
        erDiagram
            A ||--o{ B : has
        """) else { return XCTFail("parse failed") }
        let layout = DiagramLayoutEngine.layout(diagram, measure: measure)
        XCTAssertEqual(layout.boxes.count, 2)
        XCTAssertEqual(layout.edges.count, 1)
        XCTAssertGreaterThan(layout.size.width, 0)
        XCTAssertGreaterThan(layout.size.height, 0)
    }

    func testPieAnglesSumToFullCircle() {
        guard case .pie(let pie)? = MermaidParser.parse("pie\n \"A\" : 1\n \"B\" : 3") else {
            return XCTFail("parse failed")
        }
        let layout = DiagramLayoutEngine.layout(pie, measure: measure)
        XCTAssertEqual(layout.slices.count, 2)
        XCTAssertEqual(layout.slices[0].fraction, 0.25, accuracy: 0.001)
        XCTAssertEqual(layout.slices[1].fraction, 0.75, accuracy: 0.001)
        let sweep = layout.slices.last!.endAngle - layout.slices.first!.startAngle
        XCTAssertEqual(sweep, 2 * Double.pi, accuracy: 0.001)
    }

    // MARK: Brandes–Köpf coordinate assignment

    /// A straight chain A→B→C (one node per layer) must land on a single
    /// vertical line — every node shares one x.
    func testBrandesKoepfStraightChainIsColinear() {
        let layers = [["A"], ["B"], ["C"]]
        let segments = [("A", "B"), ("B", "C")]
        let breadth: [String: CGFloat] = ["A": 40, "B": 40, "C": 40]
        let x = DiagramLayoutEngine.brandesKoepfX(
            layers: layers, segments: segments, breadth: breadth, dummies: [], minGap: 20)
        XCTAssertEqual(x["A"]!, x["B"]!, accuracy: 0.001)
        XCTAssertEqual(x["B"]!, x["C"]!, accuracy: 0.001)
    }

    /// Two siblings in the lower layer under one parent keep the minimum gap
    /// (breadth/2 + breadth/2 + minGap) and stay in order.
    func testBrandesKoepfSiblingsRespectMinimumGap() {
        let layers = [["P"], ["L", "R"]]
        let segments = [("P", "L"), ("P", "R")]
        let breadth: [String: CGFloat] = ["P": 40, "L": 40, "R": 40]
        let x = DiagramLayoutEngine.brandesKoepfX(
            layers: layers, segments: segments, breadth: breadth, dummies: [], minGap: 20)
        XCTAssertLessThan(x["L"]!, x["R"]!)                       // order preserved
        XCTAssertGreaterThanOrEqual(x["R"]! - x["L"]!, 60 - 0.01) // 20+20 + gap 20
    }

    /// A long edge routed through a two-dummy channel has a genuine inner
    /// (dummy→dummy) segment, which type-1 conflict marking forces straight:
    /// the two dummies share one x even when a parallel real path competes for
    /// space beside them.
    func testBrandesKoepfInnerSegmentStaysStraight() {
        // A→C spans layers 0→3 via dummies D1, D2. A parallel real path
        // A→B→E→C runs alongside, so the dummy channel must hold its column.
        let layers = [["A"], ["D1", "B"], ["D2", "E"], ["C"]]
        let segments = [
            ("A", "D1"), ("D1", "D2"), ("D2", "C"),   // long edge's dummy chain
            ("A", "B"), ("B", "E"), ("E", "C"),        // parallel real path
        ]
        let breadth: [String: CGFloat] = ["A": 40, "B": 40, "C": 40, "E": 40, "D1": 16, "D2": 16]
        let x = DiagramLayoutEngine.brandesKoepfX(
            layers: layers, segments: segments, breadth: breadth, dummies: ["D1", "D2"], minGap: 20)
        // The inner segment D1→D2 is dummy→dummy: BK keeps it vertical.
        XCTAssertEqual(x["D1"]!, x["D2"]!, accuracy: 0.5)
        // And the two layer-order pairs never overlap or swap.
        XCTAssertLessThan(x["D1"]!, x["B"]!)
        XCTAssertLessThan(x["D2"]!, x["E"]!)
    }

    func testTimelineLayout() {
        guard case .timeline(let timeline)? = MermaidParser.parse("""
        timeline
            title History
            2002 : LinkedIn
            2004 : Facebook : Google
            section Modern
                2007 : iPhone
        """) else { return XCTFail("parse failed") }
        let layout = DiagramLayoutEngine.layout(timeline, measure: measure)

        // Non-degenerate canvas and one laid-out period per source period.
        XCTAssertGreaterThan(layout.size.width, 0)
        XCTAssertGreaterThan(layout.size.height, 0)
        XCTAssertEqual(layout.periods.count, 3)

        // Periods flow top-to-bottom: each dot is below the previous.
        XCTAssertLessThan(layout.periods[0].dot.y, layout.periods[1].dot.y)
        XCTAssertLessThan(layout.periods[1].dot.y, layout.periods[2].dot.y)

        // All dots share the spine x, which the spine spans vertically.
        for period in layout.periods {
            XCTAssertEqual(period.dot.x, layout.spineX, accuracy: 0.5)
        }
        XCTAssertLessThanOrEqual(layout.spineTop, layout.periods.first!.dot.y)
        XCTAssertGreaterThanOrEqual(layout.spineBottom, layout.periods.last!.dot.y)

        // The two events on "2004" stack (distinct, increasing y) to the right
        // of the spine, and never overlap.
        let stacked = layout.periods[1].events
        XCTAssertEqual(stacked.count, 2)
        XCTAssertGreaterThan(stacked[0].frame.minX, layout.spineX)
        XCTAssertLessThanOrEqual(stacked[0].frame.maxY, stacked[1].frame.minY)

        // The "Modern" section produces exactly one tint band.
        XCTAssertEqual(layout.sections.count, 1)
        XCTAssertEqual(layout.sections.first?.name, "Modern")
    }

    func testMindmapLayout() {
        guard case .mindmap(let mindmap)? = MermaidParser.parse("""
        mindmap
          root((Root))
            A
              A1
              A2
            B
        """) else { return XCTFail("parse failed") }
        let layout = DiagramLayoutEngine.layout(mindmap, measure: measure)

        XCTAssertGreaterThan(layout.size.width, 0)
        XCTAssertGreaterThan(layout.size.height, 0)
        // 5 nodes: root, A, A1, A2, B.
        XCTAssertEqual(layout.nodes.count, 5)
        // 4 edges (every non-root node has one parent link).
        XCTAssertEqual(layout.edges.count, 4)

        let root = layout.nodes[0]
        XCTAssertEqual(root.depth, 0)
        // Depth increases strictly left-to-right: each child column is right of
        // its parent's, so a child never overlaps its parent.
        let a = layout.nodes.first { $0.label == "A" }!
        let a1 = layout.nodes.first { $0.label == "A1" }!
        XCTAssertGreaterThan(a.frame.minX, root.frame.maxX)
        XCTAssertGreaterThan(a1.frame.minX, a.frame.maxX)

        // A centers vertically on its children A1 and A2.
        let a2 = layout.nodes.first { $0.label == "A2" }!
        XCTAssertEqual(a.frame.midY, (a1.frame.midY + a2.frame.midY) / 2, accuracy: 0.5)

        // Top-level branches A and B carry distinct tints; A1 inherits A's.
        let b = layout.nodes.first { $0.label == "B" }!
        XCTAssertNotEqual(a.colorIndex, b.colorIndex)
        XCTAssertEqual(a1.colorIndex, a.colorIndex)
    }

    func testJourneyLayout() {
        guard case .journey(let journey)? = MermaidParser.parse("""
        journey
            title Day
            section Morning
              Wake: 3: Me
              Coffee: 5: Me
            section Work
              Standup: 2: Team
        """) else { return XCTFail("parse failed") }
        let layout = DiagramLayoutEngine.layout(journey, measure: measure)

        XCTAssertGreaterThan(layout.size.width, 0)
        XCTAssertGreaterThan(layout.size.height, 0)
        XCTAssertEqual(layout.tasks.count, 3)
        // Rows flow top-to-bottom.
        XCTAssertLessThan(layout.tasks[0].scoreCenter.y, layout.tasks[1].scoreCenter.y)
        // Score badge sits left of its label.
        XCTAssertLessThan(layout.tasks[0].scoreCenter.x, layout.tasks[0].labelPoint.x)
        // Two sections → two tint bands.
        XCTAssertEqual(layout.sections.count, 2)
        XCTAssertEqual(Set(layout.sections.map(\.name)), ["Morning", "Work"])
    }

    func testQuadrantLayout() {
        guard case .quadrant(let chart)? = MermaidParser.parse("""
        quadrantChart
            x-axis Low --> High
            y-axis Low --> High
            "TopRight": [0.9, 0.9]
            "BottomLeft": [0.1, 0.1]
        """) else { return XCTFail("parse failed") }
        let layout = DiagramLayoutEngine.layout(chart, measure: measure)

        XCTAssertGreaterThan(layout.size.width, 0)
        XCTAssertGreaterThan(layout.size.height, 0)
        XCTAssertEqual(layout.quadrantRects.count, 4)
        XCTAssertEqual(layout.points.count, 2)

        // y flips: a point at y=0.9 sits near the top (small screen-y) and a
        // point at x=0.9 sits toward the right.
        let topRight = layout.points.first { $0.label == "TopRight" }!
        let bottomLeft = layout.points.first { $0.label == "BottomLeft" }!
        XCTAssertLessThan(topRight.position.y, bottomLeft.position.y)      // higher = smaller y
        XCTAssertGreaterThan(topRight.position.x, bottomLeft.position.x)
        // Every point lands inside the plot.
        for point in layout.points {
            XCTAssertTrue(layout.plotRect.insetBy(dx: -0.5, dy: -0.5).contains(point.position))
        }
    }
}
