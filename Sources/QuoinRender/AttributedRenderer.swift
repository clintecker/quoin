#if canImport(AppKit) || canImport(UIKit)
import Foundation
import ImageIO
import QuoinCore

#if canImport(AppKit)
import AppKit
#else
import UIKit
#endif

/// A rendered document: one attributed string for the whole document plus
/// the character range of every top-level block, which powers TOC jumps,
/// search navigation, and scroll anchoring across live reloads.
public struct RenderedDocument {
    public let attributed: NSAttributedString
    public let blockRanges: [BlockID: NSRange]
    /// When a block is active in the editor (syntax reveal), its literal
    /// source is rendered in place; this is that run's location and text.
    public let activeBlockID: BlockID?
    public let activeEditableRange: NSRange?
    public let activeSourceText: String?

    public init(
        attributed: NSAttributedString,
        blockRanges: [BlockID: NSRange],
        activeBlockID: BlockID? = nil,
        activeEditableRange: NSRange? = nil,
        activeSourceText: String? = nil
    ) {
        self.attributed = attributed
        self.blockRanges = blockRanges
        self.activeBlockID = activeBlockID
        self.activeEditableRange = activeEditableRange
        self.activeSourceText = activeSourceText
    }

    public static let empty = RenderedDocument(attributed: NSAttributedString(), blockRanges: [:])
}

/// Renders a `QuoinDocument` into attributed text for TextKit 2.
///
/// M1 scope: full native text rendering for all block types. Math and
/// mermaid render as styled source (their runs are tagged with
/// `QuoinAttribute` keys so QuoinMath/QuoinDiagram can replace them in
/// M2a/M2b without touching this pipeline). Tables use measured tab stops;
/// the richer table attachment view is a later refinement.
public struct AttributedRenderer {

    public let theme: Theme
    /// Directory of the open document, for resolving relative image paths.
    public let baseURL: URL?
    /// Remote images are opt-in per document (local-only by default).
    public let loadsRemoteImages: Bool

    public init(theme: Theme = Theme(), baseURL: URL? = nil, loadsRemoteImages: Bool = false) {
        self.theme = theme
        self.baseURL = baseURL
        self.loadsRemoteImages = loadsRemoteImages
    }

    public func render(_ document: QuoinDocument, activeBlockID: BlockID? = nil) -> RenderedDocument {
        let output = NSMutableAttributedString()
        var blockRanges: [BlockID: NSRange] = [:]
        var activeEditableRange: NSRange?
        var activeSourceText: String?

        for (index, block) in document.blocks.enumerated() {
            let start = output.length
            if block.id == activeBlockID,
               let slice = document.source.substring(in: block.range) {
                // Syntax reveal: the active block shows its literal source,
                // editable in place. Delimiters visible, subtle tint.
                let editable = renderEditableSource(slice)
                activeEditableRange = NSRange(location: start, length: editable.length)
                activeSourceText = slice
                output.append(editable)
            } else {
                output.append(render(block: block, depth: 0, document: document))
            }
            if index < document.blocks.count - 1 {
                output.append(NSAttributedString(string: "\n", attributes: bodyAttributes()))
            }
            blockRanges[block.id] = NSRange(location: start, length: output.length - start)
        }

        // Footnotes gather at document end: 12/1.6 secondary, top hairline.
        if !document.footnotes.isEmpty {
            output.append(NSAttributedString(string: "\n", attributes: bodyAttributes()))
            output.append(renderThematicBreak())
            for footnote in document.footnotes {
                output.append(NSAttributedString(string: "\n", attributes: bodyAttributes()))
                let start = output.length
                var marker = bodyAttributes()
                marker[.font] = PlatformFont.systemFont(ofSize: 12, weight: .semibold)
                marker[.foregroundColor] = theme.accent
                output.append(NSAttributedString(string: "\(footnote.index). ", attributes: marker))
                for block in footnote.blocks {
                    let body = NSMutableAttributedString(attributedString: render(block: block, depth: 0, document: document))
                    let full = NSRange(location: 0, length: body.length)
                    body.addAttribute(.font, value: PlatformFont.systemFont(ofSize: 12), range: full)
                    body.addAttribute(.foregroundColor, value: theme.secondaryTextColor, range: full)
                    output.append(body)
                }
                if let firstBlock = footnote.blocks.first {
                    blockRanges[firstBlock.id] = NSRange(location: start, length: output.length - start)
                }
            }
        }
        return RenderedDocument(
            attributed: output,
            blockRanges: blockRanges,
            activeBlockID: activeBlockID,
            activeEditableRange: activeEditableRange,
            activeSourceText: activeSourceText
        )
    }

