import Foundation

// MARK: - RDFM review endmatter (suggestions design §2, S2)

/// Metadata for one comment or suggestion, keyed by its `{#id}` reference.
public struct ReviewEntry: Hashable, Sendable {
    /// Author label; the literal `AI` marks agent authorship (RDFM).
    public var by: String?
    /// ISO-8601 timestamp, kept as its source string (rendering decides
    /// how much precision to show).
    public var at: String?
    /// Parent id — a threaded reply (reply bodies live entirely in
    /// endmatter; root bodies stay inline for anchor portability).
    public var re: String?
    /// `resolved` when the thread is closed.
    public var status: String?
    /// Resolution summary, when present.
    public var resolved: String?
    /// Endmatter-only body (replies and document-level comments).
    public var body: String?
}

public struct ReviewMetadata: Hashable, Sendable {
    public var comments: [String: ReviewEntry]
    public var suggestions: [String: ReviewEntry]

    public var isEmpty: Bool { comments.isEmpty && suggestions.isEmpty }

    public func entry(for id: String) -> ReviewEntry? {
        comments[id] ?? suggestions[id]
    }
}

/// Detects and parses the RDFM YAML endmatter: the LAST `\n---\n` in the
/// document whose tail parses as a `comments:`/`suggestions:` map — and only
/// when the body actually references it (`{#` somewhere before it) or it
/// carries a document-level comment. That ambiguity heuristic (from the RDFM
/// reference implementation) protects ordinary documents that merely end
/// with a thematic break. The YAML subset is deliberately tiny — two-level
/// maps with scalar string values, double-quoted or bare — parsed by hand
/// (the one-dependency policy; front matter set the precedent of carrying
/// raw YAML).
public enum ReviewEndmatter {

    public struct Detected: Sendable {
        /// Byte range of the endmatter INCLUDING its leading `\n---\n`
        /// delimiter — the body ends where this starts.
        public let range: ByteRange
        public let yaml: String
        public let metadata: ReviewMetadata
    }

    public static func detect(in source: String) -> Detected? {
        guard let delimiterRange = source.range(of: "\n---\n", options: .backwards) else { return nil }
        let tail = String(source[delimiterRange.upperBound...])
        guard let metadata = parse(yaml: tail), !metadata.isEmpty else { return nil }
        let body = String(source[..<delimiterRange.lowerBound])
        // Referenced from the body, carrying a document-level comment
        // (an entry with a body and no parent), or holding RESOLUTION
        // RECORDS (status: resolved) — Quoin's history extension: once the
        // last inline {#id} resolves, the records must keep the endmatter
        // recognized or they'd leak into prose.
        let documentLevel = metadata.comments.values.contains { $0.body != nil && $0.re == nil }
        let hasRecords = metadata.comments.values.contains { $0.status == "resolved" }
            || metadata.suggestions.values.contains { $0.status == "resolved" }
        guard body.contains("{#") || documentLevel || hasRecords else { return nil }
        let offset = source.utf8.distance(from: source.utf8.startIndex,
                                          to: delimiterRange.lowerBound.samePosition(in: source.utf8)!)
        return Detected(
            range: ByteRange(offset: offset, length: source.utf8.count - offset),
            yaml: tail,
            metadata: metadata)
    }

    /// Parses the RDFM endmatter YAML subset:
    ///
    /// ```yaml
    /// comments:
    ///   c1: { by: user, at: "2026-04-28T12:00:00Z" }
    ///   c2:
    ///     body: "I can add one."
    ///     by: AI
    ///     re: c1
    /// suggestions:
    ///   s1: { by: AI }
    /// ```
    ///
    /// Returns nil unless at least one `comments:`/`suggestions:` section
    /// exists — the caller's ordinary-`---` disambiguator.
    public static func parse(yaml: String) -> ReviewMetadata? {
        var comments: [String: ReviewEntry] = [:]
        var suggestions: [String: ReviewEntry] = [:]
        var section: String?      // "comments" | "suggestions"
        var currentID: String?
        var sawSection = false

        func assign(_ entry: ReviewEntry, id: String) {
            if section == "comments" { comments[id] = entry }
            else if section == "suggestions" { suggestions[id] = entry }
        }
        func current() -> ReviewEntry? {
            guard let id = currentID else { return nil }
            return section == "comments" ? comments[id] : suggestions[id]
        }

        for rawLine in yaml.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(rawLine)
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }
            let indent = line.prefix(while: { $0 == " " }).count

            if indent == 0 {
                currentID = nil
                if trimmed == "comments:" { section = "comments"; sawSection = true }
                else if trimmed == "suggestions:" { section = "suggestions"; sawSection = true }
                else {
                    // STRICT: review endmatter contains ONLY the review
                    // sections. Any other top-level line (prose, a closing
                    // code fence, front-matter keys) means this `---` is not
                    // endmatter — being lenient here made a fenced spec
                    // EXAMPLE parse as real endmatter and truncate the fence
                    // (caught by RDFMConformanceTests' spec golden).
                    return nil
                }
                continue
            }
            guard section != nil else { continue }

