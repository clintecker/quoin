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

    func testUnsupportedTypeReturnsNil() {
        XCTAssertNil(MermaidParser.parse("gantt\n  title Timeline"))
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

    func testStateDiagramMapsToFlowchart() {
        guard case .flowchart(let chart)? = MermaidParser.parse("""
        stateDiagram-v2
            direction LR
            [*] --> Idle
            Idle --> Loading: open
            Loading --> Ready
            Ready --> [*]
            state "Long name" as Loading
        """) else { return XCTFail("expected flowchart from state diagram") }
        XCTAssertEqual(chart.direction, .leftRight)
        XCTAssertEqual(chart.nodes.first?.shape, .stateStart)
        XCTAssertEqual(chart.nodes.last?.shape, .stateEnd)
        XCTAssertEqual(chart.nodes.first(where: { $0.id == "Idle" })?.shape, .rounded)
        XCTAssertEqual(chart.nodes.first(where: { $0.id == "Loading" })?.label, "Long name")
        XCTAssertEqual(chart.edges.count, 4)
        XCTAssertEqual(chart.edges[1].label, "open")
        XCTAssertTrue(chart.edges.allSatisfy(\.hasArrow))
    }

    func testStateTerminalsGetFixedSizes() {
        guard case .flowchart(let chart)? = MermaidParser.parse("""
        stateDiagram
            [*] --> A
            A --> [*]
        """) else { return XCTFail("parse failed") }
        let layout = DiagramLayoutEngine.layout(chart, measure: measure)
        let start = layout.nodes.first { $0.shape == .stateStart }
        let end = layout.nodes.first { $0.shape == .stateEnd }
        XCTAssertEqual(start?.frame.width, 14)
        XCTAssertEqual(end?.frame.width, 18)
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
}
