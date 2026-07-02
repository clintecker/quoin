import Foundation
import Markdown

/// A byte range into the original markdown source (UTF-8 offsets).
///
/// The source map is load-bearing: it powers checkbox write-back, search
/// highlighting, live-reload scroll anchoring, and (later) the edit mode.
public struct ByteRange: Hashable, Sendable, Codable {
    public let offset: Int
    public let length: Int

    public init(offset: Int, length: Int) {
        self.offset = offset
        self.length = length
    }

    public var upperBound: Int { offset + length }

    public func contains(_ byteOffset: Int) -> Bool {
        byteOffset >= offset && byteOffset < upperBound
    }
}

/// Maps swift-markdown's 1-based (line, column) source locations to UTF-8
/// byte offsets in the source string. cmark columns are byte-based, so the
/// conversion is `lineStart + column - 1`.
struct LineIndex {
    /// UTF-8 byte offset of the start of each line (index 0 = line 1).
    private let lineStarts: [Int]
    let totalBytes: Int

    init(source: String) {
        var starts: [Int] = [0]
        let bytes = Array(source.utf8)
        for (i, byte) in bytes.enumerated() where byte == UInt8(ascii: "\n") {
            starts.append(i + 1)
        }
        self.lineStarts = starts
        self.totalBytes = bytes.count
    }

    /// Byte offset for a 1-based line and 1-based byte column.
    func byteOffset(line: Int, column: Int) -> Int {
        guard line >= 1, line <= lineStarts.count else { return totalBytes }
        return min(lineStarts[line - 1] + column - 1, totalBytes)
    }

    /// Converts a swift-markdown source range into a byte range.
    /// swift-markdown ranges are half-open (`lower ..< upper`), with the
    /// upper bound one column past the last character.
    func byteRange(of range: SourceRange?) -> ByteRange {
        guard let range else { return ByteRange(offset: 0, length: 0) }
        let start = byteOffset(line: range.lowerBound.line, column: range.lowerBound.column)
        let end = byteOffset(line: range.upperBound.line, column: range.upperBound.column)
        return ByteRange(offset: start, length: max(0, end - start))
    }
}

extension String {
    /// The substring covered by a UTF-8 byte range, if it falls on valid boundaries.
    public func substring(in range: ByteRange) -> String? {
        let bytes = Array(utf8)
        guard range.offset >= 0, range.upperBound <= bytes.count else { return nil }
        return String(decoding: bytes[range.offset..<range.upperBound], as: UTF8.self)
    }
}
