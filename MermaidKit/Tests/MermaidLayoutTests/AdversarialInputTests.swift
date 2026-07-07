import XCTest
import CoreGraphics
@testable import MermaidLayout

/// The parser and layout engines must never crash, hang, or trap on
/// arbitrary input — a library invites hostile/fuzzed/malformed sources.
/// Every case here runs the FULL pipeline (parse → layout → scene → lint)
/// and asserts only that it returns (nil is always acceptable; crashing is
/// not).
final class AdversarialInputTests: XCTestCase {

    private let measure: DiagramTextMeasurer = { text, size in
        CGSize(width: CGFloat(max(text.count, 1)) * size * 0.6, height: size + 4)
    }

    /// Runs the whole pipeline; the assertion is simply "we got here".
    private func pipeline(_ source: String, _ label: String) {
        guard let diagram = MermaidParser.parse(source) else { return }
        let scene = DiagramScene.lower(diagram, measure: measure)
        _ = DiagramLayoutLinter.lint(scene)
        XCTAssertGreaterThanOrEqual(scene.size.width, 0, label)
    }

    func testEmptyAndWhitespace() {
        for s in ["", " ", "\n", "\n\n\n", "\t\t", "   \n   \n", "\r\n\r\n"] {
            pipeline(s, "whitespace")
        }
    }

    func testHeadersWithNoBody() {
        for header in ["flowchart TD", "sequenceDiagram", "pie", "classDiagram",
                       "erDiagram", "stateDiagram-v2", "gantt", "timeline",
                       "mindmap", "journey", "quadrantChart", "packet-beta",
                       "xychart-beta", "kanban", "radar-beta", "treemap-beta",
                       "gitGraph", "sankey-beta", "requirementDiagram", "zenuml",
                       "C4Context", "architecture-beta", "block-beta"] {
            pipeline(header, header)
            pipeline(header + "\n", header)
            pipeline(header + "\n\n\n", header)
        }
    }

    func testGarbageBodies() {
        let garbage = [
            "{{{{{{{{", "))))((((", "-->", "--> --> -->", ":::::",
            "\u{0}\u{1}\u{2}", "🧜‍♀️🧜‍♀️🧜‍♀️", "＜＞〔〕", "علامة تجريبية",
            "a\u{202E}b", String(repeating: "|", count: 500),
        ]
        for header in ["flowchart TD", "sequenceDiagram", "erDiagram", "gantt",
                       "sankey-beta", "xychart-beta", "gitGraph", "mindmap"] {
            for g in garbage { pipeline(header + "\n" + g, "\(header)+garbage") }
        }
    }

    func testVeryLongSingleLine() {
        let longLabel = String(repeating: "x", count: 100_000)
        pipeline("flowchart TD\n A[\(longLabel)] --> B", "100k label")
        pipeline("pie\n \"\(longLabel)\": 1", "100k pie label")
    }

    func testOversizedInputsRejectedFast() {
        // Past mermaid.js-style caps (maxTextSize / maxEdges) the parser must
        // return nil immediately, not feed a super-linear layout for seconds.
        var flow = "flowchart TD\n"
        for i in 0..<2_000 { flow += " n\(i) --> n\(i + 1)\n" }
        let start = Date()
        XCTAssertNil(MermaidParser.parse(flow), "past-cap input returns nil")
        XCTAssertLessThan(Date().timeIntervalSince(start), 0.5, "rejection must be fast")

        let huge = "flowchart TD\n" + String(repeating: " a --> b\n", count: 10_000)
        XCTAssertNil(MermaidParser.parse(huge), "over maxTextSize returns nil")
    }

    func testAtCapInputCompletes() {
        var flow = "flowchart TD\n"
        for i in 0..<MermaidParser.maxEdges { flow += " n\(i) --> n\(i + 1)\n" }
        let start = Date()
        pipeline(flow, "at-cap edges")
        XCTAssertLessThan(Date().timeIntervalSince(start), 10, "at-cap layout stays interactive-ish")

        var sank = "sankey-beta\n"
        for i in 0..<1_000 { sank += "a\(i),b\(i),1\n" }
        pipeline(sank, "1k sankey links")
    }

    func testDeepNesting() {
        // Mindmap indentation depth and state-diagram composite depth.
        var mind = "mindmap\n root\n"
        for depth in 2..<120 {
            mind += String(repeating: " ", count: depth) + "n\(depth)\n"
        }
        pipeline(mind, "deep mindmap")

        var state = "stateDiagram-v2\n"
        for i in 0..<60 { state += String(repeating: " ", count: i) + "state S\(i) {\n" }
        state += String(repeating: "}\n", count: 60)
        pipeline(state, "deep state nesting")
    }

    func testDuplicateAndSelfReferences() {
        pipeline("sankey-beta\nA,A,5\nA,A,5", "sankey self+dup")
        pipeline("flowchart TD\n A --> A\n A --> A", "flowchart self-loop dup")
        pipeline("erDiagram\n A ||--o{ A : self\n A ||--o{ A : self", "er dup self")
        pipeline("classDiagram\n A --|> A", "class self-inherit")
        pipeline("gitGraph\n commit\n merge main", "merge own branch")
    }

    func testHostileNumbers() {
        pipeline("pie\n \"a\": 1e308\n \"b\": 1e308", "pie 1e308")
        pipeline("pie\n \"a\": -5", "pie negative")
        pipeline("pie\n \"a\": 0\n \"b\": 0", "pie zeros")
        pipeline("xychart-beta\n line [1e308, -1e308, 0]", "xy 1e308")
        pipeline("xychart-beta\n bar [NaN, Infinity]", "xy NaN words")
        pipeline("sankey-beta\nA,B,1e308\nB,C,1e308", "sankey 1e308")
        pipeline("quadrantChart\n P: [5, -3]", "quadrant out of range")
        pipeline("gantt\n title t\n section s\n T :a, 9999-99-99, 1d", "gantt bad date")
    }

    func testCRLFAndMixedLineEndings() {
        pipeline("flowchart TD\r\n A --> B\r\n B --> C", "CRLF flowchart")
        pipeline("gantt\r\n title x\r\n section s\r\n T :t1, 2026-01-01, 1d", "CRLF gantt")
    }

    /// Layout entry points must tolerate hand-built (non-parser) models.
    func testHandBuiltDuplicateSankeyNodes() {
        let diagram = SankeyDiagram(
            nodes: ["A", "A", "B"],
            links: [.init(source: "A", target: "B", value: 1)]
        )
        let layout = DiagramLayoutEngine.layout(diagram, measure: measure)
        XCTAssertGreaterThan(layout.size.width, 0)
    }
}
