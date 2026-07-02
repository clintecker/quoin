import Foundation
import Markdown

/// Parses markdown source into an immutable `QuoinDocument`.
///
/// Pipeline: cmark-gfm (via swift-markdown) → `Block` tree with a UTF-8
/// source map → two post-passes folded into the walk: math extraction
/// (`$…$`, `$$…$$`, and ```math fences) and mermaid fence detection.
/// Outline and statistics are computed during the same walk.
public enum MarkdownConverter {

    public static func parse(_ source: String) -> QuoinDocument {
        let document = Markdown.Document(parsing: source)
        var builder = Builder(source: source)
        let blocks = builder.convert(children: document.children)
        builder.finalizeStats()
        return QuoinDocument(
            source: source,
            blocks: blocks,
            outline: builder.outline,
            stats: builder.stats,
            sourceHash: SHA256Hex.hash(of: source)
        )
    }

    // MARK: - Builder

    private struct Builder {
        let source: String
        let sourceBytes: [UInt8]
        let lineIndex: LineIndex
        var slugger = Slugger()
        var outline: [HeadingInfo] = []
        var stats = DocumentStats()
        var occurrences: [Int: Int] = [:]
        var proseBuffer = ""

        init(source: String) {
            self.source = source
            self.sourceBytes = Array(source.utf8)
            self.lineIndex = LineIndex(source: source)
        }

        // MARK: Identity

        mutating func makeBlock(kind: BlockKind, range: ByteRange) -> Block {
            var hasher = Hasher()
            hasher.combine(kind)
            let contentHash = hasher.finalize()
            let occurrence = occurrences[contentHash, default: 0]
            occurrences[contentHash] = occurrence + 1
            return Block(id: BlockID(contentHash: contentHash, occurrence: occurrence), kind: kind, range: range)
        }

        // MARK: Block conversion

        mutating func convert(children: MarkupChildren) -> [Block] {
            var blocks: [Block] = []
            for child in children {
                blocks.append(contentsOf: convert(markup: child))
            }
            return blocks
        }

        mutating func convert(markup: Markup) -> [Block] {
            let range = lineIndex.byteRange(of: markup.range)

            switch markup {
            case let heading as Markdown.Heading:
                return [convertHeading(heading, range: range)]

            case let paragraph as Markdown.Paragraph:
                return convertParagraph(paragraph, range: range)

            case let code as Markdown.CodeBlock:
                return [convertCodeBlock(code, range: range)]

            case let table as Markdown.Table:
                return [convertTable(table, range: range)]

            case let list as Markdown.UnorderedList:
                return [convertList(items: list.children, ordered: false, start: 1, range: range)]

            case let list as Markdown.OrderedList:
                return [convertList(items: list.children, ordered: true, start: Int(list.startIndex), range: range)]

            case let quote as Markdown.BlockQuote:
                let children = convert(children: quote.children)
                return [makeBlock(kind: .blockQuote(children: children), range: range)]

            case is Markdown.ThematicBreak:
                return [makeBlock(kind: .thematicBreak, range: range)]

            case let html as Markdown.HTMLBlock:
                return [makeBlock(kind: .htmlBlock(html.rawHTML), range: range)]

            default:
                // Unknown block-level construct: preserve it as literal source
                // rather than dropping content on the floor.
                if let slice = source.substring(in: range), !slice.isEmpty {
                    return [makeBlock(kind: .paragraph(inlines: [.text(slice)]), range: range)]
                }
                return []
            }
        }

        mutating func convertHeading(_ heading: Markdown.Heading, range: ByteRange) -> Block {
            let inlines = spliceInlineMath(into: convertInlines(heading.children))
            let title = inlines.plainText.trimmingCharacters(in: .whitespaces)
            let slug = slugger.slug(for: title)
            stats.headingCount += 1
            appendProse(title)
            let block = makeBlock(kind: .heading(level: heading.level, inlines: inlines, slug: slug), range: range)
            outline.append(HeadingInfo(id: block.id, level: heading.level, title: title, slug: slug, range: range))
            return block
        }