            if indent == 2, let colon = trimmed.firstIndex(of: ":") {
                let id = String(trimmed[..<colon]).trimmingCharacters(in: .whitespaces)
                guard !id.isEmpty, !id.contains(" ") else { return nil }
                var entry = ReviewEntry()
                let rest = String(trimmed[trimmed.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
                if rest.hasPrefix("{"), rest.hasSuffix("}") {
                    // Flow form: { by: user, at: "…" }
                    let inner = String(rest.dropFirst().dropLast())
                    for pair in splitFlowPairs(inner) {
                        guard let (key, value) = keyValue(pair) else { return nil }
                        set(&entry, key: key, value: value)
                    }
                } else if !rest.isEmpty {
                    return nil // an id line carries either a flow map or nothing
                }
                currentID = id
                assign(entry, id: id)
                continue
            }

            if indent >= 4, currentID != nil {
                guard let (key, value) = keyValue(trimmed), var entry = current() else { return nil }
                set(&entry, key: key, value: value)
                assign(entry, id: currentID!)
                continue
            }
            return nil // anything else isn't our subset
        }
        guard sawSection else { return nil }
        return ReviewMetadata(comments: comments, suggestions: suggestions)
    }

    private static func set(_ entry: inout ReviewEntry, key: String, value: String) {
        switch key {
        case "by": entry.by = value
        case "at": entry.at = value
        case "re": entry.re = value
        case "status": entry.status = value
        case "resolved": entry.resolved = value
        case "body": entry.body = value
        default: break // unknown keys are preserved in the raw yaml, ignored here
        }
    }

    private static func keyValue(_ text: String) -> (String, String)? {
        guard let colon = text.firstIndex(of: ":") else { return nil }
        let key = String(text[..<colon]).trimmingCharacters(in: .whitespaces)
        var value = String(text[text.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
        guard !key.isEmpty else { return nil }
        if value.hasPrefix("\""), value.hasSuffix("\""), value.count >= 2 {
            value = String(value.dropFirst().dropLast())
                .replacingOccurrences(of: "\\\"", with: "\"")
                .replacingOccurrences(of: "\\\\", with: "\\")
        }
        return (key, value)
    }

    /// Splits `by: user, at: "a, b"` on commas OUTSIDE quotes.
    private static func splitFlowPairs(_ text: String) -> [String] {
        var pairs: [String] = []
        var current = ""
        var inQuotes = false
        var previous: Character = " "
        for ch in text {
            if ch == "\"" && previous != "\\" { inQuotes.toggle() }
            if ch == "," && !inQuotes {
                pairs.append(current)
                current = ""
            } else {
                current.append(ch)
            }
            previous = ch
        }
        if !current.trimmingCharacters(in: .whitespaces).isEmpty { pairs.append(current) }
        return pairs.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }
}

// MARK: - Maintenance on resolution (suggestions S2, redlined 2026-07-14)

extension ReviewEndmatter {

    /// The endmatter's counterpart edit when the mark with `id` resolves:
    /// removes that entry AND its reply thread (entries whose `re` points
    /// into the removed set, transitively); when nothing remains, removes
    /// the ENTIRE endmatter block — otherwise the detection heuristic
    /// rightly stops firing once the last `{#id}` leaves the body, and the
    /// orphaned YAML leaks into the prose as a paragraph (the live bug:
    /// dismissing the only comment turned the endmatter into visible YAML
    /// soup). Remaining entries keep their original lines byte-exactly.
    public static func maintenanceEdit(afterResolving id: String, in source: String) -> SourceEdit? {
        guard let detected = detect(in: source) else { return nil }
        guard detected.metadata.entry(for: id) != nil else { return nil }

        // Transitive removal set over `re` links.
        var removed: Set<String> = [id]
        var grew = true
        while grew {
            grew = false
            for (entryID, entry) in detected.metadata.comments where !removed.contains(entryID) {
                if let re = entry.re, removed.contains(re) { removed.insert(entryID); grew = true }
            }
            for (entryID, entry) in detected.metadata.suggestions where !removed.contains(entryID) {
                if let re = entry.re, removed.contains(re) { removed.insert(entryID); grew = true }
            }
        }

        let remainingCount = (detected.metadata.comments.count + detected.metadata.suggestions.count)
            - removed.count
        if remainingCount <= 0 {
            return SourceEdit(range: detected.range, replacement: "")
        }

        // Line surgery: keep every line except removed entries' blocks and
        // section headers whose entries are all gone.
        var keptLines: [String] = []
        var pendingHeader: String?
        var skippingEntry = false
        for rawLine in detected.yaml.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(rawLine)
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            let indent = line.prefix(while: { $0 == " " }).count
            if indent == 0 {
                skippingEntry = false
                if trimmed == "comments:" || trimmed == "suggestions:" {
                    pendingHeader = line // emit only if it gains an entry
                } else {
                    if trimmed.isEmpty { keptLines.append(line) }
                }
                continue
            }
            if indent == 2, let colon = trimmed.firstIndex(of: ":") {
                let entryID = String(trimmed[..<colon]).trimmingCharacters(in: .whitespaces)
                skippingEntry = removed.contains(entryID)
                if !skippingEntry {
                    if let header = pendingHeader { keptLines.append(header); pendingHeader = nil }
                    keptLines.append(line)
                }
                continue
            }
            if !skippingEntry {
                keptLines.append(line)
            }
        }
        var replacement = "\n---\n" + keptLines.joined(separator: "\n")
        if !replacement.hasSuffix("\n") { replacement += "\n" }
        return SourceEdit(range: detected.range, replacement: replacement)
    }
}

// MARK: - Resolution records (history — suggestions S2, 2026-07-14 ask)

/// A resolved review item, read back from endmatter entries carrying
/// `status: resolved` — the RDFM-native history: resolutions live in the
/// file, portable and agent-readable, instead of vanishing.
public struct ResolvedRecord: Hashable, Sendable {
    public let id: String
    public let by: String?
    public let at: String?
    /// The `resolved:` summary Quoin writes: "accepted · <text>",
    /// "rejected · <old> → <new>", "dismissed · <comment>".
    public let summary: String
}

extension ReviewEndmatter {

