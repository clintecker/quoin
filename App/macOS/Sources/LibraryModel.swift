import AppKit
import Foundation
import SwiftUI
import QuoinCore

/// Owns the library: the user-picked root folder (persisted as a
/// security-scoped bookmark), the scanned tree, and file operations.
@MainActor
final class LibraryModel: ObservableObject {

    private static let bookmarkKey = "quoin.library.bookmark"

    @Published private(set) var root: LibraryNode?
    @Published private(set) var rootURL: URL?
    @Published var quickOpenQuery = ""
    @Published private(set) var quickOpenResults: [QuickOpen.Result] = []
    /// Persistent library-wide search (⇧⌘F) shown in the sidebar.
    @Published var librarySearchQuery = ""
    @Published private(set) var librarySearchResults: [QuickOpen.Result] = []
    /// Expanded folders in the tree (standardized paths). `reveal(url:)`
    /// expands a document's ancestors so opening via quick open or Finder
    /// shows the selection.
    @Published var expandedFolders: Set<String> = []

    /// Expand every ancestor folder of `url` up to the library root.
    func reveal(url: URL) {
        guard let rootURL else { return }
        let rootPath = rootURL.standardizedFileURL.path
        var directory = url.deletingLastPathComponent().standardizedFileURL
        while directory.path.hasPrefix(rootPath), directory.path != rootPath {
            expandedFolders.insert(directory.path)
            directory = directory.deletingLastPathComponent()
        }
    }

    private var accessedURL: URL?
    private var eventsWatcher: FSEventsWatcher?
    /// Inverse file moves for ⌘Z (design rule: sidebar moves are undoable).
    private var moveUndoStack: [(from: URL, to: URL)] = []

    init() {
        // `-QuoinLibraryPath /path` (launch argument → UserDefaults) bypasses
        // the folder picker — used by UI tests/screenshot automation and
        // handy for local development.
        if let path = UserDefaults.standard.string(forKey: "QuoinLibraryPath") {
            adopt(rootURL: URL(fileURLWithPath: path, isDirectory: true))
        } else {
            restoreBookmark()
        }
    }

    deinit {
        accessedURL?.stopAccessingSecurityScopedResource()
    }

    var hasLibrary: Bool { rootURL != nil }

    // MARK: - Root folder

    func chooseLibraryFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.message = "Choose the folder that holds your markdown documents."
        panel.prompt = "Use as Library"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        adopt(rootURL: url)
        if let bookmark = try? url.bookmarkData(
            options: .withSecurityScope,
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        ) {
            UserDefaults.standard.set(bookmark, forKey: Self.bookmarkKey)
        }
    }

    private func restoreBookmark() {
        guard let data = UserDefaults.standard.data(forKey: Self.bookmarkKey) else { return }
        var stale = false
        guard let url = try? URL(
            resolvingBookmarkData: data,
            options: .withSecurityScope,
            relativeTo: nil,
            bookmarkDataIsStale: &stale
        ) else { return }
        adopt(rootURL: url)
        if stale, let refreshed = try? url.bookmarkData(
            options: .withSecurityScope,
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        ) {
            UserDefaults.standard.set(refreshed, forKey: Self.bookmarkKey)
        }
    }

    private func adopt(rootURL url: URL) {
        accessedURL?.stopAccessingSecurityScopedResource()
        _ = url.startAccessingSecurityScopedResource()
        accessedURL = url
        rootURL = url
        rescan()
        // Keep the sidebar live for external changes (Finder, sync, other
        // editors). FSEvents debounces internally.
        eventsWatcher = FSEventsWatcher(url: url) { [weak self] in
            self?.rescan()
            if let self, !self.librarySearchQuery.isEmpty {
                self.runLibrarySearch()
            }
        }
    }

    // MARK: - Tree

    func rescan() {
        guard let rootURL else { return }
        // Scanning is fast (directory metadata only) but not free; keep it
        // off the main actor for large libraries.
        Task.detached(priority: .userInitiated) { [weak self] in
            let tree = Library.scan(root: rootURL)
            await MainActor.run { self?.root = tree }
        }
    }

    var documentCount: Int { root?.documentCount ?? 0 }

    // MARK: - File operations

    func rename(url: URL, to newName: String) -> URL? {
        guard let renamed = try? Library.rename(url, to: newName) else { return nil }
        rescan()
        return renamed
    }

    /// Sidebar drag-to-move: a real file move, recorded for ⌘Z.
    @discardableResult
    func move(url: URL, into folder: URL) -> URL? {
        guard url.deletingLastPathComponent() != folder,
              folder != url, // no folder-into-itself
              let moved = try? Library.move(url, into: folder)
        else { return nil }
        moveUndoStack.append((from: moved, to: url.deletingLastPathComponent()))
        rescan()
        return moved
    }

    var canUndoMove: Bool { !moveUndoStack.isEmpty }

    /// Undoes the most recent sidebar move (moves the file back on disk).
    func undoLastMove() {
        guard let last = moveUndoStack.popLast() else { return }
        _ = try? Library.move(last.from, into: last.to)
        rescan()
    }

    // MARK: - Library-wide search (⇧⌘F)

    func runLibrarySearch() {
        guard let root else {
            librarySearchResults = []
            return
        }
        let query = librarySearchQuery
        guard !query.trimmingCharacters(in: .whitespaces).isEmpty else {
            librarySearchResults = []
            return
        }
        Task.detached(priority: .userInitiated) { [weak self] in
            let results = QuickOpen.search(query: query, in: root, maxResults: 40)
            await MainActor.run {
                guard let self, self.librarySearchQuery == query else { return }
                self.librarySearchResults = results
            }
        }
    }

    /// New untitled document in the library root (design: first H1 renames
    /// the file live once the editor supports it).
    func createDocument(in folder: URL? = nil) -> URL? {
        guard let target = folder ?? rootURL else { return nil }
        var name = "Untitled"
        var candidate = target.appendingPathComponent(name).appendingPathExtension("md")
        var counter = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            name = "Untitled \(counter)"
            candidate = target.appendingPathComponent(name).appendingPathExtension("md")
            counter += 1
        }
        guard (try? Data("".utf8).write(to: candidate)) != nil else { return nil }
        rescan()
        return candidate
    }

    // MARK: - Quick open

    func runQuickOpen() {
        guard let root else {
            quickOpenResults = []
            return
        }
        let query = quickOpenQuery
        Task.detached(priority: .userInitiated) { [weak self] in
            let results = QuickOpen.search(query: query, in: root)
            await MainActor.run {
                guard let self, self.quickOpenQuery == query else { return }
                self.quickOpenResults = results
            }
        }
    }
}
