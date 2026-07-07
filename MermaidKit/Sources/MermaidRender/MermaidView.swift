#if canImport(SwiftUI) && (canImport(AppKit) || canImport(UIKit))
import SwiftUI
import MermaidLayout

/// A drop-in SwiftUI view that renders Mermaid source natively.
///
/// ```swift
/// MermaidView("""
/// flowchart TD
///     A[Start] --> B{Choice}
/// """)
/// ```
///
/// With no explicit theme the view follows the environment's color scheme,
/// re-rendering on light/dark changes. The diagram displays at its natural
/// size and scales down (never up) when the container is narrower.
/// Unrecognized sources fall back to the raw text in monospaced type, so a
/// typo'd diagram degrades to something inspectable rather than a blank.
public struct MermaidView: View {
    private let source: String
    private let explicitTheme: DiagramTheme?

    @Environment(\.colorScheme) private var colorScheme

    /// - Parameters:
    ///   - source: Mermaid source, e.g. `"flowchart TD\n  A --> B"`.
    ///   - theme: Optional fixed theme. Omit to follow the environment's
    ///     light/dark color scheme.
    public init(_ source: String, theme: DiagramTheme? = nil) {
        self.source = source
        self.explicitTheme = theme
    }

    public var body: some View {
        let theme = explicitTheme ?? DiagramTheme(prefersDark: colorScheme == .dark)
        if let image = MermaidRenderer.image(source: source, theme: theme) {
            Image(platformImage: image)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(maxWidth: image.size.width, maxHeight: image.size.height)
                .accessibilityLabel(Text(accessibilityDescription))
        } else {
            Text(source)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 6).fill(.quaternary.opacity(0.5)))
                .accessibilityLabel(Text("Unrecognized diagram source"))
        }
    }

    private var accessibilityDescription: String {
        guard let diagram = MermaidParser.parse(source) else { return "Diagram" }
        return "\(diagram.typeName) diagram"
    }
}

private extension Image {
    init(platformImage: PlatformImage) {
        #if canImport(AppKit)
        self.init(nsImage: platformImage)
        #else
        self.init(uiImage: platformImage)
        #endif
    }
}
#endif
