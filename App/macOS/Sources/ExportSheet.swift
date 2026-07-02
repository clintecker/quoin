import AppKit
import SwiftUI
import UniformTypeIdentifiers
import QuoinCore
import QuoinRender

/// The export sheet (⇧⌘E) per handoff §3: format grid (3-up cards, PDF
/// default-selected), accent primary button, native save panel.
struct ExportSheet: View {
    let documentName: String
    let document: QuoinDocument
    @Binding var isPresented: Bool

    @State private var selected: ExportFormat = .pdf
    @State private var exportError: String?

    enum ExportFormat: String, CaseIterable, Identifiable {
        case pdf = "PDF"
        case html = "HTML"
        case markdown = "MD"
        case rtf = "RTF"
        case txt = "TXT"

        var id: String { rawValue }

        var caption: String {
            switch self {
            case .pdf: return "Paginated, print-ready"
            case .html: return "Standalone, styles inlined"
            case .markdown: return "Normalized source"
            case .rtf: return "For word processors"
            case .txt: return "Plain text"
            }
        }

        var fileExtension: String {
            switch self {
            case .pdf: return "pdf"
            case .html: return "html"
            case .markdown: return "md"
            case .rtf: return "rtf"
            case .txt: return "txt"
            }
        }

        var contentType: UTType {
            switch self {
            case .pdf: return .pdf
            case .html: return .html
            case .markdown: return UTType(filenameExtension: "md") ?? .plainText
            case .rtf: return .rtf
            case .txt: return .plainText
            }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Export “\(documentName)”")
                .font(.system(size: 15, weight: .semibold))

            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 3), spacing: 10) {
                ForEach(ExportFormat.allCases) { format in
                    formatCard(format)
                }
                disabledCard(title: "DOCX", caption: "Later")
            }

            if let exportError {
                Text(exportError)
                    .font(.system(size: 11))
                    .foregroundStyle(.red)
            }

            HStack {
                Spacer()
                Button("Cancel") { isPresented = false }
                    .keyboardShortcut(.cancelAction)
                Button("Export…") { runExport() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(20)
        .frame(width: 440)
    }

    private func formatCard(_ format: ExportFormat) -> some View {
        let isSelected = format == selected
        return VStack(spacing: 3) {
            Text(format.rawValue)
                .font(.system(size: 14, weight: .semibold))
            Text(format.caption)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 14)
        .background(
            RoundedRectangle(cornerRadius: 7)
                .fill(isSelected ? Color.accentColor.opacity(0.05) : Color.clear)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 7)
                .strokeBorder(
                    isSelected ? Color.accentColor : Color.primary.opacity(0.12),
                    lineWidth: isSelected ? 2 : 1
                )
        )
        .contentShape(Rectangle())
        .onTapGesture { selected = format }
    }

    private func disabledCard(title: String, caption: String) -> some View {
        VStack(spacing: 3) {
            Text(title).font(.system(size: 14, weight: .semibold))
            Text(caption).font(.system(size: 10))
        }
        .foregroundStyle(.tertiary)
        .frame(maxWidth: .infinity)
        .padding(.vertical, 14)
        .overlay(
            RoundedRectangle(cornerRadius: 7)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
        )
    }

    // MARK: - Export

    private func runExport() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [selected.contentType]
        panel.nameFieldStringValue = "\(documentName).\(selected.fileExtension)"
        guard panel.runModal() == .OK, let url = panel.url else { return }

        do {
            let data: Data
            switch selected {
            case .pdf:
                data = try DocumentExporters.pdf(from: document, title: documentName)
            case .html:
                data = Data(HTMLExporter.export(document, title: documentName).utf8)
            case .markdown:
                data = Data(MarkdownExporter.export(document).utf8)
            case .rtf:
                data = try DocumentExporters.rtf(from: document)
            case .txt:
                data = Data(PlainTextExporter.export(document).utf8)
            }
            try data.write(to: url)
            isPresented = false
        } catch {
            exportError = "Export failed: \(error.localizedDescription)"
        }
    }
}
