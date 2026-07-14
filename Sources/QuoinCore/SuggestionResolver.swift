import Foundation

/// Accept/reject for CriticMarkup marks (suggestions design, S2): each
/// resolution is ONE byte splice — computed from the mark's bytes AS THEY
/// ARE NOW (re-scanned from the current source, never trusted from a stale
/// projection), applied through the session's ordinary edit path so undo,
/// autosave, and stale-base protection come for free.
public enum SuggestionResolver {

    public enum Action: Sendable {
        case accept
        case reject
    }

    /// The splice that resolves the mark at `range`, or nil when the bytes
    /// there no longer parse as exactly one whole mark (the document changed
    /// since the projection was built — the caller surfaces "suggestion
    /// moved", never splices blind).
    ///
    /// Byte semantics (CriticMarkup consensus — exact bytes, no whitespace
    /// normalization; what's inside the delimiters is exactly what lands):
    /// accept insertion → body; reject → nothing; deletion inverse;
    /// substitution → chosen half; comment → removed either way (an
    /// annotation); highlight → unwrapped either way (MMD-6 behavior:
    /// the text was never in question, only flagged).
    public static func edit(
        resolving range: ByteRange, in source: String, action: Action
    ) -> SourceEdit? {
        let bytes = Array(source.utf8)
        guard range.offset >= 0, range.length > 0,
              range.offset + range.length <= bytes.count else { return nil }
        let slice = String(decoding: bytes[range.offset..<(range.offset + range.length)], as: UTF8.self)
        let segments = CriticScanner.scan(slice)
        guard segments.count == 1, case .mark(let mark) = segments[0],
              mark.range.offset == 0, mark.range.length == range.length else { return nil }

        let replacement: String
        switch (mark.payload, action) {
        case (.insertion(let body), .accept): replacement = body
        case (.insertion, .reject): replacement = ""
        case (.deletion, .accept): replacement = ""
        case (.deletion(let body), .reject): replacement = body
        case (.substitution(_, let new), .accept): replacement = new
        case (.substitution(let old, _), .reject): replacement = old
        case (.comment, _): replacement = ""
        case (.highlight(let body), _): replacement = body
        }
        return SourceEdit(range: range, replacement: replacement)
    }

    /// Every unresolved mark in the document, in source order — the walk
    /// Accept All / Reject All and the review rail share.
    public static func marks(in document: QuoinDocument) -> [(kind: SuggestionKind, range: ByteRange, id: String?)] {
        var found: [(SuggestionKind, ByteRange, String?)] = []
        func walk(_ inlines: [Inline]) {
            for inline in inlines {
                switch inline {
                case .suggestion(let kind, let range, let id):
                    found.append((kind, range, id))
                case .emphasis(let c), .strong(let c), .strikethrough(let c), .highlight(let c, _):
                    walk(c)
                case .link(_, let c):
                    walk(c)
                default:
                    break
                }
            }
        }
        func walkBlocks(_ blocks: [Block]) {
            for block in blocks {
                switch block.kind {
                case .paragraph(let inlines), .heading(_, let inlines, _):
                    walk(inlines)
                case .blockQuote(let children), .callout(_, let children):
                    walkBlocks(children)
                case .list(let items, _, _):
                    for item in items { walkBlocks(item.blocks) }
                default:
                    break
                }
            }
        }
        walkBlocks(document.blocks)
        return found.sorted { $0.1.offset < $1.1.offset }
    }
}
