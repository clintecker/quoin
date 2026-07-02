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
    public func apply(to source: String) throws -> (result: String, inverse: SourceEdit) {
        let bytes = Array(source.utf8)
        guard range.offset >= 0, range.upperBound <= bytes.count else {
            throw EditError.rangeOutOfBounds
        }
        let removedBytes = Array(bytes[range.offset..<range.upperBound])
        var newBytes = Array(bytes[0..<range.offset])
        newBytes.append(contentsOf: Array(replacement.utf8))
        newBytes.append(contentsOf: bytes[range.upperBound...])

        // Refuse edits that split a UTF-8 scalar: decoding must round-trip.
        let result = String(decoding: newBytes, as: UTF8.self)
        guard Array(result.utf8) == newBytes else {
            throw EditError.rangeNotOnCharacterBoundary
        }
        let removed = String(decoding: removedBytes, as: UTF8.self)
        guard Array(removed.utf8) == removedBytes else {
            throw EditError.rangeNotOnCharacterBoundary
        }

        let inverse = SourceEdit(
            range: ByteRange(offset: range.offset, length: Array(replacement.utf8).count),
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
}
