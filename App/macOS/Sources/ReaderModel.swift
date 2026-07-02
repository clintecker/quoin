import Foundation
import SwiftUI
import QuoinCore
import QuoinRender

/// Owns the `DocumentSession` for one window and republishes its snapshots
/// as rendered output for SwiftUI. Parsing and rendering happen off the
/// main actor; the UI only ever receives finished values.
@MainActor
final class ReaderModel: ObservableObject {

    @Published private(set) var rendered: RenderedDocument = .empty
    @Published private(set) var outline: [HeadingInfo] = []
    @Published private(set) var stats = DocumentStats()

    private var session: DocumentSession?
    private var snapshotTask: Task<Void, Never>?
    private var renderer = AttributedRenderer()
    private var slugToBlock: [String: BlockID] = [:]

    func start(fileURL: URL?, initialText: String) {
        guard session == nil else { return }
        let theme = Theme()
        renderer = AttributedRenderer(theme: theme, baseURL: fileURL?.deletingLastPathComponent())

        let session: DocumentSession
        if let fileURL, let opened = try? DocumentSession.open(fileURL: fileURL) {
            session = opened
        } else {
            session = DocumentSession(source: initialText, fileURL: fileURL)
        }
        self.session = session

        // Detached so parsing/rendering never runs on the main actor.
        snapshotTask = Task.detached(priority: .userInitiated) { [weak self, renderer] in
            await session.startWatching()
            let snapshots = await session.snapshots()
            for await document in snapshots {
                // Render off the main actor; big documents shouldn't hitch the UI.
                let rendered = renderer.render(document)
                await self?.publish(document: document, rendered: rendered)
            }
        }
    }

    func stop() {
        snapshotTask?.cancel()
        snapshotTask = nil
        let session = session
        Task { await session?.stopWatching() }
    }

    private func publish(document: QuoinDocument, rendered: RenderedDocument) {
        self.rendered = rendered
        self.outline = document.outline
        self.stats = document.stats
        self.slugToBlock = Dictionary(
            document.outline.map { ($0.slug, $0.id) },
            uniquingKeysWith: { first, _ in first }
        )
    }

    func toggleTask(markerOffset: Int) {
        guard let session else { return }
        Task {
            try? await session.toggleTask(markerRange: ByteRange(offset: markerOffset, length: 3))
        }
    }

    func blockID(forSlug slug: String) -> BlockID? {
        slugToBlock[slug]
    }
}
