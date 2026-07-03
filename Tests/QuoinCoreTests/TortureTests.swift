import XCTest
@testable import QuoinCore

/// Pathological inputs: the parser must never crash, hang, or corrupt the
/// source map, no matter how broken the document is.
final class TortureTests: XCTestCase {

    func testDeeplyNestedBlockquotes() {
        let source = (1...60).map { String(repeating: "> ", count: $0) + "level \($0)" }.joined(separator: "\n")
        let doc = MarkdownConverter.parse(source)
        XCTAssertFalse(doc.blocks.isEmpty)
    }

    func testDeeplyNestedLists() {
        let source = (0..<50).map { String(repeating: "  ", count: $0) + "- item" }.joined(separator: "\n")
        let doc = MarkdownConverter.parse(source)
        XCTAssertFalse(doc.blocks.isEmpty)
    }

    func testHugeTable() {
        var source = "| " + (1...30).map { "col\($0)" }.joined(separator: " | ") + " |\n"
        source += "|" + String(repeating: "---|", count: 30) + "\n"
        for row in 1...300 {
            source += "| " + (1...30).map { "r\(row)c\($0)" }.joined(separator: " | ") + " |\n"
        }
        let doc = MarkdownConverter.parse(source)
        guard case .table(let header, let rows, _) = doc.blocks[0].kind else {
            return XCTFail("expected table")
        }
        XCTAssertEqual(header.count, 30)
        XCTAssertEqual(rows.count, 300)
    }

    func testUnclosedFence() {
        let doc = MarkdownConverter.parse("```swift\nlet x = 1\n// never closed")
        XCTAssertFalse(doc.blocks.isEmpty)
    }

    func testUnclosedEverything() {
        let doc = MarkdownConverter.parse("**bold *italic `code $math ==mark [link](")
        XCTAssertFalse(doc.blocks.isEmpty)
        XCTAssertEqual(doc.stats.mathCount, 0)
    }

    func testBrokenMermaidFallsBack() {
        let doc = MarkdownConverter.parse("```mermaid\n%%%% not a diagram {{{\n```")
        guard case .mermaid(let source) = doc.blocks[0].kind else {
            return XCTFail("expected mermaid block")
        }
        XCTAssertNil(MermaidParser.parse(source)) // renderer will fall back
    }

    func testMixedScriptsAndEmoji() {
        let source = "# 日本語の見出し 🎌\n\nمرحبا **بالعالم** и русский текст with 🎉🎊✨ emoji.\n\n- [ ] 完了していないタスク"
        let doc = MarkdownConverter.parse(source)
        XCTAssertEqual(doc.outline.first?.title, "日本語の見出し 🎌")
        guard case .list(let items, _, _) = doc.blocks[2].kind,
              let marker = items[0].taskMarkerRange else {
            return XCTFail("expected task")
        }
        // Marker range must be byte-exact despite multibyte content around it.
        XCTAssertEqual(source.substring(in: marker), "[ ]")
        let toggled = try? TaskToggler.toggle(source: source, markerRange: marker)
        XCTAssertNotNil(toggled)
    }

    func testTenThousandLines() {
        let source = (1...10_000).map { "line \($0) of plain text" }.joined(separator: "\n\n")
        let start = Date()
        let doc = MarkdownConverter.parse(source)
        XCTAssertEqual(doc.blocks.count, 10_000)
        XCTAssertLessThan(Date().timeIntervalSince(start), 5.0)
    }

    func testNullBytesAndControlCharacters() {
        let doc = MarkdownConverter.parse("text with \u{0000} null and \u{0007} bell")
        XCTAssertFalse(doc.blocks.isEmpty)
    }

    func testGiantSingleLine() {
        let doc = MarkdownConverter.parse(String(repeating: "word ", count: 50_000))
        XCTAssertEqual(doc.blocks.count, 1)
    }

    func testMathScannerPathologicalDollars() {
        // 2k unmatched dollars must not go quadratic-catastrophic or crash.
        let source = String(repeating: "$a ", count: 2000)
        let start = Date()
        _ = MarkdownConverter.parse(source)
        XCTAssertLessThan(Date().timeIntervalSince(start), 5.0)
    }

    func testFrontMatterOnlyDocument() {
        let doc = MarkdownConverter.parse("---\ntitle: only\n---")
        guard case .frontMatter = doc.blocks.first?.kind else {
            return XCTFail("expected front matter")
        }
        XCTAssertEqual(doc.blocks.count, 1)
    }
}
