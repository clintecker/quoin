import AppKit
import SwiftUI
import QuoinCore

/// The main window per the handoff: library sidebar (⌘0) · tab bar +
/// editor · outline inspector (⌥⌘0), with quick open (⇧⌘O) floating above.
struct MainWindow: View {
    @State private var library = LibraryModel()

    @State private var sidebarSelection: URL?
    @State private var openTabs: [URL] = []
    @State private var activeTab: URL?
    @State private var isQuickOpenVisible = false
    @State private var isLibrarySearchVisible = false
    @State private var columnVisibility: NavigationSplitViewVisibility = .all

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
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
        // ⌘0 / View ▸ Show/Hide Sidebar (handoff keyboard map).
        .onReceive(NotificationCenter.default.publisher(for: AppDelegate.toggleSidebarNotification)) { _ in
            withAnimation {
                columnVisibility = columnVisibility == .detailOnly ? .all : .detailOnly
            }
        }
        // Help ▸ Markdown Guide / Welcome to Quoin: LIVE documents in the
        // library (editable examples — the guide teaches by being edited).
        .onReceive(NotificationCenter.default.publisher(for: AppDelegate.openGuideNotification)) { _ in
            if let url = library.materializeBundledDocument(
                resource: "MarkdownGuide", as: "Markdown Guide.md") { open(url) }
        }
        .onReceive(NotificationCenter.default.publisher(for: AppDelegate.openWelcomeNotification)) { _ in
            if let url = library.materializeBundledDocument(
                resource: "WelcomeToQuoin", as: "Welcome to Quoin.md") { open(url) }
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
        // Reveal in the tree: expand ancestor folders so the selection is
        // visible when the doc was opened via quick open or Finder.
        library.reveal(url: url)
        // Feeds quick open's empty-query recents (idea #13).
        library.recordOpen(url)
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
            // Today's note: Journal/YYYY-MM-DD.md (idea #14).
            Button("") {
                if let url = library.dailyNote() { open(url) }
            }
            .keyboardShortcut("d", modifiers: .command)
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
            HStack(spacing: 16) {
                Button("Welcome to Quoin") {
                    if let url = library.materializeBundledDocument(
                        resource: "WelcomeToQuoin", as: "Welcome to Quoin.md") { open(url) }
                }
                Button("Markdown Guide") {
                    if let url = library.materializeBundledDocument(
                        resource: "MarkdownGuide", as: "Markdown Guide.md") { open(url) }
                }
            }
            .buttonStyle(.link)
            .font(.system(size: 11))
            .padding(.top, 2)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var chooseLibraryPrompt: some View {
        VStack(spacing: 10) {
            Image(systemName: "folder.badge.plus")
                .font(.system(size: 36))
                .foregroundStyle(.primary.opacity(0.35))
            Text("Where should your documents live?")
                .font(.system(size: 13, weight: .semibold))
            Text("Your documents stay plain .md files on disk.\nQuoin never converts or moves your files.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            // First frame of the real app should be a beautiful rendered
            // document, not an empty tree (launch ledger L1).
            Button("Create a Starter Library") {
                if let welcome = library.createStarterLibrary() { open(welcome) }
            }
            .buttonStyle(.borderedProminent)
            .padding(.top, 6)
            Button("Choose an Existing Folder…") {
                library.chooseLibraryFolder()
            }
            .buttonStyle(.bordered)
            Text("A library is just a folder — every document stays a plain file you can open anywhere.")
                .font(.system(size: 10.5))
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 300)
                .padding(.top, 4)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }
}
