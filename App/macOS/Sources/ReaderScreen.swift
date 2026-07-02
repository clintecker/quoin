import SwiftUI
import QuoinCore
import QuoinRender

/// One document window: TOC sidebar, reading surface, find bar, stats.
/// Minimalist by design — panels are closed by default and everything is
/// keyboard-reachable.
struct ReaderScreen: View {
    let fileURL: URL?
    let initialText: String

    @StateObject private var model = ReaderModel()

    @State private var isFindVisible = false
    @State private var searchQuery = ""
    @State private var activeMatch = 0
    @State private var matchCount = 0
    @State private var scrollTarget: BlockID?
    @FocusState private var findFieldFocused: Bool

    var body: some View {
        NavigationSplitView {
            TOCSidebar(outline: model.outline) { headingID in
                scrollTarget = headingID
            }
            .navigationSplitViewColumnWidth(min: 180, ideal: 220)
        } detail: {
            VStack(spacing: 0) {
                if isFindVisible {
                    findBar
                }
                MarkdownReaderView(
                    rendered: model.rendered,
                    searchQuery: isFindVisible ? searchQuery : "",
                    activeMatchOrdinal: activeMatch,
                    scrollTarget: scrollTarget,
                    onTaskToggle: { offset in model.toggleTask(markerOffset: offset) },
                    onMatchCount: { count in
                        matchCount = count
                        if activeMatch >= count { activeMatch = 0 }
                    },
                    anchorResolver: { slug in model.blockID(forSlug: slug) }
                )
            }
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                StatsButton(stats: model.stats)
            }
        }
        .navigationTitle(fileURL?.lastPathComponent ?? "Untitled")
        .onAppear { model.start(fileURL: fileURL, initialText: initialText) }
        .onDisappear { model.stop() }
        .background(
            // Find commands, window-local.
            Group {
                Button("") { openFind() }
                    .keyboardShortcut("f", modifiers: .command)
                Button("") { nextMatch() }
                    .keyboardShortcut("g", modifiers: .command)
                Button("") { previousMatch() }
                    .keyboardShortcut("g", modifiers: [.command, .shift])
            }
            .opacity(0)
            .accessibilityHidden(true)
        )
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

// MARK: - Table of contents

struct TOCSidebar: View {
    let outline: [HeadingInfo]
    let onSelect: (BlockID) -> Void

    var body: some View {
        List(outline) { heading in
            Button {
                onSelect(heading.id)
            } label: {
                Text(heading.title)
                    .lineLimit(2)
                    .font(heading.level <= 1 ? .body.weight(.semibold) : .body)
                    .padding(.leading, CGFloat(max(0, heading.level - 1)) * 12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .listStyle(.sidebar)
        .overlay {
            if outline.isEmpty {
                Text("No headings")
                    .foregroundStyle(.secondary)
                    .font(.callout)
            }
        }
    }
}

// MARK: - Statistics

struct StatsButton: View {
    let stats: DocumentStats
    @State private var isPresented = false

    var body: some View {
        Button {
            isPresented.toggle()
        } label: {
            Label("Statistics", systemImage: "chart.bar.doc.horizontal")
        }
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
