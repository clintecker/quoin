#if canImport(AppKit) || canImport(UIKit)
import Foundation
import QuoinCore

#if canImport(AppKit)
import AppKit
#else
import UIKit
#endif

/// Styles the active block's raw markdown for in-place editing: content
/// renders close to its final look while delimiters obey the handoff's
/// span-level syntax-reveal rule — the span containing the caret shows its
/// delimiters at 35% ink in mono, every other span's delimiters collapse
/// to invisible. Crucially, nothing is inserted or removed — every
/// character of the source is present exactly once, so caret/edit mapping
/// stays 1:1 (hidden delimiters are clear-colored at a 1pt font).
struct MarkdownSourceStyler {

    let theme: Theme

    /// `caretOffset` is the caret position in UTF-16 units relative to
    /// `source`. nil reveals every delimiter (whole-block flip mode for
    /// code/math/mermaid blocks, and before the caret has landed).
    func style(_ source: String, caretOffset: Int? = nil) -> NSAttributedString {
        let output = NSMutableAttributedString(string: source, attributes: baseAttributes())
        let text = source as NSString

        styleLinePrefixes(in: output, text: text, caretOffset: caretOffset)
        styleSpans(in: output, text: text, caretOffset: caretOffset)
        return output
    }

    private func baseAttributes() -> [NSAttributedString.Key: Any] {
        let style = NSMutableParagraphStyle()
        style.lineHeightMultiple = 1.5
        return [
            .font: theme.bodyFont(),
            .foregroundColor: theme.ink,
            .backgroundColor: theme.accent.withAlphaComponent(0.05),
            .paragraphStyle: style,
            QuoinAttribute.editableSource: NSNumber(value: true),
        ]
    }

    private var delimiterAttributes: [NSAttributedString.Key: Any] {
        [
            .font: theme.inlineCodeFont(),
            .foregroundColor: theme.ink.withAlphaComponent(0.35),
        ]
    }

    /// Delimiters of spans the caret is outside of: still present in the
    /// text (mapping stays 1:1) but visually collapsed.
    private var hiddenDelimiterAttributes: [NSAttributedString.Key: Any] {
        [
            .font: PlatformFont.systemFont(ofSize: 1),
            .foregroundColor: PlatformColor.clear,
        ]
    }

    // MARK: - Line prefixes (#, >, bullets, checkboxes)

    private func styleLinePrefixes(in output: NSMutableAttributedString, text: NSString, caretOffset: Int?) {
        var lineStart = 0
        while lineStart <= text.length {
            let lineRange = text.lineRange(for: NSRange(location: min(lineStart, max(text.length - 1, 0)), length: 0))
            defer {
                lineStart = lineRange.location + max(lineRange.length, 1)
            }
            let line = text.substring(with: lineRange)
            let caretOnLine = caretOffset.map {
                $0 >= lineRange.location && $0 <= lineRange.location + lineRange.length
            } ?? true

            // Headings: marks reveal only while the caret is on the line;
            // the body always styles with the heading ramp.
            if let hashes = prefixLength(of: line, matching: { $0 == "#" }), hashes >= 1, hashes <= 6,
               line.dropFirst(hashes).first == " " {
                output.addAttributes(
                    caretOnLine ? delimiterAttributes : hiddenDelimiterAttributes,
                    range: NSRange(location: lineRange.location, length: hashes + 1)
                )
                let bodyStart = lineRange.location + hashes + 1
                let bodyLength = lineRange.length - hashes - 1
                if bodyLength > 0 {
                    output.addAttributes([
                        .font: theme.headingFont(level: hashes),
                        .foregroundColor: hashes <= 3 ? theme.ink : theme.secondaryTextColor,
                    ], range: NSRange(location: bodyStart, length: bodyLength))
                }
                if lineRange.length == 0 { break }
                continue
            }

            // Quote / list / task markers are structural — without them the
            // block's shape is unreadable — so they stay faded-visible
            // regardless of the caret.
            let markers = ["> ", "- [ ] ", "- [x] ", "- [X] ", "- ", "* ", "+ "]
            let trimmed = line.drop(while: { $0 == " " || $0 == "\t" })
            let indent = line.count - trimmed.count
            for marker in markers where trimmed.hasPrefix(marker) {
                output.addAttributes(
                    delimiterAttributes,
                    range: NSRange(location: lineRange.location + indent, length: marker.utf16.count)
                )
                break
            }

            if lineRange.length == 0 { break }
        }
    }

