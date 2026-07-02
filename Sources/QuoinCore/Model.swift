import Foundation

// MARK: - Inline content

public indirect enum Inline: Hashable, Sendable {
    case text(String)
    case code(String)
    case emphasis([Inline])
    case strong([Inline])
    case strikethrough([Inline])
    case link(destination: String?, children: [Inline])
    case image(source: String?, alt: String)
    /// Inline math extracted from `$…$` spans.
    case math(latex: String)
    /// `==highlighted==` text, rendered as a pill in the current highlight color.
    case highlight([Inline])
    /// A `[^id]` footnote reference; `index` is its 1-based document ordinal.
    case footnoteReference(id: String, index: Int)
    case softBreak
    case lineBreak
    case html(String)

    /// Plain-text projection, used for search, stats, TOC labels and TXT export.
    public var plainText: String {
        switch self {
        case .text(let s): return s
        case .code(let s): return s
        case .emphasis(let c), .strong(let c), .strikethrough(let c), .highlight(let c):
            return c.map(\.plainText).joined()
        case .link(_, let c): return c.map(\.plainText).joined()
        case .image(_, let alt): return alt
        case .math(let latex): return latex
        case .footnoteReference(_, let index): return "[\(index)]"
        case .softBreak: return " "
        case .lineBreak: return "\n"
        case .html: return ""
        }
    }
}

extension Array where Element == Inline {
    public var plainText: String { map(\.plainText).joined() }
}

// MARK: - Blocks

public enum TaskState: Hashable, Sendable {
    case checked
    case unchecked

    public var toggled: TaskState { self == .checked ? .unchecked : .checked }
}

public struct ListItem: Hashable, Sendable {
    public let blocks: [Block]
    public let task: TaskState?
    /// Byte range of the `[ ]` / `[x]` marker in the source, when this is a task item.
    public let taskMarkerRange: ByteRange?

    public init(blocks: [Block], task: TaskState? = nil, taskMarkerRange: ByteRange? = nil) {
        self.blocks = blocks
        self.task = task
        self.taskMarkerRange = taskMarkerRange
    }
}

public enum TableAlignment: Hashable, Sendable {
    case left, center, right, none
}

public struct TableCell: Hashable, Sendable {
    public let inlines: [Inline]
    public init(inlines: [Inline]) { self.inlines = inlines }
}

/// Callout kinds per the design handoff: `> [!NOTE|TIP|WARNING|DANGER]`.
/// GitHub's IMPORTANT/CAUTION map onto note/danger.
public enum CalloutKind: String, Hashable, Sendable, CaseIterable {
    case note, tip, warning, danger

    public init?(marker: String) {
        switch marker.uppercased() {
        case "NOTE", "INFO", "IMPORTANT": self = .note
        case "TIP", "HINT": self = .tip
        case "WARNING", "CAUTION": self = .warning
        case "DANGER", "ERROR": self = .danger
        default: return nil
        }
    }

    public var title: String { rawValue.capitalized }
}

/// A gathered footnote: definition blocks keyed by id, numbered in order
/// of first reference.
public struct Footnote: Hashable, Sendable, Identifiable {
    public let id: String
    public let index: Int
    public let blocks: [Block]

    public init(id: String, index: Int, blocks: [Block]) {
        self.id = id
        self.index = index
        self.blocks = blocks
    }
}

public indirect enum BlockKind: Hashable, Sendable {
    case heading(level: Int, inlines: [Inline], slug: String)
    case paragraph(inlines: [Inline])
    case codeBlock(language: String?, code: String)
    /// A ```mermaid fenced block, recognized for the native diagram engine.
    case mermaid(source: String)
    /// Display math from `$$ … $$`.
    case mathBlock(latex: String)
    case table(header: [TableCell], rows: [[TableCell]], alignments: [TableAlignment])
    case list(items: [ListItem], ordered: Bool, start: Int)
    case blockQuote(children: [Block])
    /// A design-spec callout: `> [!NOTE] …`.
    case callout(kind: CalloutKind, children: [Block])
    /// Leading YAML front matter, rendered as a compact metadata chip.
    case frontMatter(yaml: String)
    /// A `[TOC]` block — renders the linked heading outline inline.
    case tableOfContents
    case thematicBreak
    /// Raw HTML blocks are shown as literal styled source in v1.
    case htmlBlock(String)
}