    /// Every resolved entry in the document's metadata, newest last. A
    /// record whose mark is STILL IN THE BODY isn't history yet (an undo
    /// restored the mark; the mark wins) — it's excluded until the mark
    /// resolves again.
    public static func resolvedRecords(in document: QuoinDocument) -> [ResolvedRecord] {
        guard let metadata = document.reviewMetadata else { return [] }
        let liveIDs = Set(SuggestionResolver.marks(in: document).compactMap(\.id))
        let all = metadata.comments.merging(metadata.suggestions) { a, _ in a }
        return all
            .filter { $0.value.status == "resolved" && !liveIDs.contains($0.key) }
            .map { ResolvedRecord(
                id: $0.key, by: $0.value.by, at: $0.value.at,
                summary: $0.value.resolved ?? "resolved") }
            .sorted { ($0.at ?? $0.id) < ($1.at ?? $1.id) }
    }

    /// The endmatter edit that RECORDS a resolution instead of deleting the
    /// entry (the "things that have been acted on just disappear" redline):
    /// the entry keeps its author/time and gains `status: resolved` +
    /// `resolved: <summary>`. Reply threads stay — they're part of the
    /// record. Other entries keep their lines byte-exactly. Returns nil when
    /// the id has no entry (an un-referenced mark resolves unrecorded).
    public static func resolutionRecordEdit(
        resolving id: String, summary: String, in source: String
    ) -> SourceEdit? {
        guard let detected = detect(in: source),
              detected.metadata.entry(for: id) != nil else { return nil }

        var keptLines: [String] = []
        var inTargetEntry = false
        var wroteRecord = false
        func emitRecord(indentOnly: Bool = false) {
            guard inTargetEntry, !wroteRecord else { return }
            keptLines.append("    status: resolved")
            let escaped = summary
                .replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\"", with: "\\\"")
            keptLines.append("    resolved: \"\(escaped)\"")
            wroteRecord = true
            inTargetEntry = false
        }
        for rawLine in detected.yaml.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(rawLine)
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            let indent = line.prefix(while: { $0 == " " }).count
            if indent == 0 {
                emitRecord()
                keptLines.append(line)
                continue
            }
            if indent == 2, let colon = trimmed.firstIndex(of: ":") {
                emitRecord() // leaving the previous entry
                let entryID = String(trimmed[..<colon]).trimmingCharacters(in: .whitespaces)
                if entryID == id {
                    inTargetEntry = true
                    // Normalize a flow-form entry to block form so the
                    // record fields can append beneath it.
                    let rest = String(trimmed[trimmed.index(after: colon)...])
                        .trimmingCharacters(in: .whitespaces)
                    if rest.hasPrefix("{"), rest.hasSuffix("}") {
                        keptLines.append("  \(entryID):")
                        let inner = String(rest.dropFirst().dropLast())
                        for pair in splitFlowPairs(inner) {
                            keptLines.append("    \(pair)")
                        }
                    } else {
                        keptLines.append(line)
                    }
                    continue
                }
            }
            if inTargetEntry, indent >= 4 {
                // Existing block-form fields of the target entry: keep,
                // but drop any stale status/resolved (re-resolution).
                if trimmed.hasPrefix("status:") || trimmed.hasPrefix("resolved:") { continue }
                keptLines.append(line)
                continue
            }
            keptLines.append(line)
        }
        emitRecord()
        var replacement = "\n---\n" + keptLines.joined(separator: "\n")
        if !replacement.hasSuffix("\n") { replacement += "\n" }
        return SourceEdit(range: detected.range, replacement: replacement)
    }
}