        mutating func convertParagraph(_ paragraph: Markdown.Paragraph, range: ByteRange) -> [Block] {
            let inlines: [Inline]
            if let slice = source.substring(in: range),
               MathScanner.containsMathDelimiter(slice),
               isSafeForSliceReparse(slice) {
                // The robust path: scan the raw source slice so that cmark's
                // emphasis parsing can't mangle `$a_b + c_d$`.
                let segments = MathScanner.scan(slice)
                if segments.count == 1, case .displayMath(let latex) = segments[0] {
                    stats.mathCount += 1
                    return [makeBlock(kind: .mathBlock(latex: latex), range: range)]
                }
                inlines = assembleInlines(from: segments)
            } else {
                inlines = spliceInlineMath(into: convertInlines(paragraph.children))
            }
            appendProse(inlines.plainText)
            stats.paragraphCount += 1
            return [makeBlock(kind: .paragraph(inlines: inlines), range: range)]
        }

        /// Slice re-parsing is only safe when the paragraph's raw lines are not
        /// decorated with container prefixes (`>` continuation inside block
        /// quotes) that would re-parse as different structure.
        func isSafeForSliceReparse(_ slice: String) -> Bool {
            guard slice.contains("\n") else { return true }
            for line in slice.split(separator: "\n", omittingEmptySubsequences: false).dropFirst() {
                if line.drop(while: { $0 == " " || $0 == "\t" }).first == ">" { return false }
            }
            return true
        }

        /// Turns math-scanner segments into an inline list, re-parsing text
        /// segments as inline markdown.
        mutating func assembleInlines(from segments: [MathSegment]) -> [Inline] {
            var result: [Inline] = []
            for segment in segments {
                switch segment {
                case .inlineMath(let latex), .displayMath(let latex):
                    stats.mathCount += 1
                    result.append(.math(latex: latex))
                case .text(let text):
                    let fragment = Markdown.Document(parsing: text)
                    for child in fragment.children {
                        if let para = child as? Markdown.Paragraph {
                            result.append(contentsOf: convertInlines(para.children))
                        } else {
                            let plain = child.format()
                            if !plain.isEmpty { result.append(.text(plain)) }
                        }
                    }
                }
            }
            return result
        }

        mutating func convertCodeBlock(_ code: Markdown.CodeBlock, range: ByteRange) -> Block {
            var body = code.code
            if body.hasSuffix("\n") { body.removeLast() }
            let language = code.language?.trimmingCharacters(in: .whitespaces).lowercased()

            switch language {
            case "mermaid":
                stats.diagramCount += 1
                return makeBlock(kind: .mermaid(source: body), range: range)
            case "math", "latex", "tex":
                stats.mathCount += 1
                return makeBlock(kind: .mathBlock(latex: body), range: range)
            default:
                stats.codeBlockCount += 1
                appendProse(body)
                return makeBlock(kind: .codeBlock(language: code.language, code: body), range: range)
            }
        }

        mutating func convertTable(_ table: Markdown.Table, range: ByteRange) -> Block {
            let header = table.head.children.compactMap { $0 as? Markdown.Table.Cell }.map(convertCell)
            var rows: [[TableCell]] = []
            for row in table.body.children {
                guard let row = row as? Markdown.Table.Row else { continue }
                rows.append(row.children.compactMap { $0 as? Markdown.Table.Cell }.map(convertCell))
            }
            let alignments: [TableAlignment] = table.columnAlignments.map { alignment in
                switch alignment {
                case .left: return .left
                case .center: return .center
                case .right: return .right
                case nil: return .none
                }
            }
            stats.tableCount += 1
            return makeBlock(kind: .table(header: header, rows: rows, alignments: alignments), range: range)
        }

        mutating func convertCell(_ cell: Markdown.Table.Cell) -> TableCell {
            let inlines = spliceInlineMath(into: convertInlines(cell.children))
            appendProse(inlines.plainText)
            return TableCell(inlines: inlines)
        }

        mutating func convertList(items: MarkupChildren, ordered: Bool, start: Int, range: ByteRange) -> Block {
            var listItems: [ListItem] = []
            for item in items {
                guard let item = item as? Markdown.ListItem else { continue }
                let itemRange = lineIndex.byteRange(of: item.range)
                let blocks = convert(children: item.children)
                var task: TaskState?
                var markerRange: ByteRange?
                if let checkbox = item.checkbox {
                    task = checkbox == .checked ? .checked : .unchecked
                    markerRange = locateTaskMarker(in: itemRange)
                    stats.taskTotal += 1
                    if task == .checked { stats.taskDone += 1 }
                }
                listItems.append(ListItem(blocks: blocks, task: task, taskMarkerRange: markerRange))
            }
            return makeBlock(kind: .list(items: listItems, ordered: ordered, start: start), range: range)
        }

