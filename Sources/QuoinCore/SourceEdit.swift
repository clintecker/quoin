import Foundation

/// A single mutation of the source text: replace the bytes in `range` with
/// `replacement`. This is the universal edit currency — keystrokes from the
/// editor, checkbox toggles, and programmatic format commands all reduce
/// to source edits applied through `DocumentSession`.
public struct SourceEdit: Hashable, Sendable {
    public let range: ByteRange
    public let replacement: String

    public init(range: ByteRange, replacement: String) {
        self.range = range
        self.replacement = replacement
    }

    public enum EditError: Error, Equatable {
        case rangeOutOfBounds
        case rangeNotOnCharacterBoundary
    }

    /// Applies the edit, returning the new source and the inverse edit
    /// (for undo). Byte-precise: everything outside `range` is untouched.
    ///
    /// This runs on every keystroke, so it must not materialize the whole
    /// source as byte arrays (the original implementation copied the
    /// document ~5×, which alone cost hundreds of milliseconds per keystroke
    /// in a novel-length file). Scalar-boundary safety is checked directly:
    /// an edit splits a UTF-8 scalar exactly when a range endpoint lands on
    /// a continuation byte (0b10xxxxxx). `replacement` is a Swift String and
    /// therefore always valid UTF-8 on its own.
    public func apply(to source: String) throws -> (result: String, inverse: SourceEdit) {
        let utf8 = source.utf8
        let count = utf8.count
        guard range.offset >= 0, range.upperBound <= count else {
            throw EditError.rangeOutOfBounds
        }

        let start = utf8.index(utf8.startIndex, offsetBy: range.offset)
        let end = utf8.index(start, offsetBy: range.length)
        func isContinuationByte(_ index: String.UTF8View.Index) -> Bool {
            index < utf8.endIndex && utf8[index] & 0b1100_0000 == 0b1000_0000
        }
        guard !isContinuationByte(start), !isContinuationByte(end) else {
            throw EditError.rangeNotOnCharacterBoundary
        }

        let removed: String
        var result: String
        if let startIndex = start.samePosition(in: source),
           let endIndex = end.samePosition(in: source) {
            // Grapheme-aligned (the overwhelmingly common case): substring
            // concatenation, no byte materialization.
            removed = String(source[startIndex..<endIndex])
            result = String(source[..<startIndex])
            result.reserveCapacity(count + replacement.utf8.count - range.length)
            result += replacement
            result += source[endIndex...]
        } else {
            // Scalar-aligned but inside a grapheme cluster (combining marks,
            // flags): rare enough that the byte-copy path's cost is fine.
            let bytes = Array(utf8)
            removed = String(decoding: bytes[range.offset..<range.upperBound], as: UTF8.self)
            var newBytes = Array(bytes[0..<range.offset])
            newBytes.append(contentsOf: Array(replacement.utf8))
            newBytes.append(contentsOf: bytes[range.upperBound...])
            result = String(decoding: newBytes, as: UTF8.self)
        }

        let inverse = SourceEdit(
            range: ByteRange(offset: range.offset, length: replacement.utf8.count),
            replacement: removed
        )
        return (result, inverse)
    }
}

/// Offset conversions between the text system's UTF-16 world and the source
/// map's UTF-8 world, for a text run that appears verbatim in both (the
/// active block's source slice in the editor).
public enum EditMapping {

    /// UTF-8 byte offset for a UTF-16 offset into `text`, or nil if out of
    /// range or not on a scalar boundary.
    public static func utf8Offset(inText text: String, utf16Offset: Int) -> Int? {
        guard utf16Offset >= 0, utf16Offset <= text.utf16.count else { return nil }
        let utf16Index = text.utf16.index(text.utf16.startIndex, offsetBy: utf16Offset)
        guard let index = utf16Index.samePosition(in: text.utf8) else { return nil }
        return text.utf8.distance(from: text.utf8.startIndex, to: index)
    }

