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

    private var accessedURL: URL?

    init() {
        restoreBookmark()
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

    func move(url: URL, into folder: URL) -> URL? {
        guard let moved = try? Library.move(url, into: folder) else { return nil }
        rescan()
        return moved
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
