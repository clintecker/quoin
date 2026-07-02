import SwiftUI
import QuoinCore
import QuoinRender

/// One document window, laid out per the design handoff: editor center
/// (max 680pt column), outline panel as a trailing inspector (⌥⌘0),
/// find bar, and a status bar with section + live statistics.
/// The library sidebar arrives in Phase D.
struct ReaderScreen: View {
    let fileURL: URL?
    let initialText: String

    @StateObject private var model = ReaderModel()
    private let theme = Theme()

    @State private var isOutlineVisible = true
    @State private var isFindVisible = false
    @State private var searchQuery = ""
    @State private var activeMatch = 0
    @State private var matchCount = 0
    @State private var scrollTarget: BlockID?
    @State private var topBlockID: BlockID?
    @FocusState private var findFieldFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            if isFindVisible {
                findBar
            }
            MarkdownReaderView(
                rendered: model.rendered,
                theme: theme,
                searchQuery: isFindVisible ? searchQuery : "",
                activeMatchOrdinal: activeMatch,
                scrollTarget: scrollTarget,
                onTaskToggle: { offset in model.toggleTask(markerOffset: offset) },
                onMatchCount: { count in
                    matchCount = count
                    if activeMatch >= count { activeMatch = 0 }
                },
                anchorResolver: { slug in model.blockID(forSlug: slug) },
                onTopBlockChange: { top in topBlockID = top },
                onEditIntent: { range, replacement in
                    model.applyEdit(relativeRange: range, replacement: replacement)
                },
                onActivateBlock: { id in model.activateBlock(id) },
                caretInActiveBlock: model.caretInActiveBlock,
                caretGeneration: model.caretGeneration
            )
            statusBar
        }
        .inspector(isPresented: $isOutlineVisible) {
            OutlinePanel(
                outline: model.outline,
                currentSectionID: currentSection?.id
            ) { headingID in
                scrollTarget = headingID
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
        .navigationTitle(fileURL?.deletingPathExtension().lastPathComponent ?? "Untitled")
        .onAppear { model.start(fileURL: fileURL, initialText: initialText) }
        .onDisappear { model.stop() }
        .background(hiddenShortcuts)
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
            Button("") { isOutlineVisible.toggle() }
                .keyboardShortcut("0", modifiers: [.command, .option])
            Button("") { model.undo() }
                .keyboardShortcut("z", modifiers: .command)
            Button("") { model.redo() }
                .keyboardShortcut("z", modifiers: [.command, .shift])
        }
        .opacity(0)
        .accessibilityHidden(true)
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
