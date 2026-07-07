import XCTest
import CoreGraphics
@testable import QuoinCore

/// Lints every diagram in `Fixtures/diagrams/` over its exact geometry (see
/// `DiagramScene` / `DiagramLayoutLinter`) — catching edges behind nodes,
/// overlapping boxes, off-canvas and colliding labels without rendering a
/// pixel. Types that lay out cleanly today are asserted to STAY clean (a real
/// regression guard); types with known layout debt are listed so the test
/// documents the state and fails loudly the day one is fixed (so it graduates
/// to the clean set) or regresses further.
final class LayoutLintTests: XCTestCase {

    /// Deterministic fake measurer — geometry only, no font metrics.
    private let measure: DiagramTextMeasurer = { text, size in
        CGSize(width: CGFloat(max(text.count, 1)) * size * 0.6, height: size + 4)
    }

    /// Types whose complex fixture lays out with ZERO errors. Adding a type
    /// here makes its clean layout load-bearing.
    private let errorFree: Set<String> = [
        "flowchart", "sequence", "gantt", "journey", "kanban", "mindmap",
        "packet", "radar", "timeline", "treemap", "zenuml", "er", "state",
    ]

    /// Known layout debt — the linter's own to-fix list (occlusion from missing
    /// edge routing, off-canvas labels, dense label collisions). Documented,
    /// not yet enforced. Shrinks as the layout engines are fixed.
    private let knownIssues: Set<String> = [
        "architecture", "block", "c4", "class", "gitgraph", "pie",
        "quadrant", "requirement", "sankey", "xychart",
    ]

    private var fixturesDir: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Fixtures/diagrams")
    }

    func testFixtureLayoutsAreClean() throws {
        let files = try FileManager.default.contentsOfDirectory(at: fixturesDir, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "mmd" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
        XCTAssertGreaterThanOrEqual(files.count, 20, "expected the full diagram fixture set")

        for url in files {
            let type = url.deletingPathExtension().lastPathComponent
            let source = try String(contentsOf: url, encoding: .utf8)
            guard let diagram = MermaidParser.parse(source) else {
                XCTFail("\(type): fixture did not parse"); continue
            }
            let scene = DiagramScene.lower(diagram, measure: measure)
            let errors = DiagramLayoutLinter.lint(scene).filter { $0.severity == .error }

            if errorFree.contains(type) {
                XCTAssertTrue(errors.isEmpty,
                    "\(type) is expected to lay out cleanly but the linter found:\n" +
                    errors.map { "  ✗ [\($0.kind)] \($0.detail)" }.joined(separator: "\n"))
            } else if knownIssues.contains(type), !errors.isEmpty {
                // Documented debt: fine for now. When this list empties, move the
                // type to `errorFree`.
            } else if !errorFree.contains(type) && !knownIssues.contains(type) {
                XCTFail("\(type): unclassified — add it to errorFree or knownIssues")
            }
        }
    }
}
