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

    public func render(_ document: QuoinDocument) -> RenderedDocument {
        let output = NSMutableAttributedString()
        var blockRanges: [BlockID: NSRange] = [:]

        for (index, block) in document.blocks.enumerated() {
            let start = output.length
            output.append(render(block: block, depth: 0))
            if index < document.blocks.count - 1 {
                output.append(NSAttributedString(string: "\n", attributes: bodyAttributes()))
            }
            blockRanges[block.id] = NSRange(location: start, length: output.length - start)
        }
        return RenderedDocument(attributed: output, blockRanges: blockRanges)
    }

    // MARK: - Blocks

    private func render(block: Block, depth: Int) -> NSAttributedString {
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
            content = renderList(items: items, ordered: ordered, start: start, depth: depth)
        case .blockQuote(let children):
            content = renderBlockQuote(children: children, depth: depth)
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
        let style = paragraphStyle()
        style.paragraphSpacingBefore = theme.paragraphSpacing * (level <= 2 ? 1.6 : 1.2)
        style.paragraphSpacing = theme.paragraphSpacing * 0.6
        attributes[.paragraphStyle] = style
        return renderInlines(inlines, base: attributes)
    }

    private func renderCodeBlock(language: String?, code: String) -> NSAttributedString {
        var attributes = bodyAttributes()
        attributes[.font] = theme.codeFont()
        attributes[.backgroundColor] = theme.codeBackground
        let style = paragraphStyle()
        style.firstLineHeadIndent = 12
        style.headIndent = 12
        style.tailIndent = -12
        style.paragraphSpacingBefore = theme.paragraphSpacing * 0.6
        attributes[.paragraphStyle] = style
        return NSAttributedString(string: code, attributes: attributes)
    }

    private func renderMermaidFallback(source: String) -> NSAttributedString {
        // Styled-source fallback until QuoinDiagram lands (M2b). The run is
        // tagged so the diagram engine can replace it in place.
        let output = NSMutableAttributedString(attributedString: renderCodeBlock(language: "mermaid", code: source))
        output.addAttribute(QuoinAttribute.diagramSource, value: source, range: NSRange(location: 0, length: output.length))

        var caption = bodyAttributes()
        caption[.font] = theme.codeFont()
        caption[.foregroundColor] = theme.secondaryTextColor
        output.append(NSAttributedString(string: "\nmermaid · native diagram rendering coming in a future update", attributes: caption))
        return output
    }

    private func renderMathBlockFallback(latex: String) -> NSAttributedString {
        var attributes = bodyAttributes()
        attributes[.font] = theme.codeFont()
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

    private func renderList(items: [QuoinCore.ListItem], ordered: Bool, start: Int, depth: Int) -> NSAttributedString {
        let output = NSMutableAttributedString()
        for (index, item) in items.enumerated() {
            if index > 0 {
                output.append(NSAttributedString(string: "\n", attributes: bodyAttributes(depth: depth)))
            }
            output.append(renderListItem(item, ordinal: ordered ? start + index : nil, depth: depth))
        }
        return output
    }

    private func renderListItem(_ item: QuoinCore.ListItem, ordinal: Int?, depth: Int) -> NSAttributedString {
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
                var strike = attributes
                if item.task == .checked {
                    strike[.foregroundColor] = theme.secondaryTextColor
                }
                output.append(renderInlines(inlines, base: item.task == .checked ? strike : attributes))
            case .list(let nested, let nestedOrdered, let nestedStart):
                output.append(renderList(items: nested, ordered: nestedOrdered, start: nestedStart, depth: depth + 1))
            default:
                output.append(render(block: block, depth: depth + 1))
            }
        }
        return output
    }

    private func renderBlockQuote(children: [Block], depth: Int) -> NSAttributedString {
        let output = NSMutableAttributedString()
        for (index, child) in children.enumerated() {
            if index > 0 {
                output.append(NSAttributedString(string: "\n", attributes: bodyAttributes()))
            }
            output.append(render(block: child, depth: depth + 1))
        }
        let full = NSRange(location: 0, length: output.length)
        output.enumerateAttribute(.paragraphStyle, in: full) { value, range, _ in
            let style = (value as? NSParagraphStyle)?.mutableCopy() as? NSMutableParagraphStyle ?? paragraphStyle()
            style.firstLineHeadIndent += 16
            style.headIndent += 16
            output.addAttribute(.paragraphStyle, value: style, range: range)
        }
        output.addAttribute(.foregroundColor, value: theme.secondaryTextColor, range: full)
        return output
    }

    private func renderThematicBreak() -> NSAttributedString {
        var attributes = bodyAttributes()
        attributes[.foregroundColor] = theme.secondaryTextColor
        let style = paragraphStyle()
        style.alignment = .center
        style.paragraphSpacingBefore = theme.paragraphSpacing
        attributes[.paragraphStyle] = style
        return NSAttributedString(string: "· · ·", attributes: attributes)
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
            attrs[.font] = theme.codeFont()
            attrs[.backgroundColor] = theme.codeBackground
            return NSAttributedString(string: code, attributes: attrs)

        case .emphasis(let children):
            var attrs = attributes
            attrs[.font] = italicVariant(of: attrs[.font] as? PlatformFont ?? theme.bodyFont())
            return renderInlines(children, base: attrs)

        case .strong(let children):
            var attrs = attributes
            attrs[.font] = boldVariant(of: attrs[.font] as? PlatformFont ?? theme.bodyFont())
            return renderInlines(children, base: attrs)

        case .strikethrough(let children):
            var attrs = attributes
            attrs[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
            attrs[.foregroundColor] = theme.secondaryTextColor
            return renderInlines(children, base: attrs)

        case .link(let destination, let children):
            var attrs = attributes
            attrs[.foregroundColor] = theme.linkColor
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
            // Styled-source fallback until QuoinMath lands (M2a); the run is
            // tagged for in-place replacement.
            var attrs = attributes
            attrs[.font] = theme.codeFont()
            attrs[.foregroundColor] = theme.secondaryTextColor
            attrs[QuoinAttribute.mathSource] = latex
            return NSAttributedString(string: latex, attributes: attrs)

        case .softBreak:
            return NSAttributedString(string: " ", attributes: attributes)

        case .lineBreak:
            return NSAttributedString(string: "\n", attributes: attributes)

        case .html(let raw):
            var attrs = attributes
            attrs[.font] = theme.codeFont()
            attrs[.foregroundColor] = theme.secondaryTextColor
            return NSAttributedString(string: raw, attributes: attrs)
        }
    }

    // MARK: - Images

    private func renderImage(source: String?, alt: String, attributes: [NSAttributedString.Key: Any]) -> NSAttributedString {
        func placeholder(_ label: String) -> NSAttributedString {
            var attrs = attributes
            attrs[.font] = theme.codeFont()
            attrs[.foregroundColor] = theme.secondaryTextColor
            attrs[.backgroundColor] = theme.codeBackground
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
        style.lineHeightMultiple = theme.lineHeightMultiple
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
