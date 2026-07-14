import SwiftUI
import QuoinCore

/// The review inspector (suggestions §3.5, as redlined): cards for every
/// mark, in document order, living as the trailing inspector's second mode —
/// works at every window width, never overlaps the canvas. Card anatomy per
/// the approved mock: author + AI badge + relative time, body (comment text
/// with its amber anchor, or the change in the suggestion tints), ✓/✕
/// capsules in the ✓ done chip grammar; replies nest under a hairline;
/// resolved cards dim with actions gone.
struct ReviewPanel: View {
    let items: [ReviewItem]
    /// Resolutions read back from endmatter records (status: resolved) —
    /// history, not live work (user redline: "acted-on things just
    /// disappear").
    let resolved: [ResolvedRecord]
    /// The mark the caret is inside, when any: its card highlights.
    let linked: ByteRange?
    let onResolve: (ByteRange, SuggestionResolver.Action) -> Void
    let onFocus: (ByteRange) -> Void

    @State private var showResolved = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(Array(items.enumerated()), id: \.element) { _, item in
                    ReviewCard(item: item, linked: item.markRange == linked,
                               onResolve: onResolve, onFocus: onFocus)
                }
                if items.isEmpty {
                    Text("Nothing left to review")
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                }
                if !resolved.isEmpty {
                    DisclosureGroup(isExpanded: $showResolved) {
                        VStack(alignment: .leading, spacing: 8) {
                            ForEach(resolved, id: \.self) { record in
                                ResolvedRow(record: record)
                            }
                        }
                        .padding(.top, 6)
                    } label: {
                        Text("RESOLVED · \(resolved.count)")
                            .font(.system(size: 10, weight: .semibold))
                            .kerning(0.5)
                            .foregroundStyle(.tertiary)
                    }
                    .padding(.top, 6)
                }
            }
            .padding(12)
        }
    }
}

/// One line of history: what happened, by whom, when.
private struct ResolvedRow: View {
    let record: ResolvedRecord

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 5) {
                Image(systemName: record.summary.hasPrefix("rejected")
                    ? "xmark.circle" : "checkmark.circle")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                Text(record.by == "AI" ? "Agent" : (record.by ?? record.id))
                    .font(.system(size: 11, weight: .semibold))
                if let at = record.at {
                    Text(at.prefix(10))
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(.tertiary)
                }
            }
            Text(record.summary)
                .font(.system(size: 10.5))
                .foregroundStyle(.secondary)
                .padding(.leading, 15)
        }
        .opacity(0.8)
    }
}

private struct ReviewCard: View {
    let item: ReviewItem
    var linked: Bool = false
    let onResolve: (ByteRange, SuggestionResolver.Action) -> Void
    let onFocus: (ByteRange) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            meta
            body_
            if !item.replies.isEmpty {
                replies
            }
            if !item.isResolved {
                actions
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color(nsColor: .textBackgroundColor)))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(linked ? Color.accentColor : Color.primary.opacity(0.12),
                              lineWidth: linked ? 1.5 : 1))
        .opacity(item.isResolved ? 0.55 : 1)
        .contentShape(Rectangle())
        .onTapGesture { onFocus(item.markRange) }
    }

    private var meta: some View {
        HStack(spacing: 5) {
            Text(item.by == "AI" ? "Agent" : (item.by ?? kindLabel))
                .font(.system(size: 11.5, weight: .semibold))
            if item.by == "AI" {
                Text("AI")
                    .font(.system(size: 8, weight: .semibold, design: .monospaced))
                    .padding(.horizontal, 4).padding(.vertical, 1)
                    .background(Color.primary.opacity(0.07), in: RoundedRectangle(cornerRadius: 4))
                    .foregroundStyle(.secondary)
            }
            if let at = relativeTime {
                Text(at)
                    .font(.system(size: 9.5, design: .monospaced))
                    .foregroundStyle(.tertiary)
            }
            Spacer(minLength: 0)
        }
    }

    private var kindLabel: String {
        switch item.body {
        case .comment: return "Comment"
        case .insertion: return "Insertion"
        case .deletion: return "Deletion"
        case .substitution: return "Replace"
        }
    }

    private var relativeTime: String? {
        guard let at = item.at else { return nil }
        let strict = ISO8601DateFormatter()
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        guard let date = strict.date(from: at) ?? fractional.date(from: at) else { return nil }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: date, relativeTo: Date())
    }

    @ViewBuilder
    private var body_: some View {
        switch item.body {
        case .comment(let text, let anchor):
            (anchorText(anchor) + Text(text))
                .font(.system(size: 11.5))
        case .insertion(let text):
            (Text("Add: ").foregroundStyle(.secondary) + inserted(text))
                .font(.system(size: 11.5))
        case .deletion(let text):
            (Text("Remove: ").foregroundStyle(.secondary) + deleted(text))
                .font(.system(size: 11.5))
        case .substitution(let old, let new):
            (Text("Replace: ").foregroundStyle(.secondary) + deleted(old)
                + Text(" with ").foregroundStyle(.secondary) + inserted(new))
                .font(.system(size: 11.5))
        }
    }

    private func anchorText(_ anchor: String?) -> Text {
        guard let anchor else { return Text("") }
        return Text(anchor).bold()
            .foregroundStyle(Color(nsColor: .systemOrange).opacity(0.9))
            + Text(" — ").foregroundStyle(.secondary)
    }

    private func inserted(_ text: String) -> Text {
        Text(text).foregroundStyle(Color(nsColor: .systemGreen))
    }

    private func deleted(_ text: String) -> Text {
        Text(text).strikethrough().foregroundStyle(Color(nsColor: .systemRed).opacity(0.8))
    }

    private var replies: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(item.replies.enumerated()), id: \.offset) { _, reply in
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 5) {
                        Text(reply.by == "AI" ? "Agent" : (reply.by ?? "reply"))
                            .font(.system(size: 11, weight: .semibold))
                        if reply.by == "AI" {
                            Text("AI")
                                .font(.system(size: 8, weight: .semibold, design: .monospaced))
                                .padding(.horizontal, 4).padding(.vertical, 1)
                                .background(Color.primary.opacity(0.07),
                                            in: RoundedRectangle(cornerRadius: 4))
                                .foregroundStyle(.secondary)
                        }
                    }
                    Text(reply.body).font(.system(size: 11))
                }
            }
        }
        .padding(.leading, 9)
        .overlay(alignment: .leading) {
            Rectangle().fill(Color.primary.opacity(0.12)).frame(width: 2)
        }
    }

    private var actions: some View {
        HStack(spacing: 6) {
            if item.isSuggestion {
                capsule("✓ Accept", prominent: true) {
                    onResolve(item.markRange, .accept)
                }
                capsule("✕ Reject", prominent: false) {
                    onResolve(item.markRange, .reject)
                }
            } else {
                capsule("✕ Dismiss", prominent: false) {
                    onResolve(item.markRange, .accept) // comments: removed either way
                }
            }
        }
        .padding(.top, 2)
    }

    private func capsule(_ title: String, prominent: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 10.5, weight: .medium))
                .padding(.horizontal, 8).padding(.vertical, 2.5)
                .background(
                    prominent ? Color.accentColor.opacity(0.12) : Color.primary.opacity(0.07),
                    in: RoundedRectangle(cornerRadius: 6))
                .foregroundStyle(prominent ? Color.accentColor : Color.secondary)
        }
        .buttonStyle(.plain)
    }
}
