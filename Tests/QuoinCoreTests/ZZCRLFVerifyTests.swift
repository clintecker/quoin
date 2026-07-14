import XCTest
@testable import QuoinCore

final class ZZCRLFVerifyTests: XCTestCase {

    // Full finding scenario: CRLF doc with a mark + RDFM endmatter.
    func testCRLFEndmatterScenario() throws {
        let source = "Body {++new text++}{#s1} here.\r\n\r\n---\r\nsuggestions:\r\n  s1: { by: AI }\r\n"

        // 1. detect on CRLF
        let detected = ReviewEndmatter.detect(in: source)
        print("VERIFY detect:", detected as Any)

        // 2. document parse — metadata attached? endmatter block kind?
        let document = MarkdownConverter.parse(source)
        print("VERIFY metadata:", document.reviewMetadata as Any)
        print("VERIFY blocks:", document.blocks.map { String(describing: $0.kind).prefix(60) })

        // 3. resolve the mark
        let marks = SuggestionResolver.marks(in: document)
        print("VERIFY marks:", marks)
        guard let mark = marks.first else { print("VERIFY no marks found"); return }
        guard let edit = SuggestionResolver.combinedResolutionEdit(
            resolving: mark.range, in: source, action: .accept) else {
            print("VERIFY no combined edit"); return
        }
        var bytes = Array(source.utf8)
        bytes.replaceSubrange(edit.range.offset..<(edit.range.offset + edit.range.length),
                              with: Array(edit.replacement.utf8))
        let result = String(decoding: bytes, as: UTF8.self)
        print("VERIFY result after accept:\n\(result.replacingOccurrences(of: "\r", with: "<CR>"))")
        let endmatterCount = result.components(separatedBy: "---").count - 1
        print("VERIFY delimiter count:", endmatterCount)
    }

    // Baseline: same doc with LF only.
    func testLFEndmatterBaseline() throws {
        let source = "Body {++new text++}{#s1} here.\n\n---\nsuggestions:\n  s1: { by: AI }\n"
        let detected = ReviewEndmatter.detect(in: source)
        print("BASELINE detect:", detected != nil)
        let document = MarkdownConverter.parse(source)
        print("BASELINE metadata:", document.reviewMetadata as Any)
    }
}
