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
        while lineStart < text.length {
            // lineRange(for:) at a valid location always spans ≥ 1 char, so
            // advancing to NSMaxRange guarantees progress (the old
            // clamped-location variant re-derived the same final line
            // forever once lineStart reached text.length — a pinwheel).
            let lineRange = text.lineRange(for: NSRange(location: lineStart, length: 0))
            defer {
                lineStart = NSMaxRange(lineRange)
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
        // alone), then bracket constructs, then double-char delimiters
        // before their single-char prefixes (claimed ranges keep the `*` of
        // a styled `**` from matching again).
        var claimed: [NSRange] = []

        styleDelimited(in: output, text: text, delimiter: "`", contentAttributes: [
            .font: theme.inlineCodeFont(),
            .backgroundColor: theme.inlineCodeFill,
        ], excludeCode: false, caretOffset: caretOffset, claimed: &claimed)

        styleLinks(in: output, text: text, caretOffset: caretOffset, claimed: &claimed)

        styleDelimited(in: output, text: text, delimiter: "**", contentAttributes: [
            .font: theme.boldBodyFont(),
        ], caretOffset: caretOffset, claimed: &claimed)
        styleDelimited(in: output, text: text, delimiter: "~~", contentAttributes: [
            .strikethroughStyle: NSUnderlineStyle.single.rawValue,
            .foregroundColor: theme.ink.withAlphaComponent(0.45),
        ], caretOffset: caretOffset, claimed: &claimed)
        styleDelimited(in: output, text: text, delimiter: "==", contentAttributes: [
            .backgroundColor: Theme.Highlight.lime.color,
        ], caretOffset: caretOffset, claimed: &claimed)
        styleDelimited(in: output, text: text, delimiter: "*", contentAttributes: [
            .font: italicFont(),
        ], caretOffset: caretOffset, claimed: &claimed)
        styleDelimited(in: output, text: text, delimiter: "_", contentAttributes: [
            .font: italicFont(),
        ], caretOffset: caretOffset, claimed: &claimed)
        styleDelimited(in: output, text: text, delimiter: "$", contentAttributes: [
            .font: theme.inlineCodeFont(),
            .foregroundColor: theme.accent,
        ], caretOffset: caretOffset, claimed: &claimed)
    }

    private func italicFont() -> PlatformFont {
        #if canImport(AppKit)
        return NSFontManager.shared.convert(theme.bodyFont(), toHaveTrait: .italicFontMask)
        #else
        let base = theme.bodyFont()
        guard let descriptor = base.fontDescriptor.withSymbolicTraits(
            base.fontDescriptor.symbolicTraits.union(.traitItalic)
        ) else { return base }
        return UIFont(descriptor: descriptor, size: base.pointSize)
        #endif
    }

    /// Links `[text](url)` and footnote refs `[^n]`: the brackets and URL
    /// are delimiters (caret-scoped), the link text styles accent+underline.
    private func styleLinks(
        in output: NSMutableAttributedString,
        text: NSString,
        caretOffset: Int?,
        claimed: inout [NSRange]
    ) {
        let source = text as String
        // Footnote refs first so `[^1]` isn't half-matched as a link label.
        if let footnotes = try? NSRegularExpression(pattern: #"\[\^([^\]\n]+)\]"#) {
            for match in footnotes.matches(in: source, range: NSRange(location: 0, length: text.length)) {
                let whole = match.range
                guard !claimed.contains(where: { NSIntersectionRange($0, whole).length > 0 }) else { continue }
                let caretInSpan = caretOffset.map { $0 >= whole.location && $0 <= whole.location + whole.length } ?? true
                output.addAttributes(
                    caretInSpan ? delimiterAttributes : hiddenDelimiterAttributes,
                    range: whole
                )
                if caretInSpan {
                    output.addAttribute(.foregroundColor, value: theme.accent, range: whole)
                } else {
                    // Collapsed: show just the index as the superscript marker.
                    output.addAttributes([
                        .font: PlatformFont.systemFont(ofSize: theme.bodySize * 0.75),
                        .foregroundColor: theme.accent,
                        .baselineOffset: theme.bodySize * 0.33,
                    ], range: match.range(at: 1))
                }
                claimed.append(whole)
            }
        }

        if let links = try? NSRegularExpression(pattern: #"\[([^\]\n]*)\]\(([^)\n]*)\)"#) {
            for match in links.matches(in: source, range: NSRange(location: 0, length: text.length)) {
                let whole = match.range
                guard !claimed.contains(where: { NSIntersectionRange($0, whole).length > 0 }) else { continue }
                let label = match.range(at: 1)
                let caretInSpan = caretOffset.map { $0 >= whole.location && $0 <= whole.location + whole.length } ?? true
                let marks = caretInSpan ? delimiterAttributes : hiddenDelimiterAttributes
                // Brackets + (url) are delimiters; the label keeps link styling.
                output.addAttributes(marks, range: NSRange(location: whole.location, length: label.location - whole.location))
                output.addAttributes(marks, range: NSRange(
                    location: label.location + label.length,
                    length: whole.location + whole.length - label.location - label.length
                ))
                output.addAttributes([
                    .foregroundColor: theme.accent,
                    .underlineStyle: NSUnderlineStyle.single.rawValue,
                    .underlineColor: theme.accent.withAlphaComponent(0.35),
                ], range: label)
                claimed.append(whole)
            }
        }
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
        caretOffset: Int?,
        claimed: inout [NSRange]
    ) {
        let delimiterLength = delimiter.utf16.count
        var search = NSRange(location: 0, length: text.length)

        func isClaimed(_ range: NSRange) -> Bool {
            claimed.contains { NSIntersectionRange($0, range).length > 0 }
        }

        while search.length > delimiterLength {
            let open = text.range(of: delimiter, options: [], range: search)
            guard open.location != NSNotFound else { break }
            // A delimiter already consumed by an earlier pass (`**` before
            // `*`, link URLs) doesn't open a new span.
            if isClaimed(open) {
                let next = open.location + delimiterLength
                search = NSRange(location: next, length: text.length - next)
                continue
            }
            let afterOpen = NSRange(
                location: open.location + delimiterLength,
                length: text.length - open.location - delimiterLength
            )
            guard afterOpen.length > 0 else { break }
            var close = text.range(of: delimiter, options: [], range: afterOpen)
            while close.location != NSNotFound, isClaimed(close) {
                let next = close.location + delimiterLength
                guard next < text.length else { close = NSRange(location: NSNotFound, length: 0); break }
                close = text.range(of: delimiter, options: [], range: NSRange(location: next, length: text.length - next))
            }
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
                claimed.append(open)
                claimed.append(NSRange(location: close.location, length: delimiterLength))
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
