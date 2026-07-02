import XCTest
@testable import QuoinCore

final class MarkdownConverterTests: XCTestCase {

    // MARK: - Basic structure

    func testHeadingsAndOutline() {
        let doc = MarkdownConverter.parse("""
        # Title

        ## Section One

        Body text.

        ## Section One

        ### Deep
        """)

        XCTAssertEqual(doc.outline.count, 4)
        XCTAssertEqual(doc.outline[0].level, 1)
        XCTAssertEqual(doc.outline[0].title, "Title")
        XCTAssertEqual(doc.outline[0].slug, "title")
        XCTAssertEqual(doc.outline[1].slug, "section-one")
        // GitHub-style dedupe for repeated headings.
        XCTAssertEqual(doc.outline[2].slug, "section-one-1")
        XCTAssertEqual(doc.stats.headingCount, 4)
    }

    func testParagraphInlines() {
        let doc = MarkdownConverter.parse("Some **bold** and *italic* and `code` and [a link](https://example.com).")
        guard case .paragraph(let inlines) = doc.blocks[0].kind else {
            return XCTFail("expected paragraph")
        }
        XCTAssertEqual(inlines.plainText, "Some bold and italic and code and a link.")
        XCTAssertEqual(doc.stats.linkCount, 1)
    }

    func testTable() {
        let doc = MarkdownConverter.parse("""
        | Name | Value |
        |:-----|------:|
        | a    | 1     |
        | b    | 2     |
        """)
        guard case .table(let header, let rows, let alignments) = doc.blocks[0].kind else {
            return XCTFail("expected table")
        }
        XCTAssertEqual(header.count, 2)
        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(header[0].inlines.plainText, "Name")
        XCTAssertEqual(rows[1][1].inlines.plainText, "2")
        XCTAssertEqual(alignments, [.left, .right])
        XCTAssertEqual(doc.stats.tableCount, 1)
    }

    func testTaskListWithMarkerRanges() throws {
        let source = """
        - [ ] first
        - [x] second
        - plain item
        """
        let doc = MarkdownConverter.parse(source)
        guard case .list(let items, let ordered, _) = doc.blocks[0].kind else {
            return XCTFail("expected list")
        }
        XCTAssertFalse(ordered)
        XCTAssertEqual(items.count, 3)
        XCTAssertEqual(items[0].task, .unchecked)
        XCTAssertEqual(items[1].task, .checked)
        XCTAssertNil(items[2].task)

        // Marker ranges must point at the exact `[ ]` / `[x]` bytes.
        let firstMarker = try XCTUnwrap(items[0].taskMarkerRange)
        XCTAssertEqual(source.substring(in: firstMarker), "[ ]")
        let secondMarker = try XCTUnwrap(items[1].taskMarkerRange)
        XCTAssertEqual(source.substring(in: secondMarker), "[x]")

        XCTAssertEqual(doc.stats.taskTotal, 2)
        XCTAssertEqual(doc.stats.taskDone, 1)
    }

    func testNestedBlockQuote() {
        let doc = MarkdownConverter.parse("> quoted text\n>\n> more")
        guard case .blockQuote(let children) = doc.blocks[0].kind else {
            return XCTFail("expected block quote")
        }
        XCTAssertEqual(children.count, 2)
    }

    // MARK: - Fences

    func testMermaidFence() {
        let doc = MarkdownConverter.parse("```mermaid\ngraph TD\n  A --> B\n```")
        guard case .mermaid(let source) = doc.blocks[0].kind else {
            return XCTFail("expected mermaid block")
        }
        XCTAssertEqual(source, "graph TD\n  A --> B")
        XCTAssertEqual(doc.stats.diagramCount, 1)
        XCTAssertEqual(doc.stats.codeBlockCount, 0)
    }

    func testMathFence() {
        let doc = MarkdownConverter.parse("```math\n\\frac{a}{b}\n```")
        guard case .mathBlock(let latex) = doc.blocks[0].kind else {
            return XCTFail("expected math block")
        }
        XCTAssertEqual(latex, "\\frac{a}{b}")
    }

    func testRegularCodeBlockKeepsLanguage() {
        let doc = MarkdownConverter.parse("```swift\nlet x = 1\n```")
        guard case .codeBlock(let language, let code) = doc.blocks[0].kind else {
            return XCTFail("expected code block")
        }
        XCTAssertEqual(language, "swift")
        XCTAssertEqual(code, "let x = 1")
    }

    // MARK: - Math

    func testInlineMath() {
        let doc = MarkdownConverter.parse("Euler says $e^{i\\pi} + 1 = 0$ famously.")
        guard case .paragraph(let inlines) = doc.blocks[0].kind else {
            return XCTFail("expected paragraph")
        }
        XCTAssertTrue(inlines.contains(.math(latex: "e^{i\\pi} + 1 = 0")))
        XCTAssertEqual(doc.stats.mathCount, 1)
    }

