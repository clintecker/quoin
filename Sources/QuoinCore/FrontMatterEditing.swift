import Foundation

// MARK: - Front-matter field editing (Properties inspector, #70)

/// Line-surgery readers and writers over the leading YAML front-matter
/// block — the Properties panel's engine. The panel is the EDITOR; the
/// in-document field grid stays the projection.
///
/// Reads are CRLF-tolerant (the walk is byte-level: Swift's `\r\n` is ONE
/// grapheme, so Character splits never split CRLF lines). Writes replace
/// only the target key's line(s) — every other line is byte-lossless.
/// Values are ONE-LINE scalars, escaped by the same quoted-scalar rules as
/// review endmatter; nested/complex values (block maps, lists, flow
/// collections, block scalars) are read-only (`isComplex`) because
/// rewriting them as scalars would silently change their YAML type.
///
/// Every writer self-calibrates: the candidate result must still parse as
/// front matter, read back the expected fields, and leave the document
/// BODY byte-identical — anything else refuses. Conservative rejections
/// are always safe.
public enum FrontMatterEditing {

    /// One top-level front-matter field, as the Properties panel sees it.
    public struct Field: Hashable, Sendable {
        public let key: String
        /// The parsed one-line scalar (quotes stripped, escapes resolved).
        /// Empty for complex fields — `rawPreview` carries their source.
        public let value: String
        /// The field's line(s) in the DOCUMENT — nested continuation lines
        /// and the trailing newline included; removal replaces exactly this.
        public let byteRange: ByteRange
        /// Nested / flow-collection / block-scalar value: shown read-only,
        /// and `setFieldEdit` refuses it.
        public let isComplex: Bool
        /// The raw source text after `key:` (continuation lines joined with
        /// newlines) — the panel's read-only preview for complex fields.
        public let rawPreview: String
    }

    // MARK: - Reading

    /// Every top-level field in the document's front matter, in file order.
    /// Empty when the document has no front-matter block.
    public static func fields(in source: String) -> [Field] {
        guard let block = block(in: source) else { return [] }
        let bytes = Array(source.utf8)
        let region = sourceLines(in: bytes).filter {
            $0.start >= block.fieldRegionStart && $0.start < block.closingLineStart
        }

        var result: [Field] = []
        var pending: PendingField?
        func flush() {
            if let field = pending { result.append(field.finished()) }
            pending = nil
        }
        for line in region {
            let trimmed = line.text.trimmingCharacters(in: .whitespaces)
            let indented = line.text.first == " " || line.text.first == "\t"
            if trimmed.isEmpty {
                // A blank line separates fields; it belongs to none, so a
                // removal never swallows the air around its neighbors.
                flush()
                continue
            }
            if !indented, trimmed.hasPrefix("#") {
                // Top-level comments survive any adjacent field's removal.
                flush()
                continue
            }
            if !indented, let head = keyLine(trimmed) {
                flush()
                pending = PendingField(
                    key: head.key, rawValue: head.rawValue,
                    start: line.start, end: line.end)
                continue
            }
            // Continuation: an indented line, a top-level list item, or any
            // other unrecognized line rides with the field above it.
            if pending != nil {
                pending!.end = line.end
                pending!.continuations.append(trimmed)
            }
        }
        flush()
        return result
    }

    // MARK: - Writing

    /// Replaces an existing key's line, appends a new key before the
    /// closing `---`, or CREATES the whole front-matter block at byte 0
    /// when the document has none. Nil refuses: complex value under that
    /// key, an unsafe key, a duplicated key, or a candidate that fails
    /// self-calibration. The value is normalized to one physical line
    /// (newlines flatten to spaces, outer whitespace trimmed) — YAML
    /// scalars here are one-line by contract.
    public static func setFieldEdit(key: String, value: String, in source: String) -> SourceEdit? {
        guard isEditableKey(key) else { return nil }
        let normalized = value
            .components(separatedBy: .newlines)
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespaces)
        let line = "\(key): \(ReviewEndmatter.fieldValue(normalized))"

