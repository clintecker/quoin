import Foundation

/// Smart-pair completion for the editor: typing an opening delimiter wraps
/// the caret in a closed pair; typing the closing half over an existing
/// closer skips it instead of doubling. Suspended inside code spans and
/// fences (design rule).
public enum SmartPairs {

    /// Delimiters that auto-close (handoff: `**` `_` `==` `$` `` ` ``).
    /// Single `*` completes too since `**` arrives as two keystrokes.
    static let pairs: Set<Character> = ["*", "_", "`", "$", "="]

    public struct Completion: Equatable, Sendable {
        /// Text to insert in place of the typed character(s).
        public let insert: String
        /// Caret position within `insert` (UTF-16) after insertion.
        public let caretOffset: Int
    }

    /// Decides how a single typed character behaves at `caretUTF16` in
    /// `text` (the active block's source). Returns nil for default handling.
    public static func completion(
        typing character: Character,
        inText text: String,
        caretUTF16 offset: Int
    ) -> Completion? {
        guard pairs.contains(character) else { return nil }
        guard !isInsideCodeContext(text: text, caretUTF16: offset) else { return nil }

        let chars = Array(text.utf16).map { $0 }
        let next: Character? = {
            guard offset < chars.count, let scalar = Unicode.Scalar(chars[offset]) else { return nil }
            return Character(scalar)
        }()

        // Type-over: the closing half already sits at the caret.
        if next == character {
            return Completion(insert: "", caretOffset: 1)
        }

        // `=` only pairs as part of `==`; a single equals is just text.
        if character == "=" {
            let previous: Character? = {
                guard offset > 0, let scalar = Unicode.Scalar(chars[offset - 1]) else { return nil }
                return Character(scalar)
            }()
            guard previous == "=" else { return nil }
            // Second `=` of an opener: complete to `==caret==`.
            return Completion(insert: "=" + "==", caretOffset: 1)
        }

        // Don't pair when gluing onto a word (typing *inside* text like
        // can*t); pairing is for starting a span.
        if let next, next.isLetter || next.isNumber {
            return nil
        }

        return Completion(insert: String(character) + String(character), caretOffset: 1)
    }

    /// True when the caret sits inside an inline code span or a code fence,
    /// where smart pairs are suspended.
    static func isInsideCodeContext(text: String, caretUTF16 offset: Int) -> Bool {
        var insideFence = false
        var backtickRun = 0
        var insideSpan = false
        var index = 0
        var atLineStart = true

        for unit in text.utf16 {
            if index >= offset { break }
            let ch = Character(Unicode.Scalar(unit) ?? " ")

            if ch == "`" {
                backtickRun += 1
            } else {
                if backtickRun >= 3 && atLineStart {
                    insideFence.toggle()
                } else if backtickRun > 0 && !insideFence {
                    insideSpan.toggle()
                }
                backtickRun = 0
                atLineStart = (ch == "\n")
            }
            index += 1
        }
        // Account for a run ending exactly at the caret.
        if backtickRun >= 3 && atLineStart {
            insideFence.toggle()
        } else if backtickRun > 0 && !insideFence {
            insideSpan.toggle()
        }
        return insideFence || insideSpan
    }
}

/// Selection-based format commands (⌘B/⌘I/⌘K/⇧⌘H): wrap or unwrap the
/// selected source text. Pure functions over the active block's source so
/// they're testable without a text system.
public enum Formatting {

    public struct Change: Equatable, Sendable {
        /// Replacement for the UTF-16 selection range that was passed in.
        public let replacement: String
        /// New selection within `replacement` (UTF-16).
        public let selectionOffset: Int
        public let selectionLength: Int
    }

    /// Toggles a symmetric delimiter (e.g. `**`, `*`, `==`) around the
    /// selected text.
    public static func toggleWrap(selection: String, delimiter: String) -> Change {
        let hasWrap = selection.hasPrefix(delimiter) && selection.hasSuffix(delimiter)
            && selection.count >= delimiter.count * 2
        if hasWrap {
            let inner = String(selection.dropFirst(delimiter.count).dropLast(delimiter.count))
            return Change(replacement: inner, selectionOffset: 0, selectionLength: inner.utf16.count)
        }
        let wrapped = delimiter + selection + delimiter
        return Change(
            replacement: wrapped,
            selectionOffset: delimiter.utf16.count,
            selectionLength: selection.utf16.count
        )
    }

    /// Wraps the selection as a link: `[selection](url)`, selecting the URL
    /// placeholder for immediate typing.
    public static func makeLink(selection: String, url: String = "url") -> Change {
        let text = selection.isEmpty ? "link" : selection
        let replacement = "[\(text)](\(url))"
        let offset = 1 + text.utf16.count + 2 // past "[text]("
        return Change(replacement: replacement, selectionOffset: offset, selectionLength: url.utf16.count)
    }
}
