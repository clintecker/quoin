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

    // MARK: - Diagnostics (Phase 0)

    func testUnsupportedCommandsNamesTheCulprit() {
        let node = MathParser.parse("\\xcancel{x}")
        XCTAssertFalse(MathParser.isFullySupported(node))
        XCTAssertEqual(MathParser.unsupportedCommands(in: node), ["\\xcancel"])
    }

    func testUnsupportedCommandsDedupesAndPreservesOrder() {
        let node = MathParser.parse("\\foo x + \\zzz y + \\foo z")
        XCTAssertEqual(MathParser.unsupportedCommands(in: node), ["\\foo", "\\zzz"])
    }

    func testUnsupportedCommandsCaps() {
        let node = MathParser.parse("\\a \\b \\c \\d \\e \\f")
        XCTAssertEqual(MathParser.unsupportedCommands(in: node, limit: 4).count, 4)
    }

    func testUnsupportedCommandsFindsCulpritInsideStructure() {
        // A single unsupported command buried in a fraction still surfaces.
        let node = MathParser.parse("\\frac{1}{\\xcancel{a}}")
        XCTAssertEqual(MathParser.unsupportedCommands(in: node), ["\\xcancel"])
    }

    func testFullySupportedExpressionHasNoUnsupportedCommands() {
        let node = MathParser.parse("\\frac{-b \\pm \\sqrt{b^2 - 4ac}}{2a}")
        XCTAssertTrue(MathParser.unsupportedCommands(in: node).isEmpty)
    }

    // MARK: - Math alphabets (Phase 1)

    func testMathbbFullAlphabet() {
        // Blackboard maps every letter, with the Letterlike holes.
        XCTAssertEqual(glyph("\\mathbb{R}"), "ℝ")  // hole
        XCTAssertEqual(glyph("\\mathbb{A}"), "𝔸")  // contiguous block
        XCTAssertEqual(glyph("\\mathbb{k}"), "𝕜")  // lowercase
    }

    func testCalligraphicAndFraktur() {
        XCTAssertEqual(glyph("\\mathcal{L}"), "ℒ")   // script hole
        XCTAssertEqual(glyph("\\mathcal{A}"), "𝒜")   // script block
        XCTAssertEqual(glyph("\\mathfrak{g}"), "𝔤")  // fraktur
        XCTAssertEqual(glyph("\\mathscr{B}"), "ℬ")   // scr == cal
    }

    func testSansAndMonospace() {
        XCTAssertEqual(glyph("\\mathsf{X}"), "𝖷")
        XCTAssertEqual(glyph("\\mathtt{x}"), "𝚡")
        XCTAssertEqual(glyph("\\mathsf{5}"), "𝟧")   // sans digits
    }

    func testMathbfStillBoldStyle() {
        // Unchanged: \mathbf renders with a bold system font, not a codepoint.
        guard case .symbol("x", _, let style) = MathParser.parse("\\mathbf{x}") else {
            return XCTFail("expected symbol")
        }
        XCTAssertEqual(style, .bold)
    }

    // MARK: - Direct-typed Unicode (Phase 1)

    func testDirectUnicodeOperatorGetsLargeOperatorClass() {
        guard case .symbol("∫", .largeOperator, _) = MathParser.parse("∫") else {
            return XCTFail("a directly-typed ∫ must class as a large operator")
        }
    }

    func testDirectUnicodeRelationGetsRelationClass() {
        guard case .symbol("≤", .relation, _) = MathParser.parse("≤") else {
            return XCTFail("≤ must class as a relation")
        }
    }

    func testDirectGreekMatchesCommandForm() {
        guard case .symbol("α", let cls, .italic) = MathParser.parse("α") else {
            return XCTFail("α should be italic ordinary")
        }
        XCTAssertEqual(cls, .ordinary)
    }

    // MARK: - Operators & \big (Phase 1)

    func testBigDelimitersAreTransparent() {
        // \big( no longer degrades — it passes the ( through as an opening.
        let node = MathParser.parse("\\big( x \\big)")
        XCTAssertTrue(MathParser.isFullySupported(node))
    }

    func testNegativeThinSpace() {
        guard case .space(let width) = MathParser.parse("\\!") else {
            return XCTFail("expected space")
        }
        XCTAssertLessThan(width, 0)
    }

    func testExtraOperatorNames() {
        for op in ["\\Pr", "\\argmax", "\\limsup"] {
            XCTAssertTrue(MathParser.isFullySupported(MathParser.parse(op)), "\(op) should render")
        }
    }

    // MARK: - Accents & genfrac (Phase 2)

    func testAccentParses() {
        guard case .accent(_, let accent) = MathParser.parse("\\hat{x}") else {
            return XCTFail("expected accent")
        }
        XCTAssertEqual(accent, .hat)
        XCTAssertTrue(MathParser.isFullySupported(MathParser.parse("\\vec{v} + \\bar{y} + \\dot{z}")))
    }

    func testOverlineUnderlineAreAccents() {
        guard case .accent(_, .overline) = MathParser.parse("\\overline{AB}") else {
            return XCTFail("expected overline accent")
        }
        guard case .accent(_, .underline) = MathParser.parse("\\underline{x}") else {
            return XCTFail("expected underline accent")
        }
    }

    func testWideAccentsAreStretchy() {
        guard case .accent(_, let accent) = MathParser.parse("\\widehat{abc}") else {
            return XCTFail("expected accent")
        }
        XCTAssertTrue(accent.isStretchy)
    }

    func testBinomialIsGenfracWithParensNoRule() {
        guard case .genfrac(_, _, let hasRule, let left, let right) = MathParser.parse("\\binom{n}{k}") else {
            return XCTFail("expected genfrac")
        }
        XCTAssertFalse(hasRule)
        XCTAssertEqual(left, "(")
        XCTAssertEqual(right, ")")
    }

    func testCfracIsAFraction() {
        guard case .fraction = MathParser.parse("\\cfrac{1}{x}") else {
            return XCTFail("expected fraction")
        }
    }

    func testAccentAndBinomFullySupported() {
        XCTAssertTrue(MathParser.isFullySupported(
            MathParser.parse("\\widehat{abc} + \\dbinom{n}{k} + \\overline{z}")))
    }

    // MARK: - Over/under & substack (Phase 3)

    func testOversetUnderset() {
        guard case .overUnder(_, let over, nil, .plain) = MathParser.parse("\\overset{!}{=}") else {
            return XCTFail("expected overset")
        }
        XCTAssertNotNil(over)
        guard case .overUnder(_, nil, let under, .plain) = MathParser.parse("\\underset{x}{y}") else {
            return XCTFail("expected underset")
        }
        XCTAssertNotNil(under)
    }

    func testOverbraceCapturesSuperscriptLabel() {
        // \overbrace{…}^{label} — the ^label becomes the brace annotation,
        // not a superscript on the whole brace.
        guard case .overUnder(_, let over, nil, .overbrace) = MathParser.parse("\\overbrace{a+b}^{s}") else {
            return XCTFail("expected overbrace")
        }
        XCTAssertNotNil(over)
    }

    func testUnderbraceCapturesSubscriptLabel() {
        guard case .overUnder(_, nil, let under, .underbrace) = MathParser.parse("\\underbrace{a+b}_{s}") else {
            return XCTFail("expected underbrace")
        }
        XCTAssertNotNil(under)
    }

    func testStretchyArrows() {
        guard case .overUnder(_, let over, _, .rightarrow) = MathParser.parse("\\xrightarrow{f}") else {
            return XCTFail("expected rightarrow")
        }
        XCTAssertNotNil(over)
        // \xrightarrow[below]{above} — both annotations.
        guard case .overUnder(_, let a, let b, .rightarrow) = MathParser.parse("\\xrightarrow[g]{f}") else {
            return XCTFail("expected rightarrow with both")
        }
        XCTAssertNotNil(a); XCTAssertNotNil(b)
    }

    func testSubstackIsATightMatrix() {
        guard case .matrix(let rows, _, _, .substack) = MathParser.parse("\\substack{a \\\\ b \\\\ c}") else {
            return XCTFail("expected substack matrix")
        }
        XCTAssertEqual(rows.count, 3)
    }

    func testPhase3ConstructsFullySupported() {
        XCTAssertTrue(MathParser.isFullySupported(
            MathParser.parse("\\sum_{\\substack{i<n \\\\ i\\text{ odd}}} \\overbrace{i}^{k} \\xrightarrow{f}")))
    }

    // MARK: - Decorations & color (Phase 5)

    func testBoxedAndPhantom() {
        guard case .decorated(_, .boxed) = MathParser.parse("\\boxed{x}") else {
            return XCTFail("expected boxed")
        }
        guard case .decorated(_, .phantom) = MathParser.parse("\\phantom{x}") else {
            return XCTFail("expected phantom")
        }
        guard case .decorated(_, .vphantom) = MathParser.parse("\\vphantom{x}") else {
            return XCTFail("expected vphantom")
        }
    }

    func testColorTakesNameThenBody() {
        guard case .styled(_, let color) = MathParser.parse("\\color{red}{x + y}") else {
            return XCTFail("expected styled")
        }
        XCTAssertEqual(color, "red")
        guard case .styled(_, let hex) = MathParser.parse("\\textcolor{#00aa88}{z}") else {
            return XCTFail("expected styled")
        }
        XCTAssertEqual(hex, "#00aa88")
    }

    func testDecorationsFullySupported() {
        XCTAssertTrue(MathParser.isFullySupported(
            MathParser.parse("\\boxed{\\color{red}{a} + \\phantom{b}}")))
    }

    // MARK: - Arrays with rules (Phase 4)

    func testHlineNoLongerDegradesArray() {
        // \hline used to become an .unsupported leaf, flipping the whole
        // array to a source card. Now it's consumed; the grid survives.
        let node = MathParser.parse("\\begin{array}{cc} a & b \\\\ \\hline c & d \\end{array}")
        XCTAssertTrue(MathParser.isFullySupported(node))
        guard case .matrix(let rows, _, _, _) = node else { return XCTFail("expected matrix") }
        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(rows[0].count, 2)
    }

    func testClineArgumentConsumed() {
        let node = MathParser.parse("\\begin{array}{cc} a & b \\\\ \\cline{1-2} c & d \\end{array}")
        XCTAssertTrue(MathParser.isFullySupported(node))
    }

    /// Convenience: the single mapped glyph of a one-atom expression.
    private func glyph(_ latex: String) -> String? {
        if case .symbol(let g, _, _) = MathParser.parse(latex) { return g }
        return nil
    }
}
