import XCTest
@testable import QuoinCore

final class MathParserTests: XCTestCase {

    func testSimpleExpression() {
        let node = MathParser.parse("x+1")
        guard case .row(let children) = node else { return XCTFail("expected row") }
        XCTAssertEqual(children, [
            .symbol("x", .ordinary, style: .italic),
            .symbol("+", .binary, style: .roman),
            .symbol("1", .ordinary, style: .roman),
        ])
        XCTAssertTrue(MathParser.isFullySupported(node))
    }

    func testFraction() {
        let node = MathParser.parse("\\frac{a}{b}")
        guard case .fraction(let n, let d) = node else { return XCTFail("expected fraction") }
        XCTAssertEqual(n, .symbol("a", .ordinary, style: .italic))
        XCTAssertEqual(d, .symbol("b", .ordinary, style: .italic))
    }

    func testMathbfIsBold() {
        // \mathbf must produce an upright bold symbol, distinct from roman.
        guard case .symbol(let glyph, _, let style) = MathParser.parse("\\mathbf{x}") else {
            return XCTFail("expected symbol")
        }
        XCTAssertEqual(glyph, "x")
        XCTAssertEqual(style, .bold)
    }

    func testMathbbStaysRoman() {
        guard case .symbol(let glyph, _, let style) = MathParser.parse("\\mathbb{R}") else {
            return XCTFail("expected symbol")
        }
        XCTAssertEqual(glyph, "ℝ")
        XCTAssertEqual(style, .roman)
    }

    func testScripts() {
        let node = MathParser.parse("x_i^2")
        guard case .scripts(let base, let sub, let sup) = node else { return XCTFail("expected scripts") }
        XCTAssertEqual(base, .symbol("x", .ordinary, style: .italic))
        XCTAssertEqual(sub, .symbol("i", .ordinary, style: .italic))
        XCTAssertEqual(sup, .symbol("2", .ordinary, style: .roman))
    }

    func testGroupedSuperscript() {
        let node = MathParser.parse("e^{i\\pi}")
        guard case .scripts(_, _, let sup) = node,
              case .row(let children) = sup else { return XCTFail("expected grouped sup") }
        XCTAssertEqual(children.count, 2)
        XCTAssertEqual(children[1], .symbol("π", .ordinary, style: .roman))
    }

    func testSqrtWithDegree() {
        let node = MathParser.parse("\\sqrt[3]{x}")
        guard case .radical(let degree, let radicand) = node else { return XCTFail("expected radical") }
        XCTAssertEqual(degree, .symbol("3", .ordinary, style: .roman))
        XCTAssertEqual(radicand, .symbol("x", .ordinary, style: .italic))
    }

    func testGreekAndOperators() {
        let node = MathParser.parse("\\alpha \\leq \\sum")
        guard case .row(let children) = node else { return XCTFail("expected row") }
        XCTAssertEqual(children, [
            .symbol("α", .ordinary, style: .roman),
            .symbol("≤", .relation, style: .roman),
            .symbol("∑", .largeOperator, style: .roman),
        ])
    }

    func testLeftRightDelimiters() {
        let node = MathParser.parse("\\left( \\frac{x}{2} \\right)")
        guard case .delimited(let l, let body, let r) = node else { return XCTFail("expected delimited") }
        XCTAssertEqual(l, "(")
        XCTAssertEqual(r, ")")
        if case .fraction = body {} else { XCTFail("expected fraction body") }
    }

    func testFunctionName() {
        let node = MathParser.parse("\\sin x")
        guard case .row(let children) = node else { return XCTFail("expected row") }
        XCTAssertEqual(children.first, .functionName("sin"))
    }

    func testMathbb() {
        let node = MathParser.parse("\\mathbb{R}")
        XCTAssertEqual(node, .symbol("ℝ", .ordinary, style: .roman))
    }

    func testUnknownCommandIsUnsupportedNotFatal() {
        let node = MathParser.parse("x + \\undefinedmacro{y}")
        XCTAssertFalse(MathParser.isFullySupported(node))
    }

    func testMinusBecomesProperGlyph() {
        let node = MathParser.parse("a-b")
        guard case .row(let children) = node else { return XCTFail("expected row") }
        XCTAssertEqual(children[1], .symbol("−", .binary, style: .roman))
    }

    func testEulerIdentityFullySupported() {
        XCTAssertTrue(MathParser.isFullySupported(MathParser.parse("e^{i\\pi} + 1 = 0")))
        XCTAssertTrue(MathParser.isFullySupported(MathParser.parse("\\int_0^1 x^2 \\, dx = \\frac{1}{3}")))
        XCTAssertTrue(MathParser.isFullySupported(MathParser.parse("\\sum_{i=1}^{n} i = \\frac{n(n+1)}{2}")))
    }

    func testPmatrixParsesRowsColumnsAndFences() {
        let node = MathParser.parse("\\begin{pmatrix} a & b \\\\ c & d \\end{pmatrix}")
        guard case .matrix(let rows, let left, let right, let style) = node else {
            return XCTFail("expected matrix, got \(node)")
        }
        XCTAssertEqual(left, "(")
        XCTAssertEqual(right, ")")
        XCTAssertEqual(style, .centered)
        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(rows[0].count, 2)
        XCTAssertEqual(rows[1].count, 2)
        XCTAssertTrue(MathParser.isFullySupported(node))
    }

    func testCasesEnvironmentIsLeftAlignedBraced() {
        let node = MathParser.parse("f(x) = \\begin{cases} 0, & x < 0 \\\\ 1, & x \\geq 0 \\end{cases}")
        guard case .row(let children) = node,
              let matrix = children.first(where: { if case .matrix = $0 { return true }; return false }),
              case .matrix(let rows, let left, _, let style) = matrix else {
            return XCTFail("expected a cases matrix in the row")
        }
        XCTAssertEqual(left, "{")
        XCTAssertEqual(style, .cases)
        XCTAssertEqual(rows.count, 2)
        XCTAssertTrue(MathParser.isFullySupported(node))
    }

    func testAlignedEnvironmentParses() {
        let node = MathParser.parse("\\begin{aligned} x &= a + b \\\\ y &= c \\end{aligned}")
        guard case .matrix(let rows, _, _, let style) = node else {
            return XCTFail("expected aligned matrix")
        }
        XCTAssertEqual(style, .aligned)
        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(rows[0].count, 2)
        XCTAssertTrue(MathParser.isFullySupported(node))
    }

    func testAlignedatSkipsColumnCountArgument() {
        // The `{3}` after alignedat must not leak into the first cell.
        let node = MathParser.parse("\\begin{alignedat}{3} a &= b \\end{alignedat}")
        guard case .matrix(let rows, _, _, _) = node else { return XCTFail("expected matrix") }
        XCTAssertEqual(rows.count, 1)
        XCTAssertTrue(MathParser.isFullySupported(node))
    }
}