        /// Finds the exact byte range of the `[ ]`/`[x]` marker inside a task
        /// list item: skip the bullet or ordinal, skip whitespace, expect the
        /// three-byte marker. Returns nil if the source doesn't match, in
        /// which case write-back is refused rather than risked.
        func locateTaskMarker(in itemRange: ByteRange) -> ByteRange? {
            var i = itemRange.offset
            let end = min(itemRange.upperBound, sourceBytes.count)
            // Leading indentation.
            while i < end, sourceBytes[i] == UInt8(ascii: " ") || sourceBytes[i] == UInt8(ascii: "\t") { i += 1 }
            // Bullet (- + *) or ordinal (digits followed by . or )).
            if i < end, [UInt8(ascii: "-"), UInt8(ascii: "+"), UInt8(ascii: "*")].contains(sourceBytes[i]) {
                i += 1
            } else {
                var j = i
                while j < end, sourceBytes[j] >= UInt8(ascii: "0"), sourceBytes[j] <= UInt8(ascii: "9") { j += 1 }
                guard j > i, j < end, sourceBytes[j] == UInt8(ascii: ".") || sourceBytes[j] == UInt8(ascii: ")") else { return nil }
                i = j + 1
            }
            // Whitespace between marker and checkbox.
            while i < end, sourceBytes[i] == UInt8(ascii: " ") || sourceBytes[i] == UInt8(ascii: "\t") { i += 1 }
            // The `[x]` marker itself.
            guard i + 2 < end,
                  sourceBytes[i] == UInt8(ascii: "["),
                  sourceBytes[i + 2] == UInt8(ascii: "]"),
                  [UInt8(ascii: " "), UInt8(ascii: "x"), UInt8(ascii: "X")].contains(sourceBytes[i + 1])
            else { return nil }
            return ByteRange(offset: i, length: 3)
        }

        // MARK: Inline conversion

        mutating func convertInlines(_ children: MarkupChildren) -> [Inline] {
            var result: [Inline] = []
            for child in children {
                if let inline = convertInline(child) {
                    result.append(inline)
                }
            }
            return result
        }

        mutating func convertInline(_ markup: Markup) -> Inline? {
            switch markup {
            case let text as Markdown.Text:
                return .text(text.string)
            case let code as Markdown.InlineCode:
                return .code(code.code)
            case let emphasis as Markdown.Emphasis:
                return .emphasis(convertInlines(emphasis.children))
            case let strong as Markdown.Strong:
                return .strong(convertInlines(strong.children))
            case let strike as Markdown.Strikethrough:
                return .strikethrough(convertInlines(strike.children))
            case let link as Markdown.Link:
                stats.linkCount += 1
                return .link(destination: link.destination, children: convertInlines(link.children))
            case let image as Markdown.Image:
                stats.imageCount += 1
                let alt = image.children.compactMap { ($0 as? Markdown.Text)?.string }.joined()
                return .image(source: image.source, alt: alt)
            case is Markdown.SoftBreak:
                return .softBreak
            case is Markdown.LineBreak:
                return .lineBreak
            case let html as Markdown.InlineHTML:
                return .html(html.rawHTML)
            default:
                // Preserve anything unrecognized as its plain text.
                let text = markup.format()
                return text.isEmpty ? nil : .text(text)
            }
        }

        /// The fallback math pass for contexts that can't use slice re-parsing
        /// (headings, table cells, block-quoted paragraphs): scans individual
        /// text runs for `$…$` spans.
        mutating func spliceInlineMath(into inlines: [Inline]) -> [Inline] {
            var result: [Inline] = []
            for inline in inlines {
                guard case .text(let text) = inline, MathScanner.containsMathDelimiter(text) else {
                    result.append(inline)
                    continue
                }
                for segment in MathScanner.scan(text) {
                    switch segment {
                    case .text(let t):
                        result.append(.text(t))
                    case .inlineMath(let latex), .displayMath(let latex):
                        stats.mathCount += 1
                        result.append(.math(latex: latex))
                    }
                }
            }
            return result
        }

        // MARK: Stats

        mutating func appendProse(_ text: String) {
            guard !text.isEmpty else { return }
            proseBuffer.append(text)
            proseBuffer.append("\n")
        }

        mutating func finalizeStats() {
            stats.characterCount = source.count
            var words = 0
            proseBuffer.enumerateSubstrings(
                in: proseBuffer.startIndex..<proseBuffer.endIndex,
                options: [.byWords, .substringNotRequired]
            ) { _, _, _, _ in
                words += 1
            }
            stats.wordCount = words
        }
    }
}
