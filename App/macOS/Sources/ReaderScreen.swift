import AppKit
import SwiftUI
import UniformTypeIdentifiers
import QuoinCore
import QuoinRender

/// One document window, laid out per the design handoff: editor center
/// (max 680pt column), outline panel as a trailing inspector (⌥⌘0),
/// find bar, and a status bar with section + live statistics.
/// The library sidebar arrives in Phase D.
struct ReaderScreen: View {
    let fileURL: URL?
    let initialText: String
    var onFileRenamed: (URL) -> Void = { _ in }

    @State private var model = ReaderModel()
    /// Fresh per body evaluation: `Theme()` captures the CURRENT appearance,
    /// and reading `colorScheme` below is what makes SwiftUI re-evaluate
    /// this view when the appearance flips (system or Settings preference).
    private var theme: Theme { Theme() }
    @Environment(\.colorScheme) private var colorScheme
    @AppStorage("QuoinShowStatusBar") private var showStatusBar = true

    @State private var formatCommand: FormatCommand?
    @State private var formatGeneration = 0
    @State private var editSourceToggleGeneration = 0

    @State private var isOutlineVisible = true
    @State private var isExportVisible = false
    /// Focus mode: everything but the paragraph you're on recedes.
    @AppStorage("QuoinFocusMode") private var isFocusMode = false
    /// Typewriter scrolling: the caret line holds a fixed height.
    @AppStorage("QuoinTypewriter") private var isTypewriter = false
    /// Sentence-granularity focus (only meaningful with focus mode on).
    @AppStorage("QuoinFocusSentence") private var isSentenceFocus = false
    /// Word-count goal (0 = off): progress shows in the status bar.
    @AppStorage("QuoinWordGoal") private var wordGoal = 0
    /// Jump history (TOC clicks, anchor links, breadcrumbs): ⌘[ / ⌘].
    @State private var backStack: [BlockID] = []
    @State private var forwardStack: [BlockID] = []
    /// Reading progress, 0…1 (hairline under the toolbar).
    @State private var scrollProgress: Double = 0
    @State private var isFindVisible = false
    @State private var searchQuery = ""
    @State private var activeMatch = 0
    @State private var matchCount = 0
    @State private var scrollTarget: BlockID?
    @State private var scrollGeneration = 0
    @State private var topBlockID: BlockID?
    @FocusState private var findFieldFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            if isFindVisible {
                findBar
            }
            if model.conflictDiskSource != nil {
                conflictBanner
            }
            if let failure = model.actionFailure {
                actionFailureBanner(failure)
            }
            ZStack(alignment: .topTrailing) {
            MarkdownReaderView(
                rendered: model.rendered,
                theme: theme,
                searchQuery: isFindVisible ? searchQuery : "",
                activeMatchOrdinal: activeMatch,
                scrollTarget: scrollTarget,
                scrollGeneration: scrollGeneration,
                onTaskToggle: { offset in model.toggleTask(markerOffset: offset) },
                onMatchCount: { count in
                    matchCount = count
                    if activeMatch >= count { activeMatch = 0 }
                },
                anchorResolver: { slug in model.blockID(forSlug: slug) },
                onTopBlockChange: { top in topBlockID = top },
                onEditIntent: { range, replacement, caretDelta in
                    model.applyEdit(relativeRange: range, replacement: replacement, caretDelta: caretDelta)
                },
                onActivateBlock: { id, caretHint, pendingInsertion in
                    model.activateBlock(id, caretHint: caretHint, pendingInsertion: pendingInsertion)
                },
                caretInActiveBlock: model.caretInActiveBlock,
                caretGeneration: model.caretGeneration,
                formatCommand: formatCommand,
                formatGeneration: formatGeneration,
                editSourceToggleGeneration: editSourceToggleGeneration,
                blockSourceProvider: { id in
                    model.document.blocks.first { $0.id == id }
                        .flatMap { model.document.source.substring(in: $0.range) }
                },
                focusModeEnabled: isFocusMode,
                typewriterEnabled: isTypewriter,
                onAnchorJump: { from in recordJump(from: from) },
                onScrollProgress: { progress in scrollProgress = progress },
                onBlockCommand: { id, command in model.perform(command, on: id) },
                focusSentenceScope: isSentenceFocus
            )
            // Dropping an image file copies it into assets/ and inserts
            // the markdown reference at the caret.
            .onDrop(of: [.fileURL], isTargeted: nil) { providers in
                var handled = false
                for provider in providers where provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                    handled = true
                    provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                        let url: URL?
                        if let data = item as? Data {
                            url = URL(dataRepresentation: data, relativeTo: nil)
                        } else {
                            url = item as? URL
                        }
                        guard let url,
                              ReaderModel.imageExtensions.contains(url.pathExtension.lowercased())
                        else { return }
                        Task { @MainActor in model.insertImage(from: url) }
                    }
                }
                return handled
            }
            // Format pill (handoff: B/I/U, radius 14, hairline border,
            // floats over the content at the top of the editor).
            formatPill
                .padding(.top, 10)
                .padding(.trailing, 16)
            }
            if showStatusBar {
                statusBar
            }
        }
        .onChange(of: colorScheme) {
            // Appearance flipped (system or the Settings preference): the
            // rendered projection has the old palette baked into its
            // attributed string, so the model must re-render with a fresh
            // Theme.
            model.refreshTheme()
        }
        .inspector(isPresented: $isOutlineVisible) {
            OutlinePanel(
                outline: model.outline,
                currentSectionID: currentSection?.id
            ) { headingID in
                jump(to: headingID)
            }
            .inspectorColumnWidth(min: 180, ideal: 220, max: 320)
        }
        // Reading progress hairline (idea #12): a quiet accent line along
        // the editor's top edge, width = scroll fraction.
        .overlay(alignment: .top) {
            GeometryReader { proxy in
                Rectangle()
                    .fill(Color.accentColor.opacity(0.35))
                    .frame(width: proxy.size.width * scrollProgress, height: 2)
            }
            .frame(height: 2)
            .allowsHitTesting(false)
        }
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button {
                    isFocusMode.toggle()
                } label: {
                    Label("Focus", systemImage: isFocusMode ? "scope" : "circle.dashed")
                }
                .help(isFocusMode ? "Leave focus mode (⌥⌘F)" : "Focus mode: dim everything but the current paragraph (⌥⌘F)")
                Button {
                    isExportVisible = true
                } label: {
                    Label("Export", systemImage: "square.and.arrow.up")
                }
                .help("Export as Markdown, HTML, or PDF (⇧⌘E)")
                Button {
                    isOutlineVisible.toggle()
                } label: {
                    Label("Outline", systemImage: "sidebar.trailing")
                }
                .help("Show or hide the outline (⌥⌘0)")
            }
        }
        .sheet(isPresented: $isExportVisible) {
            ExportSheet(
                documentName: fileURL?.deletingPathExtension().lastPathComponent ?? "Untitled",
                document: model.document,
                isPresented: $isExportVisible
            )
        }
        .navigationTitle((model.fileURL ?? fileURL)?.deletingPathExtension().lastPathComponent ?? "Untitled")
        .onAppear {
            model.onFileRenamed = onFileRenamed
            model.start(fileURL: fileURL, initialText: initialText)
            // Screenshot automation presets (see MainWindow.applyShotState).
            switch UserDefaults.standard.string(forKey: "QuoinShotState") {
            case "find":
                isFindVisible = true
                searchQuery = "math"
            case "export":
                Task { @MainActor in
                    try? await Task.sleep(for: .seconds(1))
                    isExportVisible = true
                }
            case "mermaidResilience":
                // Self-driving repro for the live-preview resilience loop
                // (ledger #6/#8 family): open the first chart's source,
                // break its header, then fix it — with QUOIN_EDIT_PERF_LOG
                // the panel.update traces record what the panel actually
                // showed at each step.
                Task { @MainActor in
                    try? await Task.sleep(for: .seconds(2))
                    guard let block = model.document.blocks.first(where: {
                        if case .mermaid = $0.kind { return true }
                        return false
                    }) else { return }
                    model.activateBlock(block.id, caretHint: .source(0))
                    try? await Task.sleep(for: .seconds(1.5))
                    guard let active = model.activeBlockID,
                          let activeBlock = model.document.blocks.first(where: { $0.id == active }),
                          let slice = model.document.source.substring(in: activeBlock.range),
                          let range = slice.range(of: "flowchart")
                    else { return }
                    let byteOffset = slice[..<range.lowerBound].utf8.count
                    model.applyEdit(relativeRange: ByteRange(offset: byteOffset, length: 0), replacement: "@@@")
                    try? await Task.sleep(for: .seconds(2))
                    model.applyEdit(relativeRange: ByteRange(offset: byteOffset, length: 3), replacement: "")
                }
            default:
                break
            }
        }
        .onDisappear { model.stop() }
        // ⌥⌘0 / View ▸ Show/Hide Outline (menu command, handoff keyboard map).
        .onReceive(NotificationCenter.default.publisher(for: AppDelegate.toggleOutlineNotification)) { _ in
            isOutlineVisible.toggle()
        }
        // ⌘↩ / Format ▸ Edit Source (embed-editing keyboard grammar).
        .onReceive(NotificationCenter.default.publisher(for: AppDelegate.toggleEditSourceNotification)) { _ in
            editSourceToggleGeneration += 1
        }
        // Format menu (⌘B/⌘I/⇧⌘H/⌘K) → the selection formatter.
        .onReceive(NotificationCenter.default.publisher(for: AppDelegate.formatNotification)) { note in
            switch note.userInfo?["format"] as? String {
            case "bold": fireFormat(.bold)
            case "italic": fireFormat(.italic)
            case "highlight": fireFormat(.highlight)
            case "link": fireFormat(.link)
            default: break
            }
        }
        // Edit ▸ Undo/Redo → the document session's undo stack.
        .onReceive(NotificationCenter.default.publisher(for: AppDelegate.undoNotification)) { _ in
            model.undo()
        }
        .onReceive(NotificationCenter.default.publisher(for: AppDelegate.redoNotification)) { _ in
            model.redo()
        }
        // File ▸ Export… (⇧⌘E).
        .onReceive(NotificationCenter.default.publisher(for: AppDelegate.exportNotification)) { _ in
            isExportVisible = true
        }
        // View ▸ Toggle Focus Mode (⌥⌘F).
        .onReceive(NotificationCenter.default.publisher(for: AppDelegate.toggleFocusModeNotification)) { _ in
            isFocusMode.toggle()
        }
        // View ▸ Typewriter Scrolling (⌥⌘T).
        .onReceive(NotificationCenter.default.publisher(for: AppDelegate.toggleTypewriterNotification)) { _ in
            isTypewriter.toggle()
        }
        // View ▸ Sentence Focus (granularity for focus mode).
        .onReceive(NotificationCenter.default.publisher(for: AppDelegate.toggleSentenceFocusNotification)) { _ in
            isSentenceFocus.toggle()
        }
        // Lets the Format menu title follow the editing state.
        .focusedSceneValue(\.quoinIsEditingBlock, model.activeBlockID != nil)
        .background(hiddenShortcuts)
    }

    // MARK: - Format pill (B/I/U + link, floats over the editor)

    /// The format pill acts on the block you're editing (bold/italic wrap the
    /// selection, or the word under the caret). Until a block is active it has
    /// nothing to act on, so it dims to read as contextual, not broken.
    private var isEditingBlock: Bool { model.activeBlockID != nil }

    private var formatPill: some View {
        HStack(spacing: 2) {
            formatPillButton("bold", command: .bold, help: "Bold (⌘B)")
            formatPillButton("italic", command: .italic, help: "Italic (⌘I)")
            formatPillButton("highlighter", command: .highlight, help: "Highlight (⇧⌘H)")
            Divider()
                .frame(height: 14)
                .padding(.horizontal, 2)
            formatPillButton("link", command: .link, help: "Link (⌘K)")
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: 14)
                .fill(Color(nsColor: .textBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .strokeBorder(Color.primary.opacity(0.12), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.08), radius: 3, y: 1)
        .opacity(isEditingBlock ? 1 : 0.45)
        .animation(.easeInOut(duration: 0.15), value: isEditingBlock)
        .help(isEditingBlock ? "" : "Click into text to format it")
    }

    private func formatPillButton(_ symbol: String, command: FormatCommand, help: String) -> some View {
        Button {
            fireFormat(command)
        } label: {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 22, height: 18)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!isEditingBlock)
        .help(help)
    }

    /// The heading governing the top of the viewport.
    private var currentSection: HeadingInfo? {
        guard let topBlockID,
              let topRange = model.rendered.blockRanges[topBlockID] else { return model.outline.first }
        var current: HeadingInfo?
        for heading in model.outline {
            guard let headingRange = model.rendered.blockRanges[heading.id] else { continue }
            if headingRange.location <= topRange.location {
                current = heading
            } else {
                break
            }
        }
        return current ?? model.outline.first
    }

    // MARK: - Keyboard map (conflict-audited; never override ⌘P/⌘E/⌘H)

    private var hiddenShortcuts: some View {
        Group {
            Button("") { openFind() }
                .keyboardShortcut("f", modifiers: .command)
            Button("") { nextMatch() }
                .keyboardShortcut("g", modifiers: .command)
            Button("") { previousMatch() }
                .keyboardShortcut("g", modifiers: [.command, .shift])
            // ⌘0/⌥⌘0/⌥⌘F, ⌘Z/⇧⌘Z, ⌘B/I/⇧⌘H/⌘K, and ⇧⌘E now live in REAL
            // menus (View/Edit/Format/File — QuoinApp.commands); only the
            // find family and print stay window-local.
            // Jump history (idea #7).
            Button("") { goBack() }
                .keyboardShortcut("[", modifiers: .command)
            Button("") { goForward() }
                .keyboardShortcut("]", modifiers: .command)
            // ⌘P keeps its system meaning: print.
            Button("") {
                DocumentExporters.runPrintOperation(
                    for: model.document,
                    jobTitle: fileURL?.deletingPathExtension().lastPathComponent ?? "Quoin Document"
                )
            }
            .keyboardShortcut("p", modifiers: .command)
        }
        .opacity(0)
        .accessibilityHidden(true)
    }

    private func fireFormat(_ command: FormatCommand) {
        formatCommand = command
        formatGeneration += 1
    }

    // MARK: - Jump history (idea #7): ⌘[ back, ⌘] forward

    /// Record the pre-jump position; any new jump clears the forward stack.
    private func recordJump(from: BlockID?) {
        guard let from else { return }
        backStack.append(from)
        forwardStack.removeAll()
    }

    /// Navigate to a heading, recording history (TOC, breadcrumb).
    private func jump(to id: BlockID) {
        recordJump(from: topBlockID)
        scrollTarget = id
        scrollGeneration += 1
    }

    private func goBack() {
        guard let target = backStack.popLast() else { return }
        if let here = topBlockID { forwardStack.append(here) }
        scrollTarget = target
        scrollGeneration += 1
    }

    private func goForward() {
        guard let target = forwardStack.popLast() else { return }
        if let here = topBlockID { backStack.append(here) }
        scrollTarget = target
        scrollGeneration += 1
    }

    /// The ancestor chain of the current section (H1 › H2 › …), for the
    /// status-bar breadcrumb (idea #6).
    private var breadcrumb: [HeadingInfo] {
        guard let current = currentSection else { return [] }
        var path: [HeadingInfo] = [current]
        var level = current.level
        guard let index = model.outline.firstIndex(where: { $0.id == current.id }) else { return path }
        for heading in model.outline[..<index].reversed() where heading.level < level {
            path.insert(heading, at: 0)
            level = heading.level
        }
        return path
    }

    // MARK: - Merge banner (non-blocking, per handoff)

    private var conflictBanner: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                Text("This file changed on disk while you had unsaved edits.")
                    .font(.system(size: 12))
                Spacer()
                Button("Keep Mine") { model.resolveConflictKeepingMine() }
                Button("Use Disk Version") { model.resolveConflictTakingDisk() }
            }
            .buttonStyle(.borderless)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Color.orange.opacity(0.08))
            Divider()
        }
    }

    // MARK: - Action failure banner (non-blocking, auto-dismissing)

    private func actionFailureBanner(_ failure: ReaderModel.ActionFailure) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "exclamationmark.circle.fill")
                    .foregroundStyle(.red)
                Text(failure.message)
                    .font(.system(size: 12))
                Spacer()
                Button {
                    model.dismissActionFailure()
                } label: {
                    Image(systemName: "xmark")
                }
                .help("Dismiss")
            }
            .buttonStyle(.borderless)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Color.red.opacity(0.08))
            Divider()
        }
        .transition(.move(edge: .top).combined(with: .opacity))
    }

    // MARK: - Status bar (10.5pt mono, 40% ink, top hairline)

    private var statusBar: some View {
        VStack(spacing: 0) {
            Divider()
            HStack {
                // Breadcrumb (idea #6): the current section as a clickable
                // ancestor path — jump to any level.
                if !breadcrumb.isEmpty {
                    Menu {
                        ForEach(breadcrumb) { heading in
                            Button(heading.title) { jump(to: heading.id) }
                        }
                    } label: {
                        Text("§ " + breadcrumb.map(\.title).joined(separator: " › "))
                            .lineLimit(1)
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .help("Jump to a section in the current path")
                }
                Spacer()
                // Word-count goal (idea #3): quiet progress next to stats.
                if wordGoal > 0 {
                    let fraction = min(1, Double(model.stats.wordCount) / Double(wordGoal))
                    ProgressView(value: fraction)
                        .progressViewStyle(.linear)
                        .frame(width: 56)
                        .tint(fraction >= 1 ? .green : .accentColor)
                        .help("\(model.stats.wordCount) of \(wordGoal) words")
                }
                StatsButton(stats: model.stats, wordGoal: $wordGoal)
            }
            .font(.system(size: 10.5, design: .monospaced))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 12)
            .padding(.vertical, 5)
        }
    }

    // MARK: - Find bar

    private var findBar: some View {
        VStack(spacing: 0) {
            findBarContent
            Divider()
        }
    }

    private var findBarContent: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("Find in document", text: $searchQuery)
                .textFieldStyle(.plain)
                .focused($findFieldFocused)
                .onSubmit { nextMatch() }
                .onExitCommand { closeFind() }
            if !searchQuery.isEmpty {
                Text(matchCount == 0 ? "No matches" : "\(activeMatch + 1) of \(matchCount)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            Button(action: previousMatch) {
                Image(systemName: "chevron.up")
            }
            .disabled(matchCount == 0)
            Button(action: nextMatch) {
                Image(systemName: "chevron.down")
            }
            .disabled(matchCount == 0)
            Button(action: closeFind) {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(.bar)
    }

    private func openFind() {
        isFindVisible = true
        findFieldFocused = true
    }

    private func closeFind() {
        isFindVisible = false
        searchQuery = ""
        activeMatch = 0
    }

    private func nextMatch() {
        guard matchCount > 0 else { return }
        activeMatch = (activeMatch + 1) % matchCount
    }

    private func previousMatch() {
        guard matchCount > 0 else { return }
        activeMatch = (activeMatch - 1 + matchCount) % matchCount
    }
}