    /// The active block's raw markdown, styled for in-place editing:
    /// content approximates its rendered look, delimiters stay visible at
    /// 35% ink mono (syntax reveal), and the character mapping stays 1:1.
    private func renderEditableSource(_ slice: String) -> NSAttributedString {
        MarkdownSourceStyler(theme: theme).style(slice)
    }

    // MARK: - Blocks

    private func render(block: Block, depth: Int, document: QuoinDocument) -> NSAttributedString {
        let content: NSAttributedString
        switch block.kind {
        case .heading(let level, let inlines, _):
            content = renderHeading(level: level, inlines: inlines)
        case .paragraph(let inlines):
            content = renderInlines(inlines, base: bodyAttributes(depth: depth))
        case .codeBlock(let language, let code):
            content = renderCodeBlock(language: language, code: code)
        case .mermaid(let source):
            content = renderMermaidFallback(source: source)
        case .mathBlock(let latex):
            content = renderMathBlockFallback(latex: latex)
        case .table(let header, let rows, let alignments):
            content = renderTable(header: header, rows: rows, alignments: alignments)
        case .list(let items, let ordered, let start):
            content = renderList(items: items, ordered: ordered, start: start, depth: depth, document: document)
        case .blockQuote(let children):
            content = renderBlockQuote(children: children, depth: depth, document: document)
        case .callout(let kind, let children):
            content = renderCallout(kind: kind, children: children, depth: depth, document: document)
        case .frontMatter(let yaml):
            content = renderFrontMatter(yaml: yaml)
        case .tableOfContents:
            content = renderTOC(outline: document.outline)
        case .thematicBreak:
            content = renderThematicBreak()
        case .htmlBlock(let html):
            content = renderCodeBlock(language: "html", code: html)
        }

        let tagged = NSMutableAttributedString(attributedString: content)
        tagged.addAttribute(
            QuoinAttribute.blockID,
            value: block.id.description,
            range: NSRange(location: 0, length: tagged.length)
        )
        return tagged
    }

    private func renderHeading(level: Int, inlines: [Inline]) -> NSAttributedString {
        var attributes = bodyAttributes()
        attributes[.font] = theme.headingFont(level: level)
        // H1–H3 in full ink; H4–H6 at 55% per the element spec.
        attributes[.foregroundColor] = level <= 3 ? theme.ink : theme.secondaryTextColor
        let style = paragraphStyle()
        let spacing = theme.headingSpacing(level: level)
        style.lineHeightMultiple = theme.headingLineHeightMultiple(level: level)
        style.paragraphSpacingBefore = spacing.above
        style.paragraphSpacing = spacing.below
        attributes[.paragraphStyle] = style
        return renderInlines(inlines, base: attributes)
    }

    private func renderCodeBlock(language: String?, code: String) -> NSAttributedString {
        // Code canvas is #1E2430 in BOTH appearances (handoff rule).
        var attributes = bodyAttributes()
        attributes[.font] = theme.codeBlockFont()
        attributes[.foregroundColor] = theme.codeText
        attributes[.backgroundColor] = theme.codeSurface
        let style = paragraphStyle()
        style.lineHeightMultiple = 1.6
        style.firstLineHeadIndent = 12
        style.headIndent = 12
        style.tailIndent = -12
        style.paragraphSpacingBefore = theme.paragraphSpacing * 0.6
        attributes[.paragraphStyle] = style
        let output = NSMutableAttributedString(string: code, attributes: attributes)

        // Native syntax highlighting: six token colors per the design spec.
        let chars = Array(code)
        for token in SyntaxHighlighter.highlight(code: code, language: language) {
            // Character indices align with UTF-16 only for BMP text; compute
            // the UTF-16 range from the character range.
            let prefix = String(chars[0..<token.range.lowerBound]).utf16.count
            let length = String(chars[token.range.lowerBound..<min(token.range.upperBound, chars.count)]).utf16.count
            let nsRange = NSRange(location: prefix, length: length)
            guard nsRange.location + nsRange.length <= output.length else { continue }
            let color: PlatformColor
            switch token.kind {
            case .keyword: color = Theme.CodeToken.keyword
            case .function: color = Theme.CodeToken.function
            case .type: color = Theme.CodeToken.type
            case .comment: color = Theme.CodeToken.comment
            case .string: color = Theme.CodeToken.string
            case .number: color = Theme.CodeToken.number
            }
            output.addAttribute(.foregroundColor, value: color, range: nsRange)
        }
        return output
    }

