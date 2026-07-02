import AppKit
import SwiftUI
import QuoinCore

/// The library sidebar: classic tree per the handoff (icons, disclosure
/// chevrons, accent-filled selection), documents open on click, assets
/// grayed, footer with the document count.
struct LibrarySidebar: View {
    @ObservedObject var library: LibraryModel
    @Binding var selection: URL?
    let onOpen: (URL) -> Void

    var body: some View {
        VStack(spacing: 0) {
            List(selection: $selection) {
                if let children = library.root?.children {
                    ForEach(children) { node in
                        LibraryRow(node: node, onOpen: onOpen, library: library)
                    }
                }
            }
            .listStyle(.sidebar)

            Divider()
            HStack {
                Text(library.documentCount == 1 ? "1 document" : "\(library.documentCount) documents")
                Spacer()
            }
            .font(.system(size: 10.5))
            .foregroundStyle(.tertiary)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            HStack {
                Spacer()
                Button {
                    if let url = library.createDocument() { onOpen(url) }
                } label: {
                    Image(systemName: "plus")
                }
                .buttonStyle(.borderless)
                .help("New document (⌘N)")
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
        }
    }
}

private struct LibraryRow: View {
    let node: LibraryNode
    let onOpen: (URL) -> Void
    @ObservedObject var library: LibraryModel

    @State private var isRenaming = false
    @State private var draftName = ""

    var body: some View {
        if node.kind == .folder {
            DisclosureGroup {
                ForEach(node.children ?? []) { child in
                    LibraryRow(node: child, onOpen: onOpen, library: library)
                }
            } label: {
                Label(node.name, systemImage: "folder")
                    .font(.system(size: 12.5))
            }
        } else {
            row
        }
    }

    private var row: some View {
        Group {
            if isRenaming {
                TextField("Name", text: $draftName, onCommit: {
                    isRenaming = false
                    _ = library.rename(url: node.url, to: draftName)
                })
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 12.5))
            } else {
                Label {
                    Text(node.name)
                        .font(.system(size: 12.5))
                        .foregroundStyle(node.kind == .asset ? Color.primary.opacity(0.35) : Color.primary)
                } icon: {
                    Image(systemName: node.kind == .asset ? "photo" : "doc.text")
                        .foregroundStyle(node.kind == .asset ? Color.primary.opacity(0.35) : Color.secondary)
                }
            }
        }
        .tag(node.url)
        .contentShape(Rectangle())
        .onTapGesture {
            if node.kind == .document { onOpen(node.url) }
        }
        .contextMenu {
            if node.kind == .document {
                Button("Open") { onOpen(node.url) }
                Button("Rename") {
                    draftName = node.name
                    isRenaming = true
                }
            }
            Button("Reveal in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([node.url])
            }
        }
    }
}

// MARK: - Quick open (⇧⌘O)

/// Centered floating panel: search row + fuzzy-title / full-text results.
struct QuickOpenPanel: View {
    @ObservedObject var library: LibraryModel
    @Binding var isPresented: Bool
    let onOpen: (URL) -> Void

    @State private var highlighted = 0
    @FocusState private var fieldFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("Open document…", text: $library.quickOpenQuery)
                    .textFieldStyle(.plain)
                    .font(.system(size: 15))
                    .focused($fieldFocused)
                    .onSubmit { openHighlighted() }
                    .onExitCommand { close() }
            }
            .padding(12)

            if !library.quickOpenResults.isEmpty {
                Divider()
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(Array(library.quickOpenResults.enumerated()), id: \.element.id) { index, result in
                            resultRow(result, isHighlighted: index == highlighted)
                                .onTapGesture {
                                    onOpen(result.url)
                                    close()
                                }
                        }
                    }
                }
                .frame(maxHeight: 320)
            }
        }
        .frame(width: 480)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
        .shadow(color: .black.opacity(0.14), radius: 32, y: 12)
        .onAppear { fieldFocused = true }
        .onChange(of: library.quickOpenQuery) { _, _ in
            highlighted = 0
            library.runQuickOpen()
        }
    }

    private func resultRow(_ result: QuickOpen.Result, isHighlighted: Bool) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(result.title)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(isHighlighted ? Color.white : Color.primary)
            if !result.snippet.isEmpty {
                Text(result.snippet)
                    .font(.system(size: 11))
                    .lineLimit(1)
                    .foregroundStyle(isHighlighted ? Color.white.opacity(0.85) : Color.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(isHighlighted ? Color.accentColor : Color.clear)
        .contentShape(Rectangle())
    }

    private func openHighlighted() {
        guard library.quickOpenResults.indices.contains(highlighted) else { return }
        onOpen(library.quickOpenResults[highlighted].url)
        close()
    }

    private func close() {
        isPresented = false
        library.quickOpenQuery = ""
    }
}

// MARK: - Tab bar

/// Custom tab strip per the handoff: hidden with one document, active tab
/// emphasized, ⌘1–9 handled by the window.
struct DocumentTabBar: View {
    let tabs: [URL]
    @Binding var activeTab: URL?
    let onClose: (URL) -> Void

    var body: some View {
        if tabs.count > 1 {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 1) {
                    ForEach(tabs, id: \.self) { url in
                        tab(url)
                    }
                }
            }
            .background(Color.primary.opacity(0.04))
            .overlay(alignment: .bottom) { Divider() }
        }
    }

    private func tab(_ url: URL) -> some View {
        let isActive = url == activeTab
        return HStack(spacing: 6) {
            Text(url.deletingPathExtension().lastPathComponent)
                .font(.system(size: 12, weight: isActive ? .medium : .regular))
                .foregroundStyle(isActive ? Color.primary : Color.primary.opacity(0.5))
                .lineLimit(1)
            Button {
                onClose(url)
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .opacity(isActive ? 1 : 0.4)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .frame(minWidth: 120)
        .background(isActive ? Color(nsColor: .textBackgroundColor) : Color.clear)
        .contentShape(Rectangle())
        .onTapGesture { activeTab = url }
    }
}