// MARK: - Outline panel ("ruled tree" per handoff: hairline under each row,
// indent 0/16/34 by level, H1 bold / H2 semibold / H3+ regular, current
// section in accent at weight 500)

struct OutlinePanel: View {
    let outline: [HeadingInfo]
    let currentSectionID: BlockID?
    let onSelect: (BlockID) -> Void

    /// Collapsed heading subtrees (session-scoped). A heading hides when
    /// any ancestor — the nearest preceding heading of a shallower level —
    /// is collapsed.
    @State private var collapsed: Set<BlockID> = []

    /// Which headings own children (the next entry is deeper).
    private var parents: Set<BlockID> {
        var result: Set<BlockID> = []
        for (index, heading) in outline.enumerated() {
            if index + 1 < outline.count, outline[index + 1].level > heading.level {
                result.insert(heading.id)
            }
        }
        return result
    }

    /// The outline with collapsed subtrees removed. The CURRENT section
    /// always shows — jumping around the document must never leave the
    /// "you are here" marker hidden inside a collapsed branch.
    private var visible: [HeadingInfo] {
        var result: [HeadingInfo] = []
        var hiddenBelowLevel: Int?
        for heading in outline {
            if let level = hiddenBelowLevel {
                if heading.level > level, heading.id != currentSectionID {
                    continue
                }
                hiddenBelowLevel = heading.level > level ? level : nil
            }
            result.append(heading)
            if collapsed.contains(heading.id) {
                hiddenBelowLevel = min(hiddenBelowLevel ?? heading.level, heading.level)
            }
        }
        return result
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                Text("OUTLINE")
                    .font(.system(size: 10, weight: .semibold))
                    .kerning(0.5)
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 12)
                    .padding(.top, 12)
                    .padding(.bottom, 6)