    private func renderFrontMatter(yaml: String) -> NSAttributedString {
        // Compact metadata chip above the H1; click-to-edit arrives with the
        // editor. Rendered as caption-size key/value lines.
        var attributes = bodyAttributes()
        attributes[.font] = theme.captionFont()
        attributes[.foregroundColor] = theme.secondaryTextColor
        attributes[.backgroundColor] = theme.inlineCodeFill
        let style = paragraphStyle()
        style.lineHeightMultiple = 1.4
        // One visual chip: no spacing between the YAML lines.
        style.paragraphSpacing = 0
        style.paragraphSpacingBefore = 0
        style.firstLineHeadIndent = 8
        style.headIndent = 8
        style.tailIndent = -8
        attributes[.paragraphStyle] = style
        return NSAttributedString(string: yaml, attributes: attributes)
    }

    private func renderCallout(kind: CalloutKind, children: [Block], depth: Int, document: QuoinDocument) -> NSAttributedString {
        let semantic: PlatformColor
        let symbol: String
        switch kind {
        case .note: semantic = .systemBlue; symbol = "ℹ︎"
        case .tip: semantic = .systemGreen; symbol = "✓"
        case .warning: semantic = .systemOrange; symbol = "⚠︎"
        case .danger: semantic = .systemRed; symbol = "✕"
        }

        let output = NSMutableAttributedString()
        var title = bodyAttributes()
        title[.font] = PlatformFont.systemFont(ofSize: 12.5, weight: .semibold)
        title[.foregroundColor] = semantic
        output.append(NSAttributedString(string: "\(symbol) \(kind.title)\n", attributes: title))

        for (index, child) in children.enumerated() {
            if index > 0 {
                output.append(NSAttributedString(string: "\n", attributes: bodyAttributes()))
            }
            output.append(render(block: child, depth: depth + 1, document: document))
        }
        // 4% tint background across the callout (border/radius arrive with
        // the block decoration pass).
        let full = NSRange(location: 0, length: output.length)
        output.addAttribute(.backgroundColor, value: semantic.withAlphaComponent(0.06), range: full)
        output.enumerateAttribute(.paragraphStyle, in: full) { value, range, _ in
            let style = (value as? NSParagraphStyle)?.mutableCopy() as? NSMutableParagraphStyle ?? paragraphStyle()
            style.firstLineHeadIndent += 12
            style.headIndent += 12
            style.tailIndent = -12
            output.addAttribute(.paragraphStyle, value: style, range: range)
        }
        return output
    }

    private func renderTOC(outline: [HeadingInfo]) -> NSAttributedString {
        let output = NSMutableAttributedString()
        for (index, heading) in outline.enumerated() {
            var attributes = bodyAttributes()
            attributes[.foregroundColor] = theme.linkColor
            attributes[.link] = QuoinLink.anchorURL(slug: heading.slug) as Any
            let style = paragraphStyle()
            style.paragraphSpacing = 2
            style.firstLineHeadIndent = CGFloat(max(0, heading.level - 1)) * 16
            style.headIndent = style.firstLineHeadIndent
            attributes[.paragraphStyle] = style
            output.append(NSAttributedString(
                string: heading.title + (index < outline.count - 1 ? "\n" : ""),
                attributes: attributes
            ))
        }
        return output
    }

