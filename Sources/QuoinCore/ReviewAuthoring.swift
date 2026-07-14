import Foundation

// MARK: - Creating a review (suggestions design §3.6, S3a)

/// Builds the ONE atomic annotation edit behind every S3a selection
/// gesture: the CriticMarkup mark wrapped around the selection's bytes
/// PLUS the endmatter entry (`by:`/`at:`), as a single spanning splice —
/// one ⌘Z removes the whole annotation, exactly the inverse of
/// `combinedResolutionEdit`.
///
/// A review never changes the prose: every kind here wraps or annotates
/// the selected bytes verbatim; only RESOLVING a suggestion changes what
/// the document says.
///
/// Validation is SELF-CALIBRATION (the incremental fast paths'
/// philosophy): the candidate source is parsed and the edit is returned
/// only when exactly the expected mark comes back at the expected offset
/// carrying the allocated id. That one rule subsumes the constraint list —
/// code/math opacity (a mark born inside a code span parses as literal →
/// refused), block-spanning selections (unbalanced per-slice → refused),
/// and sigil collisions in the selection (early close detaches the id →
/// refused). Conservative rejections are always safe: the caller beeps or
/// disables the gesture.
public enum ReviewAuthoring {

    public enum Kind: Equatable, Sendable {
        /// `{==sel==}{>>body<<}{#cN}` — the anchored-comment shape the
        /// panel renders as one card. With an EMPTY range: a document-level
        /// comment (endmatter-only entry with `body:`; no inline mark).
        case comment(body: String)
        /// `{~~sel~>new~~}{#sN}`
        case replacement(new: String)
        /// `{--sel--}{#sN}`
        case deletion
        /// `{==sel==}{#sN}`
        case highlight
        /// `{++text++}{#sN}` at a caret (range length 0).
        case insertion(text: String)
    }

    /// The combined mark + endmatter-entry edit, or nil when the
    /// annotation cannot be represented faithfully at that range.
    /// `timestamp` is threaded as a parameter (the session stamps it at
    /// apply time) so this stays a pure, testable function.
    public static func annotationEdit(
        kind: Kind, range: ByteRange, in source: String,
        reviewer: String, timestamp: String
    ) -> SourceEdit? {
        let bytes = Array(source.utf8)
        guard range.offset >= 0, range.length >= 0,
              range.offset + range.length <= bytes.count else { return nil }
        let slice = String(decoding: bytes[range.offset..<(range.offset + range.length)], as: UTF8.self)

        // Field lines shared by every entry this file writes.
        func entryFields(body: String? = nil) -> [String] {
            var fields = [
                "by: \(ReviewEndmatter.fieldValue(reviewer))",
                "at: \"\(ReviewEndmatter.escapedScalar(timestamp))\"",
            ]
            if let body {
                fields.append("body: \"\(ReviewEndmatter.escapedScalar(body))\"")
            }
            return fields
        }

        // Document-level comment: no selection, no mark — pure endmatter.
        if case .comment(let body) = kind, range.length == 0 {
            let flattened = flattenedInline(body)
            guard !flattened.isEmpty else { return nil }
            return ReviewEndmatter.appendedEntryEdit(
                fieldLines: entryFields(body: flattened),
                asComment: true, reusing: nil, in: source)?.edit
        }

        // Inline marks require a real selection (insertion: a caret).
        switch kind {
        case .insertion: guard range.length == 0 else { return nil }
        default: guard range.length > 0 else { return nil }
        }

        let asComment: Bool
        if case .comment = kind { asComment = true } else { asComment = false }
        let id = ReviewEndmatter.allocateID(asComment: asComment, in: source)

        let markText: String
        switch kind {
        case .comment(let body):
            let flattened = flattenedInline(body)
            guard !flattened.isEmpty else { return nil }
            markText = "{==\(slice)==}{>>\(flattened)<<}{#\(id)}"
        case .replacement(let new):
            markText = "{~~\(slice)~>\(flattenedInline(new))~~}{#\(id)}"
        case .deletion:
            markText = "{--\(slice)--}{#\(id)}"
        case .highlight:
            markText = "{==\(slice)==}{#\(id)}"
        case .insertion(let text):
            let flattened = flattenedInline(text)
            guard !flattened.isEmpty else { return nil }
            markText = "{++\(flattened)++}{#\(id)}"
        }

        guard let (entryEdit, _) = ReviewEndmatter.appendedEntryEdit(
            fieldLines: entryFields(),
            asComment: asComment, reusing: id, in: source),
            // The entry lands AFTER the mark (endmatter is at EOF); a
            // selection inside the endmatter itself can't be annotated.
            entryEdit.range.offset >= range.offset + range.length
        else { return nil }

        // ONE spanning splice: mark + unchanged middle + endmatter entry.
        let middle = String(decoding: bytes[
            (range.offset + range.length)..<entryEdit.range.offset], as: UTF8.self)
        let combined = SourceEdit(
            range: ByteRange(
                offset: range.offset,
                length: (entryEdit.range.offset + entryEdit.range.length) - range.offset),
            replacement: markText + middle + entryEdit.replacement)

        // Self-calibration: the candidate must parse back to a mark
        // carrying OUR id whose range starts exactly at the selection.
        var candidateBytes = bytes
        candidateBytes.replaceSubrange(
            combined.range.offset..<(combined.range.offset + combined.range.length),
            with: Array(combined.replacement.utf8))
        let candidate = String(decoding: candidateBytes, as: UTF8.self)
        let beforeMarks = SuggestionResolver.marks(in: MarkdownConverter.parse(source))
        let afterMarks = SuggestionResolver.marks(in: MarkdownConverter.parse(candidate))
        let expectedStart = range.offset
        let expectedEnd = range.offset + markText.utf8.count
        guard afterMarks.contains(where: { mark in
            mark.id == id
                && mark.range.offset >= expectedStart
                && mark.range.offset + mark.range.length == expectedEnd
        }) else { return nil }
        // …and it must not CONSUME any existing mark: wrapping a mark in a
        // highlight parses "cleanly" while silently turning the inner mark
        // into literal payload and orphaning its metadata. Every mark that
        // existed before must survive, plus exactly ours. (The anchored
        // comment counts as two: its highlight + its comment.)
        let added = { if case .comment = kind { return 2 } else { return 1 } }()
        let beforeIDs = Set(beforeMarks.compactMap(\.id))
        let afterIDs = Set(afterMarks.compactMap(\.id))
        guard afterMarks.count == beforeMarks.count + added,
              beforeIDs.subtracting(afterIDs).isEmpty else { return nil }

        return combined
    }

    /// Mark bodies live INSIDE an inline span: line breaks would change
    /// block structure (a blank line splits the paragraph mid-mark), so
    /// popover input flattens to one line — same rule as the resolution
    /// summaries.
    private static func flattenedInline(_ text: String) -> String {
        // Single-line input passes through UNTOUCHED (an insertion's
        // trailing space is meaningful: "{++really ++}"); only real line
        // breaks flatten. Whitespace-only input becomes empty (refused by
        // the callers).
        guard text.contains(where: \.isNewline) else {
            return text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "" : text
        }
        return text.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }
}