    func testInlineMathWithUnderscoresSurvivesEmphasisParsing() {
        // cmark would parse a_b + c_d as emphasis; the slice-based math pass
        // must keep the span intact.
        let doc = MarkdownConverter.parse("Value $a_b + c_d$ here.")
        guard case .paragraph(let inlines) = doc.blocks[0].kind else {
            return XCTFail("expected paragraph")
        }
        XCTAssertTrue(inlines.contains(.math(latex: "a_b + c_d")))
    }

    func testDisplayMathBecomesBlock() {
        let doc = MarkdownConverter.parse("$$\n\\int_0^1 x\\,dx = \\tfrac12\n$$")
        guard case .mathBlock(let latex) = doc.blocks[0].kind else {
            return XCTFail("expected math block, got \(doc.blocks[0].kind)")
        }
        XCTAssertEqual(latex, "\\int_0^1 x\\,dx = \\tfrac12")
    }

    func testDollarAmountsAreNotMath() {
        let doc = MarkdownConverter.parse("It costs $5 and later $10 total.")
        guard case .paragraph(let inlines) = doc.blocks[0].kind else {
            return XCTFail("expected paragraph")
        }
        XCTAssertEqual(doc.stats.mathCount, 0)
        XCTAssertEqual(inlines.plainText, "It costs $5 and later $10 total.")
    }

    func testEscapedDollarIsLiteral() {
        let doc = MarkdownConverter.parse("Escaped \\$x\\$ is not math.")
        XCTAssertEqual(doc.stats.mathCount, 0)
    }

    func testMathInHeading() {
        let doc = MarkdownConverter.parse("## The $O(n^2)$ problem")
        guard case .heading(_, let inlines, _) = doc.blocks[0].kind else {
            return XCTFail("expected heading")
        }
        XCTAssertTrue(inlines.contains(.math(latex: "O(n^2)")))
    }

    // MARK: - Source map

    func testBlockRangesCoverSource() {
        let source = "# Title\n\nParagraph one.\n\nParagraph two."
        let doc = MarkdownConverter.parse(source)
        XCTAssertEqual(doc.blocks.count, 3)
        XCTAssertEqual(source.substring(in: doc.blocks[0].range), "# Title")
        XCTAssertEqual(source.substring(in: doc.blocks[1].range), "Paragraph one.")
        XCTAssertEqual(source.substring(in: doc.blocks[2].range), "Paragraph two.")
    }

    func testUnicodeSourceRanges() {
        let source = "# Café ☕️\n\nZürich naïveté — emoji 🎉 text."
        let doc = MarkdownConverter.parse(source)
        XCTAssertEqual(source.substring(in: doc.blocks[0].range), "# Café ☕️")
        XCTAssertEqual(doc.outline[0].title, "Café ☕️")
    }

    // MARK: - Stats

    func testStats() {
        let doc = MarkdownConverter.parse("""
        # Title

        One two three four five.

        ![alt](img.png) and [link](https://x.y).
        """)
        XCTAssertEqual(doc.stats.headingCount, 1)
        XCTAssertEqual(doc.stats.imageCount, 1)
        XCTAssertEqual(doc.stats.linkCount, 1)
        XCTAssertGreaterThanOrEqual(doc.stats.wordCount, 7)
        XCTAssertGreaterThanOrEqual(doc.stats.readingTimeMinutes, 1)
    }

    // MARK: - Identity & diff

    func testUnchangedBlocksKeepIdentityAcrossReparse() {
        let a = MarkdownConverter.parse("# Title\n\nStable paragraph.\n\nChanging paragraph.")
        let b = MarkdownConverter.parse("# Title\n\nStable paragraph.\n\nChanged text!")
        let diff = BlockDiff.between(old: a.blocks, new: b.blocks)
        XCTAssertEqual(diff.unchanged.count, 2)
        XCTAssertEqual(diff.inserted.count, 1)
        XCTAssertEqual(diff.removed.count, 1)
    }

    func testRepeatedIdenticalBlocksGetDistinctIdentity() {
        let doc = MarkdownConverter.parse("Same.\n\nSame.\n\nSame.")
        let ids = Set(doc.blocks.map(\.id))
        XCTAssertEqual(ids.count, 3)
    }

    // MARK: - Robustness

    func testEmptyDocument() {
        let doc = MarkdownConverter.parse("")
        XCTAssertTrue(doc.blocks.isEmpty)
        XCTAssertTrue(doc.outline.isEmpty)
    }

    func testHTMLBlockPreservedAsLiteral() {
        let doc = MarkdownConverter.parse("<div>\nraw\n</div>")
        guard case .htmlBlock = doc.blocks[0].kind else {
            return XCTFail("expected html block")
        }
    }
}