    private func renderMermaidFallback(source: String) -> NSAttributedString {
        // Native rendering for supported diagram types (flowchart, sequence,
        // pie); everything else keeps the styled-source fallback.
        if let native = DiagramRenderer.attachmentString(source: source, theme: theme) {
            let output = NSMutableAttributedString(attributedString: native)
            let style = paragraphStyle()
            style.paragraphSpacingBefore = theme.paragraphSpacing
            style.paragraphSpacing = theme.paragraphSpacing
            output.addAttributes([
                .paragraphStyle: style,
                QuoinAttribute.diagramSource: source,
            ], range: NSRange(location: 0, length: output.length))
            return output
        }

        let output = NSMutableAttributedString(attributedString: renderCodeBlock(language: "mermaid", code: source))
        output.addAttribute(QuoinAttribute.diagramSource, value: source, range: NSRange(location: 0, length: output.length))

        var caption = bodyAttributes()
        caption[.font] = theme.captionFont()
        caption[.foregroundColor] = theme.secondaryTextColor
        output.append(NSAttributedString(string: "\nmermaid · this diagram type isn't natively rendered yet", attributes: caption))
        return output
    }

    private func renderMathBlockFallback(latex: String) -> NSAttributedString {
        // Display math: natively typeset, centered, 16pt above/below per the
        // element spec. Unsupported LaTeX keeps the styled-source fallback.
        if let native = MathImageRenderer.attachmentString(
            latex: latex, display: true, theme: theme, baseSize: theme.bodySize
        ) {
            let output = NSMutableAttributedString(attributedString: native)
            let style = paragraphStyle()
            style.alignment = .center
            style.paragraphSpacingBefore = 16
            style.paragraphSpacing = 16
            output.addAttributes([
                .paragraphStyle: style,
                QuoinAttribute.mathSource: latex,
            ], range: NSRange(location: 0, length: output.length))
            return output
        }

        var attributes = bodyAttributes()
        attributes[.font] = theme.codeBlockFont()
        attributes[.foregroundColor] = theme.secondaryTextColor
        let style = paragraphStyle()
        style.alignment = .center
        style.paragraphSpacingBefore = theme.paragraphSpacing
        attributes[.paragraphStyle] = style
        attributes[QuoinAttribute.mathSource] = latex
        return NSAttributedString(string: latex, attributes: attributes)
    }

    private func renderTable(header: [TableCell], rows: [[TableCell]], alignments: [TableAlignment]) -> NSAttributedString {
        // M1 table rendering: measured tab stops. Column widths come from the
        // widest cell, capped so a runaway column can't eat the page.
        let columnCount = max(header.count, rows.map(\.count).max() ?? 0)
        guard columnCount > 0 else { return NSAttributedString() }

        let bodyFont = theme.bodyFont()
        let headerFont = boldVariant(of: bodyFont)
        let columnGap: CGFloat = 24
        let maxColumnWidth = theme.maxContentWidth / 2

        var widths = [CGFloat](repeating: 0, count: columnCount)
        func measure(_ cells: [TableCell], font: PlatformFont) {
            for (i, cell) in cells.enumerated() where i < columnCount {
                let text = cell.inlines.plainText
                let width = (text as NSString).size(withAttributes: [.font: font]).width
                widths[i] = min(max(widths[i], width), maxColumnWidth)
            }
        }
        measure(header, font: headerFont)
        for row in rows { measure(row, font: bodyFont) }

        var tabStops: [NSTextTab] = []
        var x: CGFloat = 0
        for width in widths {
            x += width + columnGap
            tabStops.append(NSTextTab(textAlignment: .left, location: x))
        }

        let style = paragraphStyle()
        style.tabStops = tabStops
        style.lineHeightMultiple = 1.2
        style.paragraphSpacing = 2

        func renderRow(_ cells: [TableCell], font: PlatformFont, color: PlatformColor) -> NSAttributedString {
            let row = NSMutableAttributedString()
            var attributes = bodyAttributes()
            attributes[.font] = font
            attributes[.foregroundColor] = color
            attributes[.paragraphStyle] = style
            for (i, cell) in cells.enumerated() {
                row.append(renderInlines(cell.inlines, base: attributes))
                if i < cells.count - 1 {
                    row.append(NSAttributedString(string: "\t", attributes: attributes))
                }
            }
            return row
        }

        let output = NSMutableAttributedString()
        output.append(renderRow(header, font: headerFont, color: theme.textColor))
        for row in rows {
            output.append(NSAttributedString(string: "\n", attributes: bodyAttributes()))
            output.append(renderRow(row, font: bodyFont, color: theme.textColor))
        }
        return output
    }

