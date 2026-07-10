import Foundation

public enum SessionError: Error {
    case fileUnreadable(URL)
    case fileWriteFailed(URL, String)
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
    public private(set) var fileURL: URL?
    /// Set when an external change lands while local edits are unsaved;
    /// the UI shows a non-blocking merge banner (handoff rule) instead of
    /// silently replacing.
    public var onConflict: (@Sendable (String) -> Void)?
    public private(set) var lastSaveError: SessionError?
    private var isDirty = false
    public var hasUnsavedChanges: Bool { isDirty }

    private var watcher: FileWatcher?
    private var continuations: [UUID: AsyncStream<QuoinDocument>.Continuation] = [:]
    /// Hash of content we ourselves just wrote, so the resulting file-system
    /// event is recognized as self-inflicted and not re-published.
    private var selfWriteHash: String?
    private var undoStack: [SourceEdit] = []
    private var redoStack: [SourceEdit] = []
    private var autosaveTask: Task<Void, Never>?
    /// Debounce for keystroke-driven autosave; checkbox toggles still write
    /// immediately.
    private let autosaveDelay: Duration = .milliseconds(400)

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

    public func setConflictHandler(_ handler: @escaping @Sendable (String) -> Void) {
        onConflict = handler
    }

    /// Called whenever a save (including debounced autosave) fails — a
    /// silent save failure in an app with no Save button is data loss on
    /// a timer (launch audit BLOCKER #2).
    public func setSaveFailureHandler(_ handler: @escaping @Sendable (String) -> Void) {
        onSaveFailure = handler
    }
    private var onSaveFailure: (@Sendable (String) -> Void)?

    /// Follows a file rename (first-H1-renames-file): future saves and
    /// watching target the new URL.
    public func relocate(to url: URL) {
        let wasWatching = watcher != nil
        stopWatching()
        fileURL = url
        if wasWatching { startWatching() }
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
        // Clean → reload silently. Dirty → surface a merge banner instead
        // of clobbering unsaved local edits. The pending autosave is
        // cancelled so it can't overwrite the disk version while the user
        // decides.
        if isDirty {
            autosaveTask?.cancel()
            onConflict?(source)
            return
        }
        publish(MarkdownConverter.parse(source))
    }

    /// Merge-banner resolution: overwrite disk with the local version.
    public func resolveConflictKeepingMine() throws {
        try saveNow()
    }

    /// Merge-banner resolution: adopt the on-disk version, discarding
    /// unsaved local edits.
    public func resolveConflictTakingDisk(_ diskSource: String) {
        isDirty = false
        lastSaveError = nil
        autosaveTask?.cancel()
        publish(MarkdownConverter.parse(diskSource))
    }

    /// Applies new source text wholesale (no undo tracking; external inputs).
    public func apply(source: String) {
        guard SHA256Hex.hash(of: source) != document.sourceHash else { return }
        publish(MarkdownConverter.parse(source))
    }

    // MARK: - Editing

    public var canUndo: Bool { !undoStack.isEmpty }
    public var canRedo: Bool { !redoStack.isEmpty }

    /// The editor's keystroke path: apply a byte-precise edit, re-parse,
    /// publish, and schedule a debounced autosave. Returns the new document
    /// so callers can restore the caret synchronously.
    @discardableResult
    public func applyEdit(_ edit: SourceEdit, publishSnapshot: Bool = true) throws -> QuoinDocument {
        let parsed = try MarkdownConverter.parseAfterEdit(previous: document, edit: edit)
        undoStack.append(parsed.inverse)
        redoStack.removeAll()
        if publishSnapshot {
            publish(parsed.document)
        } else {
            document = parsed.document
        }
        scheduleAutosave()
        return document
    }

    @discardableResult
    public func undo() throws -> QuoinDocument? {
        guard let edit = undoStack.popLast() else { return nil }
        let (newSource, inverse) = try edit.apply(to: document.source)
        redoStack.append(inverse)
        publish(MarkdownConverter.parse(newSource))
        scheduleAutosave()
        return document
    }

