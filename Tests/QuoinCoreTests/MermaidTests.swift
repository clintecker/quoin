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
        XCTAssertNil(MermaidParser.parse("classDiagram\n  A <|-- B"))
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
