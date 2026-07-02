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
}