/// Identifies a block stably across re-parses: content hash plus the
/// occurrence index among blocks with the same hash. Unchanged blocks keep
/// their identity when the document reloads, which is what lets the renderer
/// patch instead of rebuild and keeps scroll anchored.
public struct BlockID: Hashable, Sendable, CustomStringConvertible {
    public let contentHash: Int
    public let occurrence: Int

    public init(contentHash: Int, occurrence: Int) {
        self.contentHash = contentHash
        self.occurrence = occurrence
    }

    public var description: String { "\(contentHash):\(occurrence)" }
}

public struct Block: Identifiable, Hashable, Sendable {
    public let id: BlockID
    public let kind: BlockKind
    public let range: ByteRange

    public init(id: BlockID, kind: BlockKind, range: ByteRange) {
        self.id = id
        self.kind = kind
        self.range = range
    }
}

// MARK: - Outline & stats

public struct HeadingInfo: Hashable, Sendable, Identifiable {
    public let id: BlockID
    public let level: Int
    public let title: String
    public let slug: String
    public let range: ByteRange

    public init(id: BlockID, level: Int, title: String, slug: String, range: ByteRange) {
        self.id = id
        self.level = level
        self.title = title
        self.slug = slug
        self.range = range
    }
}

public struct DocumentStats: Hashable, Sendable {
    public var wordCount = 0
    public var characterCount = 0
    public var headingCount = 0
    public var paragraphCount = 0
    public var linkCount = 0
    public var imageCount = 0
    public var codeBlockCount = 0
    public var tableCount = 0
    public var mathCount = 0
    public var diagramCount = 0
    public var taskTotal = 0
    public var taskDone = 0
    public var footnoteCount = 0
    public var highlightCount = 0

    public init() {}

    /// Reading time at 230 words per minute, never reported as zero.
    public var readingTimeMinutes: Int {
        max(1, Int((Double(wordCount) / 230.0).rounded()))
    }
}

// MARK: - Document

/// An immutable snapshot of a parsed markdown document. Produced by
/// `MarkdownConverter`, owned and republished by `DocumentSession`.
public struct QuoinDocument: Sendable {
    public let source: String
    public let blocks: [Block]
    public let outline: [HeadingInfo]
    /// Footnotes gathered from `[^id]:` definitions, in reference order.
    /// Their definition blocks are removed from `blocks`; the renderer
    /// appends them at document end per the element spec.
    public let footnotes: [Footnote]
    public let stats: DocumentStats
    /// SHA-256 of the source, used to recognize self-inflicted file events.
    public let sourceHash: String

    public init(
        source: String,
        blocks: [Block],
        outline: [HeadingInfo],
        footnotes: [Footnote] = [],
        stats: DocumentStats,
        sourceHash: String
    ) {
        self.source = source
        self.blocks = blocks
        self.outline = outline
        self.footnotes = footnotes
        self.stats = stats
        self.sourceHash = sourceHash
    }

    public static let empty = QuoinDocument(source: "", blocks: [], outline: [], stats: DocumentStats(), sourceHash: "")

    /// Depth-first search for a block by identity, descending into
    /// block quotes and list items.
    public func block(withID id: BlockID) -> Block? {
        func find(in blocks: [Block]) -> Block? {
            for block in blocks {
                if block.id == id { return block }
                switch block.kind {
                case .blockQuote(let children), .callout(_, let children):
                    if let hit = find(in: children) { return hit }
                case .list(let items, _, _):
                    for item in items {
                        if let hit = find(in: item.blocks) { return hit }
                    }
                default:
                    break
                }
            }
            return nil
        }
        return find(in: blocks)
    }
}
