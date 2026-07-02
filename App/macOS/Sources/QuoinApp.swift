import SwiftUI
import UniformTypeIdentifiers

@main
struct QuoinApp: App {
    var body: some Scene {
        DocumentGroup(viewing: MarkdownFile.self) { configuration in
            ReaderScreen(
                fileURL: configuration.fileURL,
                initialText: configuration.document.text
            )
        }
        .commands {
            // Viewer-first: strip the edit-oriented default menu items.
            CommandGroup(replacing: .saveItem) {}
            CommandGroup(replacing: .undoRedo) {}
        }
    }
}

extension UTType {
    static let markdownDocument = UTType(importedAs: "net.daringfireball.markdown")
}

/// Read-only document wrapper. Quoin never saves through the document
/// system — the only write path is the byte-precise checkbox toggle in
/// `DocumentSession`, which goes straight to disk under file coordination.
struct MarkdownFile: FileDocument {
    static var readableContentTypes: [UTType] {
        [.markdownDocument, .plainText, .text]
    }

    let text: String

    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents,
              let text = String(data: data, encoding: .utf8)
        else {
            throw CocoaError(.fileReadCorruptFile)
        }
        self.text = text
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        // Required by FileDocument; unreachable because saving is disabled.
        FileWrapper(regularFileWithContents: Data(text.utf8))
    }
}