    /// UTF-16 offset for a UTF-8 byte offset into `text`, or nil.
    public static func utf16Offset(inText text: String, utf8Offset: Int) -> Int? {
        guard utf8Offset >= 0, utf8Offset <= text.utf8.count else { return nil }
        let utf8Index = text.utf8.index(text.utf8.startIndex, offsetBy: utf8Offset)
        guard let index = utf8Index.samePosition(in: text.utf16) else { return nil }
        return text.utf16.distance(from: text.utf16.startIndex, to: index)
    }

    /// Converts a UTF-16 range within `text` to a UTF-8 byte range.
    public static func utf8Range(inText text: String, utf16Range: Range<Int>) -> ByteRange? {
        guard let start = utf8Offset(inText: text, utf16Offset: utf16Range.lowerBound),
              let end = utf8Offset(inText: text, utf16Offset: utf16Range.upperBound)
        else { return nil }
        return ByteRange(offset: start, length: end - start)
    }

    /// Maps a caret position in a block's RENDERED text onto its SOURCE
    /// slice (both UTF-16). The rendered projection hides or transforms
    /// source characters — `**` delimiters, `### ` prefixes, the two
    /// trailing spaces of a hard break, `&amp;` entities — so a raw offset
    /// drifts by every hidden character before the caret (clicking at the
    /// end of "…a hard line break." landed two characters early).
    ///
    /// Greedy two-pointer alignment: matching characters advance both
    /// sides; a mismatch advances the SOURCE (hidden delimiter) unless the
    /// rendered character can't exist in source at all (an attachment's
    /// U+FFFC), which advances the rendered side. Newline and space match
    /// each other (a soft break renders as either). The result is exact for
    /// plain text and lands within the hidden-run for styled spans — never
    /// several characters adrift.
    public static func sourceOffset(
        forRenderedOffset renderedOffset: Int,
        renderedText: String,
        sourceText: String
    ) -> Int {
        let rendered = Array(renderedText.utf16)
        let source = Array(sourceText.utf16)
        let target = min(max(0, renderedOffset), rendered.count)
        let attachment: UInt16 = 0xFFFC
        let newline = UInt16(UnicodeScalar("\n").value)
        let space = UInt16(UnicodeScalar(" ").value)

        func aligned(_ sc: UInt16, _ rc: UInt16) -> Bool {
            sc == rc || (sc == newline && rc == space) || (sc == space && rc == newline)
        }
        /// First index in `source` within a bounded window that aligns with
        /// `rc`, or nil — nil means `rc` is a TRANSFORMED character (an
        /// entity like `&lt;` rendering as `<`) with no literal counterpart.
        func lookahead(from start: Int, for rc: UInt16) -> Int? {
            let limit = min(start + 24, source.count)
            var i = start
            while i < limit {
                if aligned(source[i], rc) { return i }
                i += 1
            }
            return nil
        }

        var s = 0
        var r = 0
        while r < target, s < source.count {
            let rc = rendered[r]
            if rc == attachment {
                r += 1                                   // rendered-only (image, chip)
            } else if aligned(source[s], rc) {
                s += 1; r += 1
            } else if let match = lookahead(from: s, for: rc) {
                s = match                                // skip the hidden source run
            } else {
                s += 1; r += 1                           // transformed char: 1:1 fallback
            }
        }
        // A click at the very START aligns across the leading hidden run
        // (clicking at a heading's start lands past "### "). Applied ONLY at
        // zero: after consuming rendered text, the caret belongs BEFORE any
        // closing delimiter (clicking after "bold" stays inside the `**`
        // span so continued typing extends it).
        if target == 0, r < rendered.count, s < source.count,
           rendered[r] != attachment, !aligned(source[s], rendered[r]),
           let match = lookahead(from: s, for: rendered[r]) {
            s = match
        }
        return s
    }
}