    @discardableResult
    public func redo() throws -> QuoinDocument? {
        guard let edit = redoStack.popLast() else { return nil }
        let (newSource, inverse) = try edit.apply(to: document.source)
        undoStack.append(inverse)
        publish(MarkdownConverter.parse(newSource))
        scheduleAutosave()
        return document
    }

    /// Autosave-in-place, debounced across bursts of keystrokes. The write
    /// is atomic and marked self-inflicted so the file watcher stays quiet.
    private func scheduleAutosave() {
        guard fileURL != nil else { return }
        isDirty = true
        autosaveTask?.cancel()
        autosaveTask = Task { [autosaveDelay] in
            try? await Task.sleep(for: autosaveDelay)
            guard !Task.isCancelled else { return }
            do {
                try await self.saveNow()
            } catch {
                // Retry once shortly (transient I/O), then tell the user —
                // never fail silently on the write path.
                try? await Task.sleep(for: .milliseconds(800))
                do {
                    try await self.saveNow()
                } catch {
                    await self.reportSaveFailure()
                }
            }
        }
    }

    private func reportSaveFailure() {
        guard let fileURL else { return }
        onSaveFailure?(
            "Couldn't save “\(fileURL.lastPathComponent)”. Your edits are held in memory — "
            + "check the disk or the file's permissions.")
    }

    public func saveNow() throws {
        guard let fileURL else { return }
        let source = document.source
        let wasDirty = isDirty
        do {
            try Data(source.utf8).write(to: fileURL, options: .atomic)
            selfWriteHash = SHA256Hex.hash(of: source)
            isDirty = false
            lastSaveError = nil
            autosaveTask?.cancel()
            autosaveTask = nil
        } catch {
            if wasDirty { isDirty = true }
            let failure = SessionError.fileWriteFailed(fileURL, String(describing: error))
            lastSaveError = failure
            throw failure
        }
    }

    /// Toggles a task checkbox and writes the change back to disk,
    /// byte-precise. If the file changed on disk since the last parse, it is
    /// re-read first and the toggle is re-validated against fresh content.
    public func toggleTask(markerRange: ByteRange) throws {
        let viewed = document

        // The offset the UI sent is only meaningful against the render the
        // user clicked. Capture *which* task that was (by label + ordinal)
        // before touching disk, so a shifted file can't reroute the toggle.
        guard let intended = TaskLocator.identify(offset: markerRange.offset, in: viewed) else {
            throw SessionError.taskNotTogglable
        }

        var base = viewed
        var effectiveRange = markerRange

        // Conflict rule: if disk moved under us, re-parse and re-anchor by
        // identity — never by the stale offset.
        if let fileURL,
           let data = try? Data(contentsOf: fileURL),
           let diskSource = String(data: data, encoding: .utf8),
           SHA256Hex.hash(of: diskSource) != viewed.sourceHash {
            let fresh = MarkdownConverter.parse(diskSource)
            guard let relocated = TaskLocator.relocate(intended, in: fresh) else {
                // Can't prove which task the user meant. Surface the current
                // truth so they re-click on accurate content, then refuse.
                publish(fresh)
                throw SessionError.taskNotTogglable
            }
            base = fresh
            effectiveRange = relocated
        }

        let newSource = try TaskToggler.toggle(source: base.source, markerRange: effectiveRange)

        if let fileURL {
            do {
                try Data(newSource.utf8).write(to: fileURL, options: .atomic)
                selfWriteHash = SHA256Hex.hash(of: newSource)
                lastSaveError = nil
            } catch {
                let failure = SessionError.fileWriteFailed(fileURL, String(describing: error))
                lastSaveError = failure
                throw failure
            }
        }
        publish(MarkdownConverter.parse(newSource))
    }
}
