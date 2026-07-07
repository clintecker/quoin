#if canImport(AppKit) || canImport(UIKit)
import Foundation
import CoreGraphics
#if canImport(AppKit)
import AppKit
#else
import UIKit
#endif
import MermaidLayout

/// Public entry points for host apps.
public enum MermaidRenderer {

    /// Renders Mermaid source to a native image, or nil if the source isn't a
    /// recognized Mermaid diagram. The image auto-sizes to the diagram bounds.
    public static func image(source: String, theme: DiagramTheme) -> PlatformImage? {
        guard let attr = attachmentString(source: source, theme: theme),
              attr.length > 0,
              let attachment = attr.attribute(.attachment, at: 0, effectiveRange: nil) as? NSTextAttachment
        else { return nil }
        return attachment.image
    }

    /// Renders off the calling thread — the async twin of
    /// ``image(source:theme:)`` for hosts batching many diagrams or staying
    /// paranoid about main-thread time (a single cold render is single-digit
    /// milliseconds for most types; the worst dense fixture is ~13 ms).
    /// Shares the same render cache.
    public static func image(source: String, theme: DiagramTheme) async -> sending PlatformImage? {
        let task = Task.detached(priority: .userInitiated) { () -> sending PlatformImage? in
            image(source: source, theme: theme)
        }
        return await task.value
    }

    /// The diagram as a single-attachment attributed string, for embedding in
    /// a text view (how Quoin's editor consumes it). Nil when not Mermaid.
    public static func attachmentString(source: String, theme: DiagramTheme) -> NSAttributedString? {
        DiagramRenderer.attachmentString(source: source, theme: theme)
    }

    /// The CoreText measurer the renderer itself uses — pass to
    /// `DiagramLayoutEngine.layout`/`DiagramScene.lower` so layout geometry and
    /// lint checks see the same text metrics the render does.
    public static let textMeasurer: @Sendable (String, Double) -> CGSize = { text, size in
        DiagramRenderer.measure(text, size: CGFloat(size))
    }
}
#endif
