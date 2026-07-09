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

    @State private var isOutlineVisible = true
    @State private var isExportVisible = false
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
                onActivateBlock: { id, caretHint in model.activateBlock(id, caretHint: caretHint) },
                caretInActiveBlock: model.caretInActiveBlock,
                caretGeneration: model.caretGeneration,
                formatCommand: formatCommand,
                formatGeneration: formatGeneration
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
                scrollTarget = headingID
                scrollGeneration += 1
            }
            .inspectorColumnWidth(min: 180, ideal: 220, max: 320)
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
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
            default:
                break
            }
        }
        .onDisappear { model.stop() }
        // ⌥⌘0 / View ▸ Show/Hide Outline (menu command, handoff keyboard map).
        .onReceive(NotificationCenter.default.publisher(for: AppDelegate.toggleOutlineNotification)) { _ in
            isOutlineVisible.toggle()
        }
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
            // ⌘0/⌥⌘0 live in the View menu (QuoinApp.commands).
            Button("") { model.undo() }
                .keyboardShortcut("z", modifiers: .command)
            Button("") { model.redo() }
                .keyboardShortcut("z", modifiers: [.command, .shift])
            Button("") { isExportVisible = true }
                .keyboardShortcut("e", modifiers: [.command, .shift])
            Button("") { fireFormat(.bold) }
                .keyboardShortcut("b", modifiers: .command)
            Button("") { fireFormat(.italic) }
                .keyboardShortcut("i", modifiers: .command)
            Button("") { fireFormat(.highlight) }
                .keyboardShortcut("h", modifiers: [.command, .shift])
            Button("") { fireFormat(.link) }
                .keyboardShortcut("k", modifiers: .command)
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
                if let section = currentSection {
                    Text("§ \(section.title)")
                        .lineLimit(1)
                }
                Spacer()
                StatsButton(stats: model.stats)
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

                ForEach(outline) { heading in
                    OutlineRow(
                        heading: heading,
                        isCurrent: heading.id == currentSectionID,
                        onSelect: onSelect
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
    let onSelect: (BlockID) -> Void

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
                Text(heading.title)
                    .font(.system(size: 12, weight: weight))
                    .foregroundStyle(isCurrent ? Color.accentColor : Color.primary)
                    .lineLimit(1)
                    .padding(.leading, 12 + indent)
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
            StatsView(stats: stats)
        }
        .help("Document statistics")
    }
}

struct StatsView: View {
    let stats: DocumentStats

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