    private func renderList(items: [QuoinCore.ListItem], ordered: Bool, start: Int, depth: Int, document: QuoinDocument) -> NSAttributedString {
        let output = NSMutableAttributedString()
        for (index, item) in items.enumerated() {
            if index > 0 {
                output.append(NSAttributedString(string: "\n", attributes: bodyAttributes(depth: depth)))
            }
            output.append(renderListItem(item, ordinal: ordered ? start + index : nil, depth: depth, document: document))
        }
        return output
    }

    private func renderListItem(_ item: QuoinCore.ListItem, ordinal: Int?, depth: Int, document: QuoinDocument) -> NSAttributedString {
        let indent = CGFloat(depth + 1) * 22
        let style = paragraphStyle()
        style.firstLineHeadIndent = indent - 22
        style.headIndent = indent
        style.paragraphSpacing = theme.paragraphSpacing * 0.35

        var markerAttributes = bodyAttributes()
        markerAttributes[.paragraphStyle] = style

        let output = NSMutableAttributedString()

        // The marker: checkbox, ordinal, or bullet.
        if let task = item.task {
            var checkbox = markerAttributes
            checkbox[.foregroundColor] = theme.linkColor
            if let offset = item.taskMarkerRange?.offset, let url = QuoinLink.taskURL(markerOffset: offset) {
                checkbox[.link] = url
                checkbox[QuoinAttribute.taskMarkerOffset] = NSNumber(value: offset)
            }
            let glyph = task == .checked ? "☑" : "☐"
            output.append(NSAttributedString(string: glyph + "  ", attributes: checkbox))
        } else if let ordinal {
            output.append(NSAttributedString(string: "\(ordinal).  ", attributes: markerAttributes))
        } else {
            output.append(NSAttributedString(string: "•  ", attributes: markerAttributes))
        }

        // Item content: first paragraph flows inline after the marker, any
        // further blocks (nested lists, paragraphs) follow on their own lines.
        for (blockIndex, block) in item.blocks.enumerated() {
            if blockIndex > 0 {
                output.append(NSAttributedString(string: "\n", attributes: markerAttributes))
            }
            switch block.kind {
            case .paragraph(let inlines):
                var attributes = bodyAttributes()
                attributes[.paragraphStyle] = style
                if item.task == .checked {
                    // Done rows strike and fade to 40% per the element spec.
                    attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
                    attributes[.foregroundColor] = theme.ink.withAlphaComponent(0.4)
                    attributes[.strikethroughColor] = theme.ink.withAlphaComponent(0.4)
                }
                output.append(renderInlines(inlines, base: attributes))
            case .list(let nested, let nestedOrdered, let nestedStart):
                output.append(renderList(items: nested, ordered: nestedOrdered, start: nestedStart, depth: depth + 1, document: document))
            default:
                output.append(render(block: block, depth: depth + 1, document: document))
            }
        }
        return output
    }

    private func renderBlockQuote(children: [Block], depth: Int, document: QuoinDocument) -> NSAttributedString {
        let output = NSMutableAttributedString()
        for (index, child) in children.enumerated() {
            if index > 0 {
                output.append(NSAttributedString(string: "\n", attributes: bodyAttributes()))
            }
            output.append(render(block: child, depth: depth + 1, document: document))
        }
        let full = NSRange(location: 0, length: output.length)
        output.enumerateAttribute(.paragraphStyle, in: full) { value, range, _ in
            let style = (value as? NSParagraphStyle)?.mutableCopy() as? NSMutableParagraphStyle ?? paragraphStyle()
            style.firstLineHeadIndent += 16
            style.headIndent += 16
            output.addAttribute(.paragraphStyle, value: style, range: range)
        }
        // Element spec: pad-left 16, italic, 55% ink. (The 3pt vertical rule
        // needs custom drawing — arrives with the block decoration pass.)
        output.enumerateAttribute(.font, in: full) { value, range, _ in
            let font = value as? PlatformFont ?? theme.bodyFont()
            output.addAttribute(.font, value: italicVariant(of: font), range: range)
        }
        output.addAttribute(.foregroundColor, value: theme.secondaryTextColor, range: full)
        return output
    }