                ForEach(visible) { heading in
                    OutlineRow(
                        heading: heading,
                        isCurrent: heading.id == currentSectionID,
                        isParent: parents.contains(heading.id),
                        isCollapsed: collapsed.contains(heading.id),
                        onSelect: onSelect,
                        onToggle: {
                            withAnimation(.easeOut(duration: 0.15)) {
                                if collapsed.contains(heading.id) {
                                    collapsed.remove(heading.id)
                                } else {
                                    collapsed.insert(heading.id)
                                }
                            }
                        }
                    )
                }
            }
        }
        .overlay {
            if outline.isEmpty {
                Text("No headings")
                    .foregroundStyle(.secondary)
                    .font(.callout)
            }
        }
    }
}

private struct OutlineRow: View {
    let heading: HeadingInfo
    let isCurrent: Bool
    let isParent: Bool
    let isCollapsed: Bool
    let onSelect: (BlockID) -> Void
    let onToggle: () -> Void

    private var indent: CGFloat {
        switch heading.level {
        case 1: return 0
        case 2: return 16
        default: return 34
        }
    }

    private var weight: Font.Weight {
        if isCurrent { return .medium }
        switch heading.level {
        case 1: return .bold
        case 2: return .semibold
        default: return .regular
        }
    }

    var body: some View {
        Button {
            onSelect(heading.id)
        } label: {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 3) {
                    // Disclosure chevron: only headings with children get
                    // one; leaves keep a spacer so titles align.
                    if isParent {
                        Button(action: onToggle) {
                            Image(systemName: "chevron.right")
                                .font(.system(size: 8, weight: .semibold))
                                .foregroundStyle(.tertiary)
                                .rotationEffect(.degrees(isCollapsed ? 0 : 90))
                                .frame(width: 12, height: 12)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .help(isCollapsed ? "Expand section" : "Collapse section")
                    } else {
                        Color.clear.frame(width: 12, height: 12)
                    }
                    Text(heading.title)
                        .font(.system(size: 12, weight: weight))
                        .foregroundStyle(isCurrent ? Color.accentColor : Color.primary)
                        .lineLimit(1)
                    if isCollapsed, isParent {
                        Text("…")
                            .font(.system(size: 12))
                            .foregroundStyle(.tertiary)
                    }
                }
                .padding(.leading, 8 + indent)
                .padding(.trailing, 12)
                .padding(.vertical, 6)
                .frame(maxWidth: .infinity, alignment: .leading)
                Rectangle()
                    .fill(Color.primary.opacity(0.08))
                    .frame(height: 1)
                    .padding(.leading, 12)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Statistics ("412 words · 2,304 chars · 2 min read"; click → detail)

struct StatsButton: View {
    let stats: DocumentStats
    var wordGoal: Binding<Int>?
    @State private var isPresented = false

    private var summary: String {
        let words = stats.wordCount.formatted()
        let chars = stats.characterCount.formatted()
        return "\(words) words · \(chars) chars · \(stats.readingTimeMinutes) min read"
    }

    var body: some View {
        Button {
            isPresented.toggle()
        } label: {
            Text(summary)
        }
        .buttonStyle(.plain)
        .popover(isPresented: $isPresented, arrowEdge: .bottom) {
            StatsView(stats: stats, wordGoal: wordGoal)
        }
        .help("Document statistics")
    }
}

struct StatsView: View {
    let stats: DocumentStats
    var wordGoal: Binding<Int>?

    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 6) {
            row("Words", stats.wordCount)
            row("Characters", stats.characterCount)
            row("Reading time", "\(stats.readingTimeMinutes) min")
            Divider()
            row("Headings", stats.headingCount)
            row("Links", stats.linkCount)
            row("Images", stats.imageCount)
            row("Code blocks", stats.codeBlockCount)
            row("Tables", stats.tableCount)
            if stats.mathCount > 0 { row("Math", stats.mathCount) }
            if stats.diagramCount > 0 { row("Diagrams", stats.diagramCount) }
            if stats.taskTotal > 0 {
                Divider()
                row("Tasks", "\(stats.taskDone) of \(stats.taskTotal) done")
            }
            if let wordGoal {
                Divider()
                GridRow {
                    Text("Word goal").foregroundStyle(.secondary)
                    TextField("Off", value: wordGoal, format: .number)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 90)
                        .multilineTextAlignment(.trailing)
                        .help("Set a word-count goal (0 turns it off); progress shows in the status bar")
                }
            }
        }
        .padding(16)
        .font(.callout)
    }

    @ViewBuilder
    private func row(_ label: String, _ value: Int) -> some View {
        row(label, "\(value)")
    }

    @ViewBuilder
    private func row(_ label: String, _ value: String) -> some View {
        GridRow {
            Text(label).foregroundStyle(.secondary)
            Text(value).monospacedDigit().frame(maxWidth: .infinity, alignment: .trailing)
        }
    }
}
