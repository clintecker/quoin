import SwiftUI
import QuoinCore

/// The Properties inspector (#70): front matter as an editable key/value
/// panel, the trailing inspector's third mode. The panel is the EDITOR —
/// the in-document field grid stays the projection. One row per top-level
/// field: key in the grid's small-caps grammar, value in a plain text
/// field committing on Return/focus loss (only when changed). Complex
/// fields (nested lists/maps, flow collections, block scalars) show a
/// read-only raw preview — they're edited in the document via the block's
/// source reveal. Every write goes through the session's in-actor
/// front-matter writers; refusals surface as the action-failure banner.
struct PropertiesPanel: View {
    let fields: [FrontMatterEditing.Field]
    let onSet: (String, String) -> Void
    let onRemove: (String) -> Void

    /// The keys the "+ Add Property" menu pre-offers (already-present
    /// keys drop out); "Custom…" takes any editable key.
    private static let commonKeys = [
        "title", "tags", "date", "author", "status", "description", "aliases", "draft",
    ]

    @State private var isCustomKeyVisible = false
    @State private var customKey = ""

    private var availableCommonKeys: [String] {
        let taken = Set(fields.map(\.key))
        return Self.commonKeys.filter { !taken.contains($0) }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(fields, id: \.byteRange.offset) { field in
                    PropertyRow(field: field, onSet: onSet, onRemove: onRemove)
                }
                if fields.isEmpty {
                    Text("No properties yet")
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                }
                addPropertyMenu
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
            }
            .padding(.top, 6)
        }
    }

    private var addPropertyMenu: some View {
        Menu {
            ForEach(availableCommonKeys, id: \.self) { key in
                Button(key) { onSet(key, "") }
            }
            if !availableCommonKeys.isEmpty {
                Divider()
            }
            Button("Custom…") {
                customKey = ""
                isCustomKeyVisible = true
            }
        } label: {
            Label("Add Property", systemImage: "plus")
                .font(.system(size: 11, weight: .medium))
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("Add a front-matter property")
        .popover(isPresented: $isCustomKeyVisible, arrowEdge: .bottom) {
            customKeyEntry
        }
    }

    private var customKeyEntry: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Property name")
                .font(.system(size: 11, weight: .semibold))
            TextField("key", text: $customKey)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 12))
                .frame(width: 160)
                .onSubmit { addCustomKey() }
            HStack {
                Spacer()
                Button("Add") { addCustomKey() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!FrontMatterEditing.isEditableKey(
                        customKey.trimmingCharacters(in: .whitespaces)))
            }
        }
        .padding(12)
    }

    private func addCustomKey() {
        let key = customKey.trimmingCharacters(in: .whitespaces)
        guard FrontMatterEditing.isEditableKey(key) else { return }
        isCustomKeyVisible = false
        onSet(key, "")
    }
}

/// One field row: small-caps key (the in-document grid's grammar), an
/// editable value line, hover ✕ to remove. Commits only when the draft
/// actually differs — focus wandering must not spam no-op edits.
private struct PropertyRow: View {
    let field: FrontMatterEditing.Field
    let onSet: (String, String) -> Void
    let onRemove: (String) -> Void

    @State private var draft = ""
    @State private var isHovering = false
    @FocusState private var isFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 4) {
                    Text(field.key.uppercased())
                        .font(.system(size: 10, weight: .semibold))
                        .kerning(0.5)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                    if isHovering {
                        Button {
                            onRemove(field.key)
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 10))
                                .foregroundStyle(.tertiary)
                        }
                        .buttonStyle(.plain)
                        .help("Remove “\(field.key)”")
                    }
                }
                if field.isComplex {
                    Text(field.rawPreview)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(4)
                        .help("Nested values are edited in the document — click the front-matter block")
                } else {
                    TextField("empty", text: $draft)
                        .textFieldStyle(.plain)
                        .font(.system(size: 12))
                        .focused($isFocused)
                        .onSubmit { commit() }
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            Rectangle()
                .fill(Color.primary.opacity(0.08))
                .frame(height: 1)
                .padding(.leading, 12)
        }
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
        .contextMenu {
            Button("Remove Property", role: .destructive) { onRemove(field.key) }
        }
        .onAppear { draft = field.value }
        // A projection change (this or another window's edit) refreshes the
        // row — but never while the user is mid-type in it.
        .onChange(of: field.value) { _, newValue in
            if !isFocused { draft = newValue }
        }
        .onChange(of: isFocused) { _, focused in
            if !focused { commit() }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(field.key): \(field.isComplex ? field.rawPreview : field.value)")
    }

    private func commit() {
        guard draft != field.value else { return }
        onSet(field.key, draft)
    }
}