        let edit: SourceEdit
        let expectedOthers: [Field]
        if let block = block(in: source) {
            let existing = fields(in: source)
            let matches = existing.filter { $0.key == key }
            if let field = matches.first {
                // Duplicated keys are ambiguous — one contiguous edit can't
                // fix both lines, so refuse rather than leave a shadow.
                guard matches.count == 1, !field.isComplex else { return nil }
                edit = SourceEdit(range: field.byteRange, replacement: line + block.newline)
            } else {
                edit = SourceEdit(
                    range: ByteRange(offset: block.closingLineStart, length: 0),
                    replacement: line + block.newline)
            }
            expectedOthers = existing.filter { $0.key != key }
        } else {
            // No front matter: create the whole block at byte 0, in the
            // document's own newline flavor.
            let newline = source.contains("\r\n") ? "\r\n" : "\n"
            edit = SourceEdit(
                range: ByteRange(offset: 0, length: 0),
                replacement: "---\(newline)\(line)\(newline)---\(newline)")
            expectedOthers = []
        }
        return validated(edit, in: source) { candidate in
            let after = fields(in: candidate)
            guard let written = after.first(where: { $0.key == key }),
                  written.value == normalized, !written.isComplex else { return false }
            return signatures(of: after.filter { $0.key != key }) == signatures(of: expectedOthers)
        }
    }

    /// Removes the key's line(s) — nested continuation lines included.
    /// Removing the LAST field removes the entire block (an empty
    /// `---\n---\n` chip is noise, and the grid renders nothing anyway).
    /// Nil refuses: key absent, key duplicated, or self-calibration failed.
    public static func removeFieldEdit(key: String, in source: String) -> SourceEdit? {
        guard let block = block(in: source) else { return nil }
        let existing = fields(in: source)
        let matches = existing.filter { $0.key == key }
        guard matches.count == 1, let field = matches.first else { return nil }
        let others = existing.filter { $0.key != key }

        if others.isEmpty, fieldRegionIsBlankOutside(field.byteRange, block: block, in: source) {
            // Last field, nothing else in the block: remove the block.
            let edit = SourceEdit(range: ByteRange(offset: 0, length: block.length), replacement: "")
            guard let (candidate, _) = try? edit.apply(to: source),
                  // The body must not get REINTERPRETED as front matter (a
                  // body that itself starts with `---\n…---` would silently
                  // promote its first section into metadata).
                  self.block(in: candidate) == nil,
                  candidate == bodySuffix(of: source, afterBlockLength: block.length)
            else { return nil }
            return edit
        }

        let edit = SourceEdit(range: field.byteRange, replacement: "")
        return validated(edit, in: source) { candidate in
            let after = fields(in: candidate)
            return !after.contains { $0.key == key }
                && signatures(of: after) == signatures(of: others)
        }
    }

    /// Keys the writers accept: the same shape the field grid renders as a
    /// key row (letters, digits, `_`, `-`) — anything else could smuggle
    /// structure (colons, quotes, leading `-`) into the key position.
    public static func isEditableKey(_ key: String) -> Bool {
        !key.isEmpty && key.allSatisfy { $0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" }
    }

    // MARK: - Block geometry (shared with MarkdownConverter via InlinePostPasses)

    /// The front-matter block's byte geometry. `yaml` is the CRLF-normalized
    /// text between the delimiters — the exact value `MarkdownConverter`
    /// stores in `.frontMatter(yaml:)`.
    struct DetectedBlock {
        let yaml: String
        /// Bytes `0..<length` are the whole block, closing line included.
        let length: Int
        /// Just past the opening `---` line: the field region's start.
        let fieldRegionStart: Int
        /// The closing delimiter line's first byte: the field region's end,
        /// and where a new field appends.
        let closingLineStart: Int
        /// The block's own line terminator, for lines the writers create.
        let newline: String
    }

    /// Byte-level front-matter detection: the source must OPEN with a bare
    /// `---` line and a later line must close with `---` or `…` (`...`).
    /// Unterminated front matter is ordinary content, exactly like the
    /// converter's rule.
    static func block(in source: String) -> DetectedBlock? {
        let bytes = Array(source.utf8)
        let lines = sourceLines(in: bytes)
        guard let opening = lines.first, opening.text == "---",
              // A bare `---` at EOF (no terminator) is a thematic break.
              opening.end > opening.start + 3
        else { return nil }
        let usesCRLF = bytes[opening.end - 2] == 0x0D
        for (index, line) in lines.enumerated().dropFirst() {
            let trimmed = line.text.trimmingCharacters(in: .whitespaces)
            guard trimmed == "---" || trimmed == "..." else { continue }
            let yaml = lines[1..<index].map(\.text).joined(separator: "\n")
            return DetectedBlock(
                yaml: yaml,
                length: line.end,
                fieldRegionStart: opening.end,
                closingLineStart: line.start,
                newline: usesCRLF ? "\r\n" : "\n")
        }
        return nil
    }

    // MARK: - Internals

    private struct PendingField {
        let key: String
        let rawValue: String
        let start: Int
        var end: Int
        var continuations: [String] = []

        func finished() -> Field {
            let hasContinuations = !continuations.isEmpty
            // Flow collections, block scalars, and YAML anchors/aliases are
            // not one-line scalars even on one line.
            let complexLead = rawValue.first.map { "[{|>&*".contains($0) } ?? false
            let isComplex = hasContinuations || complexLead
            let preview = ([rawValue] + continuations)
                .filter { !$0.isEmpty }
                .joined(separator: "\n")
            return Field(
                key: key,
                value: isComplex ? "" : unquoted(rawValue),
                byteRange: ByteRange(offset: start, length: end - start),
                isComplex: isComplex,
                rawPreview: preview)
        }
    }

    /// Splits a top-level `key: value` line, or nil when the line isn't a
    /// field (the same key shape the grid renderer recognizes).
    private static func keyLine(_ trimmed: String) -> (key: String, rawValue: String)? {
        guard let colon = trimmed.firstIndex(of: ":") else { return nil }
        let key = String(trimmed[..<colon])
        guard isEditableKey(key) else { return nil }
        let rawValue = String(trimmed[trimmed.index(after: colon)...])
            .trimmingCharacters(in: .whitespaces)
        return (key, rawValue)
    }

    /// One-line scalar readback: strips a matching pair of double quotes
    /// (resolving `\"`/`\\` in one left-to-right scan, the ReviewEndmatter
    /// rule) or single quotes (resolving `''`).
    private static func unquoted(_ raw: String) -> String {
        if raw.hasPrefix("\""), raw.hasSuffix("\""), raw.count >= 2 {
            var unescaped = ""
            var iterator = raw.dropFirst().dropLast().makeIterator()
            while let ch = iterator.next() {
                if ch == "\\", let next = iterator.next() {
                    unescaped.append(next)
                } else {
                    unescaped.append(ch)
                }
            }
            return unescaped
        }
        if raw.hasPrefix("'"), raw.hasSuffix("'"), raw.count >= 2 {
            return String(raw.dropFirst().dropLast())
                .replacingOccurrences(of: "''", with: "'")
        }
        return raw
    }

    /// True when nothing but blank lines remains in the field region once
    /// `range` is taken out — the whole-block-removal precondition.
    private static func fieldRegionIsBlankOutside(
        _ range: ByteRange, block: DetectedBlock, in source: String
    ) -> Bool {
        let bytes = Array(source.utf8)
        return sourceLines(in: bytes)
            .filter { $0.start >= block.fieldRegionStart && $0.start < block.closingLineStart }
            .filter { $0.start < range.offset || $0.start >= range.upperBound }
            .allSatisfy { $0.text.trimmingCharacters(in: .whitespaces).isEmpty }
    }

    /// The self-calibration gate shared by both writers: the candidate must
    /// still open with a parsable front-matter block, its BODY must be
    /// byte-identical to the original body, and the caller's field-level
    /// expectation must hold.
    private static func validated(
        _ edit: SourceEdit, in source: String, expecting check: (String) -> Bool
    ) -> SourceEdit? {
        guard let (candidate, _) = try? edit.apply(to: source) else { return nil }
        guard let newBlock = block(in: candidate) else { return nil }
        let oldBody = bodySuffix(of: source, afterBlockLength: block(in: source)?.length ?? 0)
        guard bodySuffix(of: candidate, afterBlockLength: newBlock.length) == oldBody else { return nil }
        guard check(candidate) else { return nil }
        return edit
    }

    private static func bodySuffix(of source: String, afterBlockLength length: Int) -> String {
        let bytes = Array(source.utf8)
        guard length <= bytes.count else { return "" }
        return String(decoding: bytes[length...], as: UTF8.self)
    }

    /// Comparable field identity for the untouched-fields check: byte
    /// ranges shift with any edit above them, so compare content only.
    private static func signatures(of fields: [Field]) -> [[String]] {
        fields.map { [$0.key, $0.value, $0.isComplex ? "complex" : "scalar", $0.rawPreview] }
    }

    // MARK: - Byte-level line walking

    private struct SourceLine {
        /// Content without its terminator; a trailing `\r` is stripped so
        /// CRLF and LF lines read identically.
        let text: String
        /// Byte offset of the line's first byte.
        let start: Int
        /// Byte offset just past the terminator (the next line's start, or EOF).
        let end: Int
    }

    private static func sourceLines(in bytes: [UInt8]) -> [SourceLine] {
        var lines: [SourceLine] = []
        var start = 0
        var i = 0
        while i <= bytes.count {
            if i == bytes.count || bytes[i] == 0x0A {
                guard start < bytes.count else { break }
                var contentEnd = i
                if contentEnd > start, bytes[contentEnd - 1] == 0x0D { contentEnd -= 1 }
                let end = i == bytes.count ? i : i + 1
                lines.append(SourceLine(
                    text: String(decoding: bytes[start..<contentEnd], as: UTF8.self),
                    start: start,
                    end: end))
                start = end
            }
            i += 1
        }
        return lines
    }
}