    private func renderThematicBreak() -> NSAttributedString {
        // 1px hairline @12% ink, 20 above/below. Drawn as a line of box
        // glyphs until the block decoration pass draws a true rule.
        var attributes = bodyAttributes()
        attributes[.foregroundColor] = theme.hairline
        attributes[.font] = PlatformFont.systemFont(ofSize: 8)
        let style = paragraphStyle()
        style.alignment = .center
        style.paragraphSpacingBefore = 20
        style.paragraphSpacing = 20
        attributes[.paragraphStyle] = style
        return NSAttributedString(string: String(repeating: "─", count: 60), attributes: attributes)
    }

    // MARK: - Inlines

    private func renderInlines(_ inlines: [Inline], base: [NSAttributedString.Key: Any]) -> NSAttributedString {
        let output = NSMutableAttributedString()
        for inline in inlines {
            output.append(renderInline(inline, attributes: base))
        }
        return output
    }

    private func renderInline(_ inline: Inline, attributes: [NSAttributedString.Key: Any]) -> NSAttributedString {
        switch inline {
        case .text(let text):
            return NSAttributedString(string: text, attributes: attributes)

        case .code(let code):
            var attrs = attributes
            attrs[.font] = theme.inlineCodeFont()
            attrs[.backgroundColor] = theme.inlineCodeFill
            return NSAttributedString(string: code, attributes: attrs)

        case .emphasis(let children):
            var attrs = attributes
            attrs[.font] = italicVariant(of: attrs[.font] as? PlatformFont ?? theme.bodyFont())
            return renderInlines(children, base: attrs)

        case .strong(let children):
            // Bold text is full ink (#1D1D1F) per the element spec.
            var attrs = attributes
            attrs[.font] = boldVariant(of: attrs[.font] as? PlatformFont ?? theme.bodyFont())
            attrs[.foregroundColor] = theme.ink
            return renderInlines(children, base: attrs)

        case .strikethrough(let children):
            // 45% ink per the element spec.
            var attrs = attributes
            attrs[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
            attrs[.foregroundColor] = theme.ink.withAlphaComponent(0.45)
            return renderInlines(children, base: attrs)

        case .link(let destination, let children):
            // Accent text with a 35%-alpha accent underline.
            var attrs = attributes
            attrs[.foregroundColor] = theme.linkColor
            attrs[.underlineStyle] = NSUnderlineStyle.single.rawValue
            attrs[.underlineColor] = theme.linkColor.withAlphaComponent(0.35)
            if let destination {
                if destination.hasPrefix("#") {
                    attrs[.link] = QuoinLink.anchorURL(slug: String(destination.dropFirst())) as Any
                } else if let url = URL(string: destination) {
                    attrs[.link] = url
                }
            }
            return renderInlines(children, base: attrs)

        case .image(let source, let alt):
            return renderImage(source: source, alt: alt, attributes: attributes)

        case .math(let latex):
            // Natively typeset inline math, baseline-aligned with the text;
            // unsupported LaTeX degrades to marked styled source (PRD rule).
            if let native = MathImageRenderer.attachmentString(
                latex: latex, display: false, theme: theme, baseSize: theme.bodySize
            ) {
                let output = NSMutableAttributedString(attributedString: native)
                var carried = attributes
                carried[QuoinAttribute.mathSource] = latex
                carried.removeValue(forKey: .font)
                output.addAttributes(carried, range: NSRange(location: 0, length: output.length))
                return output
            }
            var attrs = attributes
            attrs[.font] = theme.inlineCodeFont()
            attrs[.foregroundColor] = theme.secondaryTextColor
            attrs[QuoinAttribute.mathSource] = latex
            return NSAttributedString(string: latex, attributes: attrs)

        case .highlight(let children):
            // Pill highlight, lime by default (radius arrives with the
            // block decoration pass; background carries the color now).
            var attrs = attributes
            attrs[.backgroundColor] = Theme.Highlight.lime.color
            attrs[.foregroundColor] = theme.textColor
            return renderInlines(children, base: attrs)

        case .footnoteReference(_, let index):
            // Superscript accent marker; bidirectional jump lands in Phase C.
            var attrs = attributes
            attrs[.font] = PlatformFont.systemFont(ofSize: theme.bodySize * 0.75)
            attrs[.foregroundColor] = theme.accent
            attrs[.baselineOffset] = theme.bodySize * 0.33
            return NSAttributedString(string: "\(index)", attributes: attrs)

        case .softBreak:
            return NSAttributedString(string: " ", attributes: attributes)

        case .lineBreak:
            return NSAttributedString(string: "\n", attributes: attributes)

        case .html(let raw):
            var attrs = attributes
            attrs[.font] = theme.inlineCodeFont()
            attrs[.foregroundColor] = theme.secondaryTextColor
            return NSAttributedString(string: raw, attributes: attrs)
        }
    }

    // MARK: - Images

    private func renderImage(source: String?, alt: String, attributes: [NSAttributedString.Key: Any]) -> NSAttributedString {
        func placeholder(_ label: String) -> NSAttributedString {
            var attrs = attributes
            attrs[.font] = theme.inlineCodeFont()
            attrs[.foregroundColor] = theme.secondaryTextColor
            attrs[.backgroundColor] = theme.inlineCodeFill
            return NSAttributedString(string: " ▢ \(label) ", attributes: attrs)
        }

        guard let source, !source.isEmpty else { return placeholder(alt.isEmpty ? "image" : alt) }

        if source.hasPrefix("http://") || source.hasPrefix("https://") {
            // Local-only policy: remote images are placeholders unless the
            // user opts in for this document (opt-in fetch arrives with the
            // async image pipeline in M2a).
            return placeholder("remote image: \(source)")
        }

        let fileURL: URL
        if source.hasPrefix("/") {
            fileURL = URL(fileURLWithPath: source)
        } else if let baseURL {
            fileURL = baseURL.appendingPathComponent(source).standardizedFileURL
        } else {
            return placeholder(alt.isEmpty ? source : alt)
        }

        guard let image = downsampledImage(at: fileURL, maxDimension: theme.maxContentWidth * 2) else {
            return placeholder("missing image: \(source)")
        }

        let attachment = NSTextAttachment()
        let scale = min(1, theme.maxContentWidth / max(image.size.width, 1))
        attachment.image = image
        attachment.bounds = CGRect(
            x: 0, y: 0,
            width: image.size.width * scale,
            height: image.size.height * scale
        )
        let output = NSMutableAttributedString(attachment: attachment)
        output.addAttributes(attributes, range: NSRange(location: 0, length: output.length))
        return output
    }

    /// Decodes at display size via ImageIO so a 20 MP photo doesn't cost
    /// 80 MB of memory to show at 680 points wide.
    private func downsampledImage(at url: URL, maxDimension: CGFloat) -> PlatformImage? {
        let options: [CFString: Any] = [kCGImageSourceShouldCache: false]
        guard let source = CGImageSourceCreateWithURL(url as CFURL, options as CFDictionary) else { return nil }
        let thumbnailOptions: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: Int(maxDimension),
            kCGImageSourceShouldCacheImmediately: true,
        ]
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbnailOptions as CFDictionary) else { return nil }
        #if canImport(AppKit)
        return NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
        #else
        return UIImage(cgImage: cgImage)
        #endif
    }

    // MARK: - Attribute helpers

    private func bodyAttributes(depth: Int = 0) -> [NSAttributedString.Key: Any] {
        [
            .font: theme.bodyFont(),
            .foregroundColor: theme.textColor,
            .paragraphStyle: paragraphStyle(),
        ]
    }

    private func paragraphStyle() -> NSMutableParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.lineHeightMultiple = theme.bodyLineHeightMultiple
        style.paragraphSpacing = theme.paragraphSpacing
        return style
    }

    private func boldVariant(of font: PlatformFont) -> PlatformFont {
        #if canImport(AppKit)
        return NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask)
        #else
        guard let descriptor = font.fontDescriptor.withSymbolicTraits(
            font.fontDescriptor.symbolicTraits.union(.traitBold)
        ) else { return font }
        return UIFont(descriptor: descriptor, size: font.pointSize)
        #endif
    }

    private func italicVariant(of font: PlatformFont) -> PlatformFont {
        #if canImport(AppKit)
        return NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask)
        #else
        guard let descriptor = font.fontDescriptor.withSymbolicTraits(
            font.fontDescriptor.symbolicTraits.union(.traitItalic)
        ) else { return font }
        return UIFont(descriptor: descriptor, size: font.pointSize)
        #endif
    }
}

#if canImport(AppKit)
public typealias PlatformImage = NSImage
#else
public typealias PlatformImage = UIImage
#endif
#endif