    private func prefixLength(of line: String, matching predicate: (Character) -> Bool) -> Int? {
        var count = 0
        for ch in line {
            if predicate(ch) { count += 1 } else { break }
        }
        return count > 0 ? count : nil
    }

    // MARK: - Inline spans

    private func styleSpans(in output: NSMutableAttributedString, text: NSString, caretOffset: Int?) {
        // Order matters: code spans first (their interiors are then left
        // alone), then double-char delimiters before their single-char
        // prefixes.
        styleDelimited(in: output, text: text, delimiter: "`", contentAttributes: [
            .font: theme.inlineCodeFont(),
            .backgroundColor: theme.inlineCodeFill,
        ], excludeCode: false, caretOffset: caretOffset)

        styleDelimited(in: output, text: text, delimiter: "**", contentAttributes: [
            .font: theme.boldBodyFont(),
        ], caretOffset: caretOffset)
        styleDelimited(in: output, text: text, delimiter: "==", contentAttributes: [
            .backgroundColor: Theme.Highlight.lime.color,
        ], caretOffset: caretOffset)
        styleDelimited(in: output, text: text, delimiter: "$", contentAttributes: [
            .font: theme.inlineCodeFont(),
            .foregroundColor: theme.accent,
        ], caretOffset: caretOffset)
    }

    /// Finds `delimiter…delimiter` pairs on a single line and styles the
    /// content with `contentAttributes`. The delimiters render faded when
    /// the caret sits inside the span (delimiters included) and collapse
    /// to invisible otherwise. Skips spans that fall inside already-styled
    /// code (unless styling code itself).
    private func styleDelimited(
        in output: NSMutableAttributedString,
        text: NSString,
        delimiter: String,
        contentAttributes: [NSAttributedString.Key: Any],
        excludeCode: Bool = true,
        caretOffset: Int?
    ) {
        let delimiterLength = delimiter.utf16.count
        var search = NSRange(location: 0, length: text.length)

        while search.length > delimiterLength {
            let open = text.range(of: delimiter, options: [], range: search)
            guard open.location != NSNotFound else { break }
            let afterOpen = NSRange(
                location: open.location + delimiterLength,
                length: text.length - open.location - delimiterLength
            )
            guard afterOpen.length > 0 else { break }
            let close = text.range(of: delimiter, options: [], range: afterOpen)
            guard close.location != NSNotFound else { break }

            let contentRange = NSRange(
                location: open.location + delimiterLength,
                length: close.location - open.location - delimiterLength
            )
            let spansNewline = text.substring(with: contentRange).contains("\n")
            let insideCode = excludeCode && isCode(output, at: open.location)

            if contentRange.length > 0 && !spansNewline && !insideCode {
                let spanEnd = close.location + delimiterLength
                let caretInSpan = caretOffset.map { $0 >= open.location && $0 <= spanEnd } ?? true
                let marks = caretInSpan ? delimiterAttributes : hiddenDelimiterAttributes
                output.addAttributes(marks, range: open)
                output.addAttributes(marks, range: NSRange(location: close.location, length: delimiterLength))
                output.addAttributes(contentAttributes, range: contentRange)
            }

            let next = close.location + delimiterLength
            search = NSRange(location: next, length: text.length - next)
        }
    }

    private func isCode(_ output: NSAttributedString, at location: Int) -> Bool {
        guard location < output.length else { return false }
        let font = output.attribute(.font, at: location, effectiveRange: nil) as? PlatformFont
        let background = output.attribute(.backgroundColor, at: location, effectiveRange: nil) as? PlatformColor
        return font == theme.inlineCodeFont() && background != nil
    }
}
#endif
