import AppKit
import SwiftUI
import QuoinCore

/// The main window per the handoff: library sidebar (⌘0) · tab bar +
/// editor · outline inspector (⌥⌘0), with quick open (⇧⌘O) floating above.
struct MainWindow: View {
    @State private var library = LibraryModel()

    @State private var sidebarSelection: URL?
    @State private var openTabs: [DocumentTab] = []
    @State private var activeTabID: DocumentTab.ID?
    /// Workspace memory (UI #4): open tabs survive relaunch. First line
    /// is the active tab's path, the rest are the tab order.
    @SceneStorage("QuoinOpenTabs") private var persistedTabs = ""

    private var activeTab: DocumentTab? {
        openTabs.first { $0.id == activeTabID }
    }
    @State private var isQuickOpenVisible = false
    @State private var isLibrarySearchVisible = false
    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    /// Menu actions must land in the KEY window only — every observer
    /// below guards on this (launch ledger BLOCKER: two windows used to
    /// both undo/export on one menu click).
    @Environment(\.controlActiveState) private var controlActiveState

    private var isKeyWindow: Bool { controlActiveState == .key }

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
                // Onboarding lives in the DETAIL pane (below) where there's
                // room; the sidebar stays quiet until a library exists.
                VStack(spacing: 6) {
                    Image(systemName: "books.vertical")
                        .foregroundStyle(.tertiary)
                    Text("No library yet")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        } detail: {
            VStack(spacing: 0) {
                if !library.hasLibrary {
                    chooseLibraryPrompt
                } else {
                    DocumentTabBar(tabs: openTabs, activeTabID: $activeTabID) { tab in
                        close(tab)
                    }
                    if let tab = activeTab {
                        // Keyed by the tab's STABLE identity, not the URL —
                        // a first-H1 rename used to tear down the live
                        // editor mid-typing (ledger senior #13).
                        ReaderScreen(fileURL: tab.url, initialText: "", onFileRenamed: { newURL in
                            if let index = openTabs.firstIndex(where: { $0.id == tab.id }) {
                                openTabs[index].url = newURL
                            }
                            sidebarSelection = newURL
                            library.rescan()
                        })
                        .id(tab.id)
                    } else {
                        emptyState
                    }
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
            guard isKeyWindow else { return }
            if let url = note.userInfo?["url"] as? URL {
                open(url)
            }
        }
        // ⌘0 / View ▸ Show/Hide Sidebar (handoff keyboard map).
        .onReceive(NotificationCenter.default.publisher(for: AppDelegate.toggleSidebarNotification)) { _ in
            guard isKeyWindow else { return }
            withAnimation {
                columnVisibility = columnVisibility == .detailOnly ? .all : .detailOnly
            }
        }
        // File ▸ New Document (⌘N).
        .onReceive(NotificationCenter.default.publisher(for: AppDelegate.newDocumentNotification)) { _ in
            guard isKeyWindow else { return }
            if let url = library.createDocument() { open(url) }
        }
        // File ▸ Close Tab (⌘W).
        .onReceive(NotificationCenter.default.publisher(for: AppDelegate.closeTabNotification)) { _ in
            guard isKeyWindow, let tab = activeTab else { return }
            close(tab)
        }
        // File ▸ Open… (⌘O): native panel, markdown files only.
        .onReceive(NotificationCenter.default.publisher(for: AppDelegate.openFilePanelNotification)) { _ in
            guard isKeyWindow else { return }
            presentOpenPanel()
        }
        // File ▸ Change Library Folder….
        .onReceive(NotificationCenter.default.publisher(for: AppDelegate.changeLibraryNotification)) { _ in
            guard isKeyWindow else { return }
            library.chooseLibraryFolder()
        }
        // Go ▸ Quick Open (⇧⌘O) / Daily Note (⌘D).
        .onReceive(NotificationCenter.default.publisher(for: AppDelegate.toggleQuickOpenNotification)) { _ in
            guard isKeyWindow else { return }
            isQuickOpenVisible.toggle()
        }
        .onReceive(NotificationCenter.default.publisher(for: AppDelegate.dailyNoteNotification)) { _ in
            guard isKeyWindow else { return }
            if let url = library.dailyNote() { open(url) }
        }
        // Edit ▸ Find ▸ Search Library (⇧⌘F).
        .onReceive(NotificationCenter.default.publisher(for: AppDelegate.toggleLibrarySearchNotification)) { _ in
            guard isKeyWindow else { return }
            isLibrarySearchVisible.toggle()
        }
        // A trashed document's tabs close in EVERY window (deliberately
        // not key-gated) — a live session would autosave into the Trash.
        .onReceive(NotificationCenter.default.publisher(for: LibraryModel.documentTrashedNotification)) { note in
            if let url = note.userInfo?["url"] as? URL {
                openTabs.removeAll { $0.url == url || $0.url.path.hasPrefix(url.path + "/") }
                if activeTab == nil {
                    activeTabID = openTabs.last?.id
                }
            }
        }
        // Help ▸ Markdown Guide / Welcome to Quoin: LIVE documents in the
        // library (editable examples — the guide teaches by being edited).
        .onReceive(NotificationCenter.default.publisher(for: AppDelegate.openGuideNotification)) { _ in
            guard isKeyWindow else { return }
            if let url = library.materializeBundledDocument(
                resource: "MarkdownGuide", as: "Markdown Guide.md") { open(url) }
        }
        .onReceive(NotificationCenter.default.publisher(for: AppDelegate.openWelcomeNotification)) { _ in
            guard isKeyWindow else { return }
            if let url = library.materializeBundledDocument(
                resource: "WelcomeToQuoin", as: "Welcome to Quoin.md") { open(url) }
        }
        .onAppear {
            restoreTabs()
            applyShotState()
        }
        .onChange(of: openTabs) { persistTabs() }
        .onChange(of: activeTabID) { persistTabs() }
        // Sidebar keyboard selection (↑/↓ + the List's type-select) opens
        // documents, not just mouse clicks (UI #23). open() re-sets the
        // selection to the same URL, so this settles after one pass.
        .onChange(of: sidebarSelection) { _, url in
            if let url, url.pathExtension.lowercased() == "md", activeTab?.url != url {
                open(url)
            }
        }
    }

    // MARK: - Workspace persistence (UI #4)

    private func persistTabs() {
        persistedTabs = ([activeTab?.url.path ?? ""] + openTabs.map(\.url.path)).joined(separator: "\n")
    }

    /// Restores tabs from the last session. Only files reachable through
    /// the library's security scope come back — a sandboxed relaunch has
    /// no access to one-off files that were opened via the panel.
    private func restoreTabs() {
        guard openTabs.isEmpty, !persistedTabs.isEmpty,
              let rootPath = library.rootURL?.standardizedFileURL.path else { return }
        let lines = persistedTabs.components(separatedBy: "\n")
        guard lines.count > 1 else { return }
        let restored = lines.dropFirst()
            .filter { $0.hasPrefix(rootPath + "/") && FileManager.default.fileExists(atPath: $0) }
            .map { DocumentTab(url: URL(fileURLWithPath: $0)) }
        guard !restored.isEmpty else { return }
        openTabs = restored
        let activePath = lines[0]
        let active = restored.first { $0.url.path == activePath } ?? restored.last
        activeTabID = active?.id
        if let active {
            sidebarSelection = active.url
            library.reveal(url: active.url)
        }
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
        if let existing = openTabs.first(where: { $0.url == url }) {
            activeTabID = existing.id
        } else {
            let tab = DocumentTab(url: url)
            openTabs.append(tab)
            activeTabID = tab.id
        }
        sidebarSelection = url
        // Reveal in the tree: expand ancestor folders so the selection is
        // visible when the doc was opened via quick open or Finder.
        library.reveal(url: url)
        // Feeds quick open's empty-query recents (idea #13) + the system's
        // recents (dock menu, Spotlight "recent items").
        library.recordOpen(url)
        NSDocumentController.shared.noteNewRecentDocumentURL(url)
    }

    private func close(_ tab: DocumentTab) {
        openTabs.removeAll { $0.id == tab.id }
        if activeTabID == tab.id {
            activeTabID = openTabs.last?.id
        }
    }

    /// File ▸ Open…: markdown files anywhere on disk; each becomes a tab.
    private func presentOpenPanel() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = [.markdownDocument, .plainText]
        guard panel.runModal() == .OK else { return }
        for url in panel.urls where url.pathExtension.lowercased() == "md" {
            open(url)
        }
    }

    // MARK: - Shortcuts (conflict-audited map from the handoff)

    /// Only what has no menu-bar home: tab switching (⌘1–9) and the
    /// no-document sidebar-move undo. Everything else moved into REAL
    /// menus (File/Edit/View/Go/Format — QuoinApp.commands).
    private var windowShortcuts: some View {
        Group {
            // ⌘Z undoes sidebar file moves when no document is open;
            // with a document open, its edit-undo owns the shortcut.
            if activeTabID == nil {
                Button("") { library.undoLastMove() }
                    .keyboardShortcut("z", modifiers: .command)
            }
            ForEach(1..<10) { index in
                Button("") {
                    if openTabs.indices.contains(index - 1) {
                        activeTabID = openTabs[index - 1].id
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
