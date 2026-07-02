import Foundation

public enum SessionError: Error {
    case fileUnreadable(URL)
    case taskNotTogglable
}

/// The single authority over one open document's source text.
///
/// Every input — the file watcher, a checkbox tap, and eventually an editor
/// pane — funnels through the same path: apply the mutation to the source,
/// re-parse, and publish a fresh immutable `QuoinDocument` snapshot. The UI
/// only ever consumes snapshots; it never touches the source directly. This
/// is the seam a future edit mode drops into.
public actor DocumentSession {

    public private(set) var document: QuoinDocument
    public let fileURL: URL?

    private var watcher: FileWatcher?
    private var continuations: [UUID: AsyncStream<QuoinDocument>.Continuation] = [:]
    /// Hash of content we ourselves just wrote, so the resulting file-system
    /// event is recognized as self-inflicted and not re-published.
    private var selfWriteHash: String?

    // MARK: - Lifecycle

    public init(source: String, fileURL: URL? = nil) {
        self.document = MarkdownConverter.parse(source)
        self.fileURL = fileURL
    }

    /// Opens a file and starts watching it for external changes.
    public static func open(fileURL: URL) throws -> DocumentSession {
        guard let data = try? Data(contentsOf: fileURL),
              let source = String(data: data, encoding: .utf8)
        else { throw SessionError.fileUnreadable(fileURL) }
        return DocumentSession(source: source, fileURL: fileURL)
    }

    /// Begins publishing snapshots for external file changes. Idempotent.
    public func startWatching() {
        guard watcher == nil, let fileURL else { return }
        let newWatcher = FileWatcher(url: fileURL) { [weak self] in
            guard let self else { return }
            Task { await self.reloadFromDisk() }
        }
        watcher = newWatcher
        newWatcher.start()
    }

    public func stopWatching() {
        watcher?.cancel()
        watcher = nil
    }

    // MARK: - Snapshots

    /// A stream of document snapshots, starting with the current one.
    public func snapshots() -> AsyncStream<QuoinDocument> {
        let id = UUID()
        return AsyncStream { continuation in
            continuations[id] = continuation
            continuation.yield(document)
            continuation.onTermination = { [weak self] _ in
                guard let self else { return }
                Task { await self.removeContinuation(id) }
            }
        }
    }

    private func removeContinuation(_ id: UUID) {
        continuations[id] = nil
    }

    private func publish(_ newDocument: QuoinDocument) {
        document = newDocument
        for continuation in continuations.values {
            continuation.yield(newDocument)
        }
    }

    // MARK: - Mutations

    /// Reloads from disk after an external change. No-ops when the content
    /// is unchanged or was written by this session (checkbox write-back).
    public func reloadFromDisk() {
        guard let fileURL,
              let data = try? Data(contentsOf: fileURL),
              let source = String(data: data, encoding: .utf8)
        else { return }

        let hash = SHA256Hex.hash(of: source)
        if hash == document.sourceHash { return }
        if hash == selfWriteHash {
            selfWriteHash = nil
            return
        }
        publish(MarkdownConverter.parse(source))
    }

    /// Applies new source text (the general mutation path; the future edit
    /// mode feeds keystrokes through here).
    public func apply(source: String) {
        guard SHA256Hex.hash(of: source) != document.sourceHash else { return }
        publish(MarkdownConverter.parse(source))
    }

    /// Toggles a task checkbox and writes the change back to disk,
    /// byte-precise. If the file changed on disk since the last parse, it is
    /// re-read first and the toggle is re-validated against fresh content.
    public func toggleTask(markerRange: ByteRange) throws {
        var base = document

        // Conflict rule: if disk moved under us, re-parse before writing.
        if let fileURL,
           let data = try? Data(contentsOf: fileURL),
           let diskSource = String(data: data, encoding: .utf8),
           SHA256Hex.hash(of: diskSource) != base.sourceHash {
            base = MarkdownConverter.parse(diskSource)
            guard base.source.substring(in: ByteRange(offset: markerRange.offset, length: markerRange.length)) != nil else {
                throw SessionError.taskNotTogglable
            }
        }

        let newSource = try TaskToggler.toggle(source: base.source, markerRange: markerRange)

        if let fileURL {
            selfWriteHash = SHA256Hex.hash(of: newSource)
            try Data(newSource.utf8).write(to: fileURL, options: .atomic)
        }
        publish(MarkdownConverter.parse(newSource))
    }
}
