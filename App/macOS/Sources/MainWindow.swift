import AppKit
import SwiftUI
import QuoinCore

/// The main window per the handoff: library sidebar (⌘0) · tab bar +
/// editor · outline inspector (⌥⌘0), with quick open (⇧⌘O) floating above.
struct MainWindow: View {
    @StateObject private var library = LibraryModel()

    @State private var sidebarSelection: URL?
    @State private var openTabs: [URL] = []
    @State private var activeTab: URL?
    @State private var isQuickOpenVisible = false
    @State private var isLibrarySearchVisible = false

    var body: some View {
        NavigationSplitView {
            if library.hasLibrary {
                LibrarySidebar(
                    library: library,
                    selection: $sidebarSelection,
                    isSearchVisible: $isLibrarySearchVisible
                ) { url in
                    open(url)
                }
                .navigationSplitViewColumnWidth(min: 200, ideal: 240, max: 320)
            } else {
                chooseLibraryPrompt
            }
        } detail: {
            VStack(spacing: 0) {
                DocumentTabBar(tabs: openTabs, activeTab: $activeTab) { url in
                    close(url)
                }
                if let activeTab {
                    // Keyed by URL: each document gets its own model/session.
                    ReaderScreen(fileURL: activeTab, initialText: "", onFileRenamed: { newURL in
                        if let index = openTabs.firstIndex(of: activeTab) {
                            openTabs[index] = newURL
                        }
                        self.activeTab = newURL
                        sidebarSelection = newURL
                        library.rescan()
                    })
                    .id(activeTab)
                } else {
                    emptyState
                }
            }
        }
        .overlay {
            if isQuickOpenVisible {
                Color.black.opacity(0.001) // click-away catcher
                    .onTapGesture { isQuickOpenVisible = false }
                QuickOpenPanel(library: library, isPresented: $isQuickOpenVisible) { url in
                    open(url)
                }
                .padding(.top, 80)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            }
        }
        .background(windowShortcuts)
        .onReceive(NotificationCenter.default.publisher(for: AppDelegate.openDocumentNotification)) { note in
            if let url = note.userInfo?["url"] as? URL {
                open(url)
            }
        }
        .onAppear(perform: applyShotState)
    }

    /// Screenshot automation: `-QuoinShotOpen name.md` opens a library file
    /// at launch; `-QuoinShotState quickopen|libsearch` presets window
    /// chrome. Deterministic state beats synthetic keyboard events on
    /// headless runners.
    private func applyShotState() {
        let defaults = UserDefaults.standard
        guard defaults.string(forKey: "QuoinShotOpen") != nil
                || defaults.string(forKey: "QuoinShotState") != nil else { return }

        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1)) // let the library scan land
            if let name = defaults.string(forKey: "QuoinShotOpen"), let root = library.rootURL {
                open(root.appendingPathComponent(name))
            }
            switch defaults.string(forKey: "QuoinShotState") {
            case "quickopen":
                isQuickOpenVisible = true
                library.quickOpenQuery = "show"
                try? await Task.sleep(for: .milliseconds(500))
                library.runQuickOpen()
            case "libsearch":
                isLibrarySearchVisible = true
                library.librarySearchQuery = "engine"
                try? await Task.sleep(for: .milliseconds(500))
                library.runLibrarySearch()
            default:
                break
            }
        }
    }

    // MARK: - Tabs

    private func open(_ url: URL) {
        if !openTabs.contains(url) {
            openTabs.append(url)
        }
        activeTab = url
        sidebarSelection = url
    }

    private func close(_ url: URL) {
        openTabs.removeAll { $0 == url }
        if activeTab == url {
            activeTab = openTabs.last
        }
    }

    // MARK: - Shortcuts (conflict-audited map from the handoff)

    private var windowShortcuts: some View {
        Group {
            Button("") { isQuickOpenVisible = true }
                .keyboardShortcut("o", modifiers: [.command, .shift])
            Button("") {
                if let url = library.createDocument() { open(url) }
            }
            .keyboardShortcut("n", modifiers: .command)
            Button("") {
                if let activeTab { close(activeTab) }
            }
            .keyboardShortcut("w", modifiers: .command)
            Button("") { isLibrarySearchVisible.toggle() }
                .keyboardShortcut("f", modifiers: [.command, .shift])
            // ⌘Z undoes sidebar file moves when no document is open;
            // with a document open, its edit-undo owns the shortcut.
            if activeTab == nil {
                Button("") { library.undoLastMove() }
                    .keyboardShortcut("z", modifiers: .command)
            }
            ForEach(1..<10) { index in
                Button("") {
                    if openTabs.indices.contains(index - 1) {
                        activeTab = openTabs[index - 1]
                    }
                }
                .keyboardShortcut(KeyEquivalent(Character("\(index)")), modifiers: .command)
            }
        }
        .opacity(0)
        .accessibilityHidden(true)
    }

    // MARK: - Empty states (per handoff §4)

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "doc.text")
                .font(.system(size: 44))
                .foregroundStyle(.primary.opacity(0.35))
            Text("No document open")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.primary.opacity(0.55))
            Text("Select a document, or press ⌘N")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            Button("New Document") {
                if let url = library.createDocument() { open(url) }
            }
            .buttonStyle(.bordered)
            .tint(.accentColor)
            .padding(.top, 6)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var chooseLibraryPrompt: some View {
        VStack(spacing: 10) {
            Image(systemName: "folder.badge.plus")
                .font(.system(size: 36))
                .foregroundStyle(.primary.opacity(0.35))
            Text("Choose a library folder")
                .font(.system(size: 13, weight: .semibold))
            Text("Your documents stay plain .md files on disk.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            Button("Choose Folder…") {
                library.chooseLibraryFolder()
            }
            .buttonStyle(.borderedProminent)
            .padding(.top, 6)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }
}
