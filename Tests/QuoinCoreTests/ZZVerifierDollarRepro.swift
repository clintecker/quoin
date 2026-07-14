import XCTest
@testable import QuoinCore

final class ZZVerifierDollarRepro: XCTestCase {
    func testCurrencyDollarsSwallowMark() throws {
        let source = "It costs $5 to run {++per month++} at $10 scale.\n"
        // 1. Raw scanner level
        let segments = CriticScanner.scan(source)
        print("REPRO segments:", segments)
        // 2. Full pipeline level
        let document = MarkdownConverter.parse(source)
        print("REPRO suggestionCount:", document.stats.suggestionCount,
              "mathCount:", document.stats.mathCount)
        // 3. Control: same paragraph, no dollars
        let control = MarkdownConverter.parse("It costs five to run {++per month++} at ten scale.\n")
        print("CONTROL suggestionCount:", control.stats.suggestionCount)
        // 4. Only ONE dollar before the mark (unpaired) — does it still swallow?
        let single = MarkdownConverter.parse("It costs $5 to run {++per month++} at scale.\n")
        print("SINGLE-$ suggestionCount:", single.stats.suggestionCount)
        // 5. What does MathScanner itself think of the failing paragraph?
        print("MATHSCAN:", MathScanner.scan(source))
    }
}
